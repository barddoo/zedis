const std = @import("std");
const storeModule = @import("../store.zig");
const ZedisObject = storeModule.ZedisObject;
const Store = storeModule.Store;
const ZedisValue = storeModule.ZedisValue;
const ValueType = storeModule.ValueType;
const ZedisList = @import("../list.zig").ZedisList;
const ZedisListNode = @import("../list.zig").ZedisListNode;
const fs = std.fs;
const eql = std.mem.eql;

// const WriteType = union(enum) {
//     int: i64,
//     string: []const u8,
// };

const DEFAULT_FILE_NAME = "test.rdb";

const OPCODE_AUX = 0xFA;
const OPCODE_RESIZE_DB = 0xFB;
const OPCODE_EXPIRE_TIME_MS = 0xFC;
const OPCODE_EXPIRE_TIME = 0xFD;
const OPCODE_SELECT_DB = 0xFE;
const OPCODE_EOF = 0xFF;

const LEN_PREFIX_32_INT = 0b10000000;
const LEN_PREFIX_64_INT = 0b10000001;

const INT_PREFIX_8_BITS = 0xC0;
const INT_PREFIX_16_BITS = 0xC1;
const INT_PREFIX_32_BITS = 0xC2;

const VALUE_TYPE_STR = 0x00;

pub const RdbWriteError = error{ StringTooLarge, NumberTooLarge };
pub const RdbError = RdbWriteError || std.fs.File.WriteError || error{WriteFailed};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    buffer: *[1024]u8,
    file: std.fs.File,
    store: *Store,
    writer: std.fs.File.Writer,

    fn mapToOpCode(val: ZedisValue) u8 {
        return switch (val) {
            .int, .string, .short_string => 0x00,
            .list => 0x01,
            .time_series => 0x0A,
        };
    }

    pub fn init(allocator: std.mem.Allocator, store: *Store, fileName: []const u8) !Writer {
        fs.cwd().deleteFile(fileName) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const file = try std.fs.cwd().createFile(fileName, .{ .truncate = true });
        const buffer = try allocator.create([1024]u8);
        const writer = file.writer(buffer);

        return .{
            .allocator = allocator,
            .buffer = buffer,
            .file = file,
            .store = store,
            .writer = writer,
        };
    }

    pub fn deinit(self: *Writer) void {
        _ = self.writer.interface.flush() catch {};
        self.file.close();
        self.allocator.destroy(self.buffer);
    }

    pub fn writeFile(self: *Writer) !void {
        try self.writeHeader();
        try self.writeCache();
        try self.writeEndOfFile();

        try self.writer.interface.flush();
    }

    fn writeHeader(self: *Writer) !void {
        try self.writeAuxFields();

        try self.writer.interface.writeByte(OPCODE_SELECT_DB);
        try self.writeLength(0x00);

        try self.writer.interface.writeByte(OPCODE_RESIZE_DB);
        try self.writeLength(self.store.size());
        // TODO Write the size of the expiry hash table
        try self.writeLength(0);
    }

    fn writeEndOfFile(self: *Writer) !void {
        try self.writer.interface.writeByte(OPCODE_EOF);
        // TODO Fix this
        const file_content = self.writer.interface.buffered();
        const checksum = std.hash.crc.Crc64Redis.hash(file_content);

        try self.writer.interface.writeInt(u64, checksum, .little);
    }

    fn writeAuxFields(self: *Writer) !void {
        _ = try self.writer.interface.write("REDIS");
        _ = try self.writer.interface.write("0012");

        try self.writeMetadata("redis-ver", .{ .string = "255.255.255" });

        const bits = if (@sizeOf(usize) == 8) 64 else 32;
        try self.writeMetadata("redis-bits", .{ .int = bits });

        const now_timestamp = std.time.timestamp();
        try self.writeMetadata("ctime", .{ .int = now_timestamp });

        // TODO
        try self.writeMetadata("used-mem", .{ .int = 0 });

        // TODO
        try self.writeMetadata("aof-base", .{ .int = 0 });
    }

    fn writeMetadata(self: *Writer, key: []const u8, value: ZedisValue) !void {
        // 0xFA indicates auxiliary field; we encode key then value as length-prefixed strings.
        try self.writer.interface.writeByte(0xFA);
        try self.genericWrite(.{ .string = key });
        try self.genericWrite(value);
    }

    fn writeCache(self: *Writer) !void {
        var it = self.store.map.iterator();
        while (it.next()) |entry| {
            if (self.store.getTtl(entry.key_ptr.*)) |expiry| {
                try self.writer.interface.writeByte(OPCODE_EXPIRE_TIME_MS);
                try self.writer.interface.writeInt(i64, expiry, .little);
            }

            const value = entry.value_ptr.value;

            const op_code = Writer.mapToOpCode(value);
            try self.writer.interface.writeByte(op_code);

            try self.writeString(entry.key_ptr.*);

            switch (entry.value_ptr.*.value) {
                .int => |i| try self.writeInt(i),
                .string => |s| try self.writeString(s),
                .short_string => |ss| try self.writeString(ss.asSlice()),
                .list => |list| try self.writeList(@constCast(&list)),
                // TODO
                else => {},
            }
        }
    }

    fn writeLength(self: *Writer, len: u64) RdbError!void {
        if (len <= 63) { // 6-bit
            try self.writer.interface.writeByte(@as(u8, @truncate(len)));
        } else if (len <= 16383) { // 14-bit
            const first_byte = 0b01000000 | @as(u8, @truncate(len >> 8));
            const second_byte = @as(u8, @truncate(len));
            try self.writer.interface.writeByte(first_byte);
            try self.writer.interface.writeByte(second_byte);
        } else if (len <= 0xFFFFFFFF) { // 32-bit
            try self.writer.interface.writeByte(LEN_PREFIX_32_INT);
            try self.writer.interface.writeInt(u32, @intCast(len), .big);
        } else { // 64-bit
            try self.writer.interface.writeByte(LEN_PREFIX_64_INT);
            try self.writer.interface.writeInt(u64, len, .big);
        }
    }

    fn writeString(self: *Writer, str: []const u8) RdbError!void {
        try self.writeLength(str.len);
        try self.writer.interface.writeAll(str);
    }

    fn writeList(self: *Writer, list: *ZedisList) RdbError!void {
        const len = list.len();
        try self.writeLength(len);

        var current = list.list.first;
        while (current) |node| {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            const value = list_node.data;

            switch (value) {
                .int => |i| try self.writeInt(i),
                .string => |s| try self.writeString(s),
            }

            current = node.next;
        }
    }

    fn writeInt(self: *Writer, number: i64) RdbError!void {
        if (number >= std.math.minInt(i8) and number <= std.math.maxInt(i8)) {
            // Can fit in i8
            try self.writer.interface.writeByte(INT_PREFIX_8_BITS);
            try self.writer.interface.writeInt(i8, @intCast(number), .little);
        } else if (number >= std.math.minInt(i16) and number <= std.math.maxInt(i16)) {
            // Can fit in i16
            try self.writer.interface.writeByte(INT_PREFIX_16_BITS);
            try self.writer.interface.writeInt(i16, @intCast(number), .little);
        } else if (number >= std.math.minInt(i32) and number <= std.math.maxInt(i32)) {
            // Can fit in i32
            try self.writer.interface.writeByte(INT_PREFIX_32_BITS);
            try self.writer.interface.writeInt(i32, @intCast(number), .little);
        } else {
            // Fallback for larger numbers (i64) or any number that doesn't fit
            // the above: write as a length-prefixed string.
            var buf: [20]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{}", .{number});
            try self.writeString(str);
        }
    }

    fn genericWrite(self: *Writer, payload: ZedisValue) RdbError!void {
        switch (payload) {
            .int => |number| try self.writeInt(number),
            .string => |str| try self.writeString(str),
            .short_string => |ss| try self.writeString(ss.asSlice()),
            .list => |list| try self.writeList(@constCast(&list)),
            else => {},
        }
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    file: std.fs.File,
    reader: std.fs.File.Reader,
    store: *Store,

    const MAGIC_STRING = "REDIS";
    const ReaderError = error{ MalformedRDB, UnknownLengthPrefix };

    pub const RdbReaderOutput = struct {
        rdb_version: ?[]u8,
        redis_version: ?[]u8,
        redis_bits: ?i64,
        ctime: i64,
        used_mem: ?i64,
        aof_base: ?i64,
        resize_db: u64,
        resize_db_expiration: u64,
        select_db: u64,
    };

    pub fn init(allocator: std.mem.Allocator, store: *Store) !Reader {
        const file = try fs.cwd().openFile(DEFAULT_FILE_NAME, .{});

        const buffer = try allocator.alloc(u8, 1024 * 100);

        const reader = file.reader(buffer);

        return .{ .allocator = allocator, .buffer = buffer, .store = store, .file = file, .reader = reader };
    }

    pub fn rdbFileExists() bool {
        fs.cwd().access(DEFAULT_FILE_NAME, .{}) catch {
            return false;
        };

        return true;
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.buffer);
        self.file.close();
    }

    pub fn readFile(self: *Reader) !RdbReaderOutput {
        var output: RdbReaderOutput = .{
            .rdb_version = undefined,
            .redis_version = undefined,
            .redis_bits = undefined,
            .ctime = undefined,
            .used_mem = undefined,
            .aof_base = undefined,
            .resize_db = undefined,
            .resize_db_expiration = undefined,
            .select_db = undefined,
        };
        const magic_string = try self.reader.interface.takeArray(5);
        assert(magic_string, MAGIC_STRING);

        const rdb_version = try self.reader.interface.takeArray(4);
        output.rdb_version = rdb_version;

        while (true) {
            const byte = try self.reader.interface.takeByte();

            switch (byte) {
                OPCODE_AUX => {
                    const key = try self.readString();

                    if (eql(u8, key, "redis-ver")) {
                        output.redis_version = try self.readString();
                    } else if (eql(u8, key, "redis-bits")) {
                        output.redis_bits = try self.readInt();
                    } else if (eql(u8, key, "ctime")) {
                        output.ctime = try self.readInt();
                    } else if (eql(u8, key, "used-mem")) {
                        output.used_mem = try self.readInt();
                    } else if (eql(u8, key, "aof-base")) {
                        output.aof_base = try self.readInt();
                    }
                },
                OPCODE_RESIZE_DB => {
                    output.resize_db = try self.readLength();
                    output.resize_db_expiration = try self.readLength();
                },
                OPCODE_SELECT_DB => {
                    output.select_db = try self.readLength();
                },

                OPCODE_EXPIRE_TIME_MS => {
                    const expiration = try self.reader.interface.takeInt(u64, .little);
                    const op_code = try self.reader.interface.takeByte();
                    // TODO Load expiration time
                    _ = expiration;
                    _ = op_code;
                    try self.readEntry();
                },
                VALUE_TYPE_STR => {
                    try self.readEntry();
                },
                OPCODE_EOF => {
                    break;
                },
                else => {
                    return error.MalformedRDB;
                },
            }
        }
        return output;
    }

    fn readEntry(self: *Reader) !void {
        const key = try self.readString();
        const value = try self.genericRead();

        try self.store.putObject(key, .{ .value = value });
    }

    fn assert(incoming_byes: []u8, expected: []const u8) void {
        std.debug.assert(std.mem.eql(u8, incoming_byes, expected));
    }

    fn readLength(self: *Reader) !u64 {
        const first_byte = try self.reader.interface.takeByte();

        switch (first_byte) {
            // Case 1: Bits are 00xxxxxx. The length IS the lower 6 bits.
            0x00...0x3F => {
                // The length is just the byte value itself (masked implicitly by the range).
                return @as(u64, first_byte);
            },
            // Case 2: Bits are 01xxxxxx. Length is 14 bits.
            // This is the range that matches your requirement.
            0x40...0x7F => {
                // The high 6 bits of the length are the lower 6 bits of this byte.
                const high_part: u64 = @as(u64, first_byte & 0x3F);

                // The low 8 bits of the length are the entire next byte.
                const low_part: u64 = try self.reader.interface.takeByte();

                // Combine them: (high_bits << 8) | low_bits
                return (high_part << 8) | low_part;
            },
            LEN_PREFIX_32_INT => {
                return try self.reader.interface.takeInt(u32, .big);
            },
            LEN_PREFIX_64_INT => {
                return try self.reader.interface.takeInt(u64, .big);
            },
            else => return ReaderError.UnknownLengthPrefix,
        }
    }

    fn readInt(self: *Reader) !i64 {
        const first_byte = try self.reader.interface.takeByte();
        switch (first_byte) {
            INT_PREFIX_8_BITS => {
                return try self.reader.interface.takeInt(i8, .little);
            },
            INT_PREFIX_16_BITS => {
                return try self.reader.interface.takeInt(i16, .little);
            },
            INT_PREFIX_32_BITS => {
                return try self.reader.interface.takeInt(i32, .little);
            },

            else => {
                const bytes = try self.readString();
                return std.fmt.parseInt(i64, bytes, 10);
            },
        }
    }

    fn readString(self: *Reader) ![]u8 {
        const len = try self.readLength();
        return self.reader.interface.take(len);
    }

    fn genericRead(self: *Reader) !ZedisValue {
        const first_byte = try self.reader.interface.peekByte();

        switch (first_byte) {
            INT_PREFIX_8_BITS, INT_PREFIX_16_BITS, INT_PREFIX_32_BITS => {
                const int = try self.readInt();
                return .{ .int = int };
            },
            else => {
                const str = try self.readString();
                return .{ .string = str };
            },
        }
    }
};

const testing = std.testing;

test "ZDB init and deinit" {
    const allocator = testing.allocator;

    var store = Store.init(allocator, 4096);
    defer store.deinit();
    const test_file = "test_db.rdb";

    var zdb = try Writer.init(allocator, &store, test_file);
    defer zdb.deinit();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    try testing.expect(zdb.allocator.ptr == allocator.ptr);
    try testing.expect(zdb.store == &store);
}

test "ZDB writeFile creates valid RDB header" {
    const allocator = testing.allocator;

    var store = Store.init(allocator, 4096);
    defer store.deinit();
    const test_file = "test_header.rdb";

    var zdb = try Writer.init(allocator, &store, test_file);
    defer zdb.deinit();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    try zdb.writeFile();

    const file_content = try std.fs.cwd().readFileAlloc(allocator, test_file, 1024);
    defer allocator.free(file_content);

    try testing.expect(std.mem.startsWith(u8, file_content, "REDIS0012"));
    try testing.expect(file_content[9] == 0xFA); // metadata marker
}

test "ZDB writeString writes correct format" {
    const allocator = testing.allocator;

    var store = Store.init(allocator, 4096);
    defer store.deinit();
    const test_file = "test_string.rdb";

    var zdb = try Writer.init(allocator, &store, test_file);
    defer zdb.deinit();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    try zdb.genericWrite(.{ .string = "test" });
    try zdb.writer.interface.flush();

    const file_content = try std.fs.cwd().readFileAlloc(allocator, test_file, 1024);
    defer allocator.free(file_content);

    try testing.expectEqual(@as(u8, 4), file_content[0]);
    try testing.expect(std.mem.eql(u8, file_content[1..5], "test"));
}

test "ZDB writeMetadata writes correct format" {
    const allocator = testing.allocator;

    var store = Store.init(allocator, 4096);
    defer store.deinit();
    const test_file = "test_string.rdb";

    var zdb = try Writer.init(allocator, &store, test_file);
    defer zdb.deinit();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const key = "test";
    const value = "random";
    try zdb.writeMetadata(key, .{ .string = value });
    try zdb.writer.interface.flush();

    const file_content = try std.fs.cwd().readFileAlloc(allocator, test_file, 1024);
    defer allocator.free(file_content);

    try testing.expectEqual(0xFA, file_content[0]);
    // Key
    try testing.expectEqual(key.len, file_content[1]);
    try testing.expect(std.mem.eql(u8, file_content[2..6], key));

    // Value
    try testing.expectEqual(value.len, file_content[key.len + 2]);

    const valueStart = 3 + key.len;
    const valueEnd = valueStart + value.len;
    try testing.expect(std.mem.eql(u8, file_content[valueStart..valueEnd], value));
}
