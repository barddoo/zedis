const std = @import("std");
const storeModule = @import("../store.zig");
const ZedisObject = storeModule.ZedisObject;
const Store = storeModule.Store;
const ZedisValue = storeModule.ZedisValue;
const ValueType = storeModule.ValueType;
const ZedisList = @import("../list.zig").ZedisList;
const ZedisListNode = @import("../list.zig").ZedisListNode;
const Config = @import("../config.zig");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const eql = mem.eql;
const Clock = @import("../clock.zig");

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
pub const RdbError = RdbWriteError || std.fmt.BufPrintError || error{WriteFailed};

pub const Writer = struct {
    allocator: mem.Allocator,
    buffer: []u8,
    file: Io.File,
    buffered_writer: Io.File.Writer,
    store: *Store,
    checksum: std.hash.crc.Crc64Redis,
    io: Io,

    fn map_to_op_code(val: ZedisValue) u8 {
        return switch (val) {
            .int, .string, .short_string => 0x00,
            .list => 0x01,
            .time_series => 0x0A,
            .bloom_filter => 0x0B,
            .search_index => 0x0C,
        };
    }

    // Helper functions to write data and update CRC checksum
    inline fn write_byte(self: *Writer, byte: u8) !void {
        self.checksum.update(&.{byte});
        try self.buffered_writer.interface.writeByte(byte);
    }

    inline fn write_int(self: *Writer, comptime T: type, value: T, endian: std.builtin.Endian) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        mem.writeInt(T, &buf, value, endian);
        self.checksum.update(&buf);
        try self.buffered_writer.interface.writeAll(&buf);
    }

    inline fn write_all(self: *Writer, bytes: []const u8) !void {
        self.checksum.update(bytes);
        try self.buffered_writer.interface.writeAll(bytes);
    }

    inline fn flush(self: *Writer) !void {
        try self.buffered_writer.interface.flush();
    }

    pub fn init(allocator: mem.Allocator, store: *Store, fileName: []const u8, config: Config, io: Io) !Writer {
        Dir.cwd().createDir(io, config.dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try Dir.cwd().openDir(io, config.dir, .{});
        dir.deleteFile(io, fileName) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const file = try dir.createFile(io, fileName, .{ .truncate = true });

        // Allocate buffer using configured size (default 256KB for optimal SSD throughput)
        const buffer = try allocator.alloc(u8, config.rdb_write_buffer_size);
        errdefer allocator.free(buffer);

        const buffered_writer = file.writer(io, buffer);

        return .{
            .allocator = allocator,
            .buffer = buffer,
            .file = file,
            .buffered_writer = buffered_writer,
            .store = store,
            .checksum = std.hash.crc.Crc64Redis.init(),
            .io = io,
        };
    }

    pub fn deinit(self: *Writer) void {
        _ = self.flush() catch {};
        self.file.close(self.io);
        self.allocator.free(self.buffer);
    }

    pub fn write_file(self: *Writer) !void {
        try self.write_header();
        try self.write_cache();
        try self.write_end_of_file();

        try self.flush();
    }

    fn write_header(self: *Writer) !void {
        try self.write_aux_fields();

        try self.write_byte(OPCODE_SELECT_DB);
        try self.write_length(0x00);

        try self.write_byte(OPCODE_RESIZE_DB);
        try self.write_length(self.store.size());
        // TODO Write the size of the expiry hash table
        try self.write_length(0);
    }

    fn write_end_of_file(self: *Writer) !void {
        try self.write_byte(OPCODE_EOF);

        // Get the accumulated checksum from all writes
        const checksum = self.checksum.final();

        // Write checksum directly (not included in checksum calculation)
        try self.buffered_writer.interface.writeInt(u64, checksum, .little);
    }

    fn write_aux_fields(self: *Writer) !void {
        try self.write_all("REDIS");
        try self.write_all("0012");

        try self.write_metadata("redis-ver", .{ .string = "255.255.255" });

        const bits = if (@sizeOf(usize) == 8) 64 else 32;
        try self.write_metadata("redis-bits", .{ .int = bits });

        const ts = self.store.clock.now();
        const now_timestamp = ts.toMilliseconds();
        try self.write_metadata("ctime", .{ .int = now_timestamp });

        // TODO
        try self.write_metadata("used-mem", .{ .int = 0 });

        // TODO
        try self.write_metadata("aof-base", .{ .int = 0 });
    }

    fn write_metadata(self: *Writer, key: []const u8, value: ZedisValue) !void {
        // 0xFA indicates auxiliary field; we encode key then value as length-prefixed strings.
        try self.write_byte(0xFA);
        try self.generic_write(.{ .string = key });
        try self.generic_write(value);
    }

    fn write_cache(self: *Writer) !void {
        var it = self.store.map.iterator();
        while (it.next()) |entry| {
            if (self.store.get_ttl(entry.key_ptr.*)) |expiry| {
                try self.write_byte(OPCODE_EXPIRE_TIME_MS);
                try self.write_int(i64, expiry, .little);
            }

            const value = entry.value_ptr.*.object.value;

            const op_code = Writer.map_to_op_code(value);
            try self.write_byte(op_code);

            try self.write_string(entry.value_ptr.*.key);

            switch (entry.value_ptr.*.object.value) {
                .int => |i| try self.write_int_value(i),
                .string => |s| try self.write_string(s),
                .short_string => |ss| try self.write_string(ss.as_slice()),
                .list => |list_ptr| try self.write_list(list_ptr),
                // TODO
                else => {},
            }
        }
    }

    fn write_length(self: *Writer, len: u64) RdbError!void {
        if (len <= 63) { // 6-bit
            try self.write_byte(@as(u8, @truncate(len)));
        } else if (len <= 16383) { // 14-bit
            const first_byte = 0b01000000 | @as(u8, @truncate(len >> 8));
            const second_byte = @as(u8, @truncate(len));
            try self.write_byte(first_byte);
            try self.write_byte(second_byte);
        } else if (len <= 0xFFFFFFFF) { // 32-bit
            try self.write_byte(LEN_PREFIX_32_INT);
            try self.write_int(u32, @intCast(len), .big);
        } else { // 64-bit
            try self.write_byte(LEN_PREFIX_64_INT);
            try self.write_int(u64, len, .big);
        }
    }

    fn write_string(self: *Writer, str: []const u8) RdbError!void {
        try self.write_length(str.len);
        try self.write_all(str);
    }

    fn write_list(self: *Writer, list: *ZedisList) RdbError!void {
        const len = list.len();
        try self.write_length(len);

        var current = list.list.first;
        while (current) |node| {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            const value = list_node.data;

            switch (value) {
                .int => |i| try self.write_int_value(i),
                .string => |s| try self.write_string(s),
                .short_string => |ss| try self.write_string(ss.as_slice()),
            }

            current = node.next;
        }
    }

    fn write_int_value(self: *Writer, number: i64) RdbError!void {
        if (number >= std.math.minInt(i8) and number <= std.math.maxInt(i8)) {
            // Can fit in i8
            try self.write_byte(INT_PREFIX_8_BITS);
            try self.write_int(i8, @intCast(number), .little);
        } else if (number >= std.math.minInt(i16) and number <= std.math.maxInt(i16)) {
            // Can fit in i16
            try self.write_byte(INT_PREFIX_16_BITS);
            try self.write_int(i16, @intCast(number), .little);
        } else if (number >= std.math.minInt(i32) and number <= std.math.maxInt(i32)) {
            // Can fit in i32
            try self.write_byte(INT_PREFIX_32_BITS);
            try self.write_int(i32, @intCast(number), .little);
        } else {
            // Fallback for larger numbers (i64) or any number that doesn't fit
            // the above: write as a length-prefixed string.
            var buf: [20]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{}", .{number});
            try self.write_string(str);
        }
    }

    fn generic_write(self: *Writer, payload: ZedisValue) RdbError!void {
        switch (payload) {
            .int => |number| try self.write_int_value(number),
            .string => |str| try self.write_string(str),
            .short_string => |ss| try self.write_string(ss.as_slice()),
            .list => |list_ptr| try self.write_list(list_ptr),
            else => {},
        }
    }
};

pub const Reader = struct {
    allocator: mem.Allocator,
    buffer: []u8,
    file: Io.File,
    reader: Io.File.Reader,
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

    pub fn init(allocator: mem.Allocator, store: *Store) !Reader {
        const file = try Dir.cwd().openFile(DEFAULT_FILE_NAME, .{});

        const buffer = try allocator.alloc(u8, 1024 * 100);

        const reader = file.reader(buffer);

        return .{ .allocator = allocator, .buffer = buffer, .store = store, .file = file, .reader = reader };
    }

    pub fn rdb_file_exists() bool {
        Dir.cwd().access(DEFAULT_FILE_NAME, .{}) catch {
            return false;
        };

        return true;
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.buffer);
        self.file.close();
    }

    pub fn read_file(self: *Reader) !RdbReaderOutput {
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
                    const key = try self.read_string();

                    if (eql(u8, key, "redis-ver")) {
                        output.redis_version = try self.read_string();
                    } else if (eql(u8, key, "redis-bits")) {
                        output.redis_bits = try self.read_int();
                    } else if (eql(u8, key, "ctime")) {
                        output.ctime = try self.read_int();
                    } else if (eql(u8, key, "used-mem")) {
                        output.used_mem = try self.read_int();
                    } else if (eql(u8, key, "aof-base")) {
                        output.aof_base = try self.read_int();
                    }
                },
                OPCODE_RESIZE_DB => {
                    output.resize_db = try self.read_length();
                    output.resize_db_expiration = try self.read_length();
                },
                OPCODE_SELECT_DB => {
                    output.select_db = try self.read_length();
                },

                OPCODE_EXPIRE_TIME_MS => {
                    const expiration = try self.reader.interface.takeInt(u64, .little);
                    const op_code = try self.reader.interface.takeByte();
                    // TODO Load expiration time
                    _ = expiration;
                    _ = op_code;
                    try self.read_entry();
                },
                VALUE_TYPE_STR => {
                    try self.read_entry();
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

    fn read_entry(self: *Reader) !void {
        const key = try self.read_string();
        const value = try self.generic_read();

        try self.store.put_object(key, .{ .value = value });
    }

    fn assert(incoming_byes: []u8, expected: []const u8) void {
        std.debug.assert(mem.eql(u8, incoming_byes, expected));
    }

    fn read_length(self: *Reader) !u64 {
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

    fn read_int(self: *Reader) !i64 {
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
                const bytes = try self.read_string();
                return std.fmt.parseInt(i64, bytes, 10);
            },
        }
    }

    fn read_string(self: *Reader) ![]u8 {
        const len = try self.read_length();
        return self.reader.interface.take(len);
    }

    fn generic_read(self: *Reader) !ZedisValue {
        const first_byte = try self.reader.interface.peekByte();

        switch (first_byte) {
            INT_PREFIX_8_BITS, INT_PREFIX_16_BITS, INT_PREFIX_32_BITS => {
                const int = try self.read_int();
                return .{ .int = int };
            },
            else => {
                const str = try self.read_string();
                return .{ .string = str };
            },
        }
    }
};

const testing = std.testing;

test "ZDB init and deinit" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();
    const test_file = "test_db.rdb";

    const config = Config{};
    var zdb = try Writer.init(allocator, &store, test_file, config, testing.io);
    defer zdb.deinit();
    defer Dir.cwd().deleteFile(testing.io, test_file) catch {};

    try testing.expect(zdb.allocator.ptr == allocator.ptr);
    try testing.expect(zdb.store == &store);
}

test "ZDB write_file creates valid RDB header" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();
    const test_file = "test_header.rdb";

    const config = Config{};
    var zdb = try Writer.init(allocator, &store, test_file, config, testing.io);
    defer zdb.deinit();
    defer Dir.cwd().deleteFile(testing.io, test_file) catch {};

    try zdb.write_file();

    const file_content = try Dir.cwd().readFileAlloc(testing.io, test_file, allocator, .unlimited);
    defer allocator.free(file_content);

    try testing.expect(mem.startsWith(u8, file_content, "REDIS0012"));
    try testing.expect(file_content[9] == 0xFA); // metadata marker
}

test "ZDB write_string writes correct format" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();
    const test_file = "test_string.rdb";

    const config = Config{};
    var zdb = try Writer.init(allocator, &store, test_file, config, testing.io);
    defer zdb.deinit();
    defer Dir.cwd().deleteFile(testing.io, test_file) catch {};

    try zdb.generic_write(.{ .string = "test" });
    try zdb.flush();
    try zdb.file.sync(testing.io);

    const file_content = try Dir.cwd().readFileAlloc(testing.io, test_file, allocator, .unlimited);
    defer allocator.free(file_content);

    try testing.expectEqual(@as(u8, 4), file_content[0]);
    try testing.expect(mem.eql(u8, file_content[1..5], "test"));
}

test "ZDB write_metadata writes correct format" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();
    const test_file = "test_string.rdb";

    const config = Config{};
    var zdb = try Writer.init(allocator, &store, test_file, config, testing.io);
    defer zdb.deinit();
    defer Dir.cwd().deleteFile(testing.io, test_file) catch {};

    const key = "test";
    const value = "random";
    try zdb.write_metadata(key, .{ .string = value });
    try zdb.flush();
    try zdb.file.sync(testing.io);

    const file_content = try Dir.cwd().readFileAlloc(testing.io, test_file, allocator, .unlimited);
    defer allocator.free(file_content);

    try testing.expectEqual(0xFA, file_content[0]);
    // Key
    try testing.expectEqual(key.len, file_content[1]);
    try testing.expect(mem.eql(u8, file_content[2..6], key));

    // Value
    try testing.expectEqual(value.len, file_content[key.len + 2]);

    const valueStart = 3 + key.len;
    const valueEnd = valueStart + value.len;
    try testing.expect(mem.eql(u8, file_content[valueStart..valueEnd], value));
}
