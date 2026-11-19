const std = @import("std");
const storeModule = @import("../storage/store.zig");
const ZedisObject = storeModule.ZedisObject;
const Store = storeModule.Store;
const ZedisValue = storeModule.ZedisValue;
const ValueType = storeModule.ValueType;
const ZedisList = @import("../storage/list.zig").ZedisList;
const ZedisListNode = @import("../storage/list.zig").ZedisListNode;
const ZedisHash = @import("../storage/hash.zig").ZedisHash;
const ZedisSet = @import("../storage/set.zig").ZedisSet;
const ZedisZSet = @import("../storage/zset.zig").ZedisZSet;
const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;
const TimeSeries = @import("../storage/time_series.zig").TimeSeries;
const Config = @import("../app/config.zig");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const eql = mem.eql;
const Clock = @import("../app/clock.zig");

const Crc64 = @import("../util/crc64.zig");

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
const VALUE_TYPE_LIST = 0x01;
const VALUE_TYPE_TIME_SERIES = 0x0A;
const VALUE_TYPE_BLOOM = 0x0B;
const VALUE_TYPE_SEARCH = 0x0C;
const VALUE_TYPE_HASH = 0x0D;
const VALUE_TYPE_SET = 0x0E;
const VALUE_TYPE_ZSET = 0x0F;

pub const RdbWriteError = error{ StringTooLarge, NumberTooLarge };
pub const RdbError = RdbWriteError || std.fmt.BufPrintError || error{WriteFailed};

pub const Writer = struct {
    allocator: mem.Allocator,
    buffer: []u8,
    file: Io.File,
    buffered_writer: Io.File.Writer,
    store: *Store,
    checksum: Crc64,
    io: Io,

    fn map_to_op_code(val: ZedisValue) u8 {
        return switch (val) {
            .int, .string, .short_string => 0x00,
            .list => 0x01,
            .time_series => 0x0A,
            .bloom_filter => 0x0B,
            .search_index => 0x0C,
            .hash_map => 0x0D,
            .set => 0x0E,
            .zset => 0x0F,
        };
    }

    inline fn write_byte(self: *Writer, byte: u8) !void {
        self.checksum.updateByte(byte);
        try self.buffered_writer.interface.writeByte(byte);
    }

    inline fn write_int(self: *Writer, comptime T: type, value: T, endian: std.lang.Endian) !void {
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
        // Refuse before touching the old snapshot: the file is truncated and
        // recreated below, so a dataset this format cannot express must not
        // delete the previous dump.
        try check_supported(store);

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
            .checksum = Crc64.init(),
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
        var it = self.store.iterator();
        while (it.next()) |entry| {
            if (entry.expires_at) |expiry| {
                try self.write_byte(OPCODE_EXPIRE_TIME_MS);
                try self.write_int(i64, expiry, .little);
            }

            const value = entry.object.value;

            const op_code = Writer.map_to_op_code(value);
            try self.write_byte(op_code);

            try self.write_string(entry.key);
            try self.write_value(value);
        }
    }

    fn write_value(self: *Writer, value: ZedisValue) RdbError!void {
        switch (value) {
            .int => |i| try self.write_int_value(i),
            .string => |s| try self.write_string(s),
            .short_string => |ss| try self.write_string(ss.as_slice()),
            .list => |list_ptr| try self.write_list(list_ptr),
            .hash_map => |hash| try self.write_hash(hash),
            .set => |set| try self.write_set(set),
            .zset => |zset| try self.write_zset(zset),
            .time_series, .bloom_filter, .search_index => unreachable, // check_supported
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
            try self.write_primitive(list_node.data);
            current = node.next;
        }
    }

    fn write_hash(self: *Writer, hash: *ZedisHash) RdbError!void {
        try self.write_length(hash.hlen());
        var it = hash.iterator();
        while (it.next()) |entry| {
            try self.write_string(entry.key_ptr.*);
            try self.write_primitive(entry.value_ptr.*);
        }
    }

    fn write_set(self: *Writer, set: *ZedisSet) RdbError!void {
        try self.write_length(set.len());
        var it = set.iterator();
        while (it.next()) |member| try self.write_string(member.*);
    }

    /// Members are written in score order with the score as its IEEE-754 bits,
    /// so a reload keeps exact scores and determinism.
    fn write_zset(self: *Writer, zset: *ZedisZSet) RdbError!void {
        try self.write_length(zset.len());
        for (zset.order.items) |entry| {
            try self.write_string(entry.member);
            try self.write_int(u64, @bitCast(entry.score), .little);
        }
    }

    fn write_primitive(self: *Writer, value: PrimitiveValue) RdbError!void {
        switch (value) {
            .int => |i| try self.write_int_value(i),
            .string => |s| try self.write_string(s),
            .short_string => |ss| try self.write_string(ss.as_slice()),
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
            .hash_map => |hash| try self.write_hash(hash),
            .set => |set| try self.write_set(set),
            .zset => |zset| try self.write_zset(zset),
            .time_series, .bloom_filter, .search_index => unreachable, // check_supported
        }
    }
};

fn check_supported(store: *Store) error{UnsupportedType}!void {
    var it = store.iterator();
    while (it.next()) |entry| {
        switch (entry.object.value) {
            .time_series, .bloom_filter, .search_index => {
                std.log.scoped(.zdb).warn("RDB cannot store {s} key '{s}'", .{
                    @tagName(entry.object.value),
                    entry.key,
                });
                return error.UnsupportedType;
            },
            else => {},
        }
    }
}

pub const Reader = struct {
    allocator: mem.Allocator,
    buffer: []u8,
    file: Io.File,
    reader: Io.File.Reader,
    store: *Store,
    io: Io,

    const ReaderError = error{ MalformedRDB, UnknownLengthPrefix, UnsupportedType };

    pub const RdbReaderOutput = struct {
        ctime: i64,
    };

    pub fn init(allocator: mem.Allocator, store: *Store, io: Io, dir_path: []const u8, file_name: []const u8) !Reader {
        const dir = try Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        const file = try dir.openFile(io, file_name, .{});

        const buffer = try allocator.alloc(u8, 100 * 1024);
        errdefer allocator.free(buffer);

        return .{
            .allocator = allocator,
            .buffer = buffer,
            .file = file,
            .reader = file.reader(io, buffer),
            .store = store,
            .io = io,
        };
    }

    pub fn fileExists(io: Io, dir_path: []const u8, file_name: []const u8) bool {
        const dir = Dir.cwd().openDir(io, dir_path, .{}) catch return false;
        defer dir.close(io);
        dir.access(io, file_name, .{}) catch return false;
        return true;
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.buffer);
        self.file.close(self.io);
    }

    pub fn read_file(self: *Reader) !RdbReaderOutput {
        const magic = try self.reader.interface.takeArray(5);
        if (!mem.eql(u8, magic, "REDIS")) return error.MalformedRDB;
        _ = try self.reader.interface.takeArray(4);

        var ctime: i64 = 0;
        var pending_expiry: ?i64 = null;

        while (true) {
            const byte = try self.reader.interface.takeByte();
            switch (byte) {
                OPCODE_AUX => {
                    const key = try self.read_string_alloc();
                    defer self.allocator.free(key);
                    if (eql(u8, key, "ctime")) {
                        ctime = try self.read_int();
                    } else {
                        try self.skip_scalar();
                    }
                },
                OPCODE_RESIZE_DB => {
                    _ = try self.read_length();
                    _ = try self.read_length();
                },
                OPCODE_SELECT_DB => _ = try self.read_length(),

                OPCODE_EXPIRE_TIME_MS => pending_expiry = try self.reader.interface.takeInt(i64, .little),
                OPCODE_EXPIRE_TIME => pending_expiry = @as(i64, try self.reader.interface.takeInt(i32, .little)) * 1000,

                VALUE_TYPE_STR => try self.read_string_entry(pending_expiry),
                VALUE_TYPE_LIST => try self.read_list_entry(pending_expiry),
                VALUE_TYPE_HASH => try self.read_hash_entry(pending_expiry),
                VALUE_TYPE_SET => try self.read_set_entry(pending_expiry),
                VALUE_TYPE_ZSET => try self.read_zset_entry(pending_expiry),

                VALUE_TYPE_TIME_SERIES,
                VALUE_TYPE_BLOOM,
                VALUE_TYPE_SEARCH,
                => return error.UnsupportedType,

                OPCODE_EOF => break,
                else => return error.MalformedRDB,
            }
            if (byte != OPCODE_EXPIRE_TIME_MS and byte != OPCODE_EXPIRE_TIME) pending_expiry = null;
        }
        return .{ .ctime = ctime };
    }

    fn read_string_entry(self: *Reader, expiry: ?i64) !void {
        const key = try self.read_string_alloc();
        defer self.allocator.free(key);

        if (self.isInt()) {
            try self.store.set_int(key, try self.read_int());
        } else {
            const value = try self.read_string_alloc();
            defer self.allocator.free(value);
            try self.store.set(key, value);
        }
        try self.apply_expiry(key, expiry);
    }

    fn read_list_entry(self: *Reader, expiry: ?i64) !void {
        const key = try self.read_string_alloc();
        defer self.allocator.free(key);

        const len = try self.read_length();
        const list = try self.store.create_list(key);
        var i: u64 = 0;
        while (i < len) : (i += 1) {
            var value = try self.read_primitive();
            errdefer value.deinit(self.store.allocator);
            try list.append(value);
        }
        try self.apply_expiry(key, expiry);
    }

    fn read_hash_entry(self: *Reader, expiry: ?i64) !void {
        const key = try self.read_string_alloc();
        defer self.allocator.free(key);

        const len = try self.read_length();
        const hash = try self.store.create_hash(key);
        var i: u64 = 0;
        while (i < len) : (i += 1) {
            const field = try self.read_string_alloc();
            defer self.allocator.free(field);
            var value = try self.read_primitive();
            errdefer value.deinit(self.store.allocator);
            _ = try hash.hset(field, value);
        }
        try self.apply_expiry(key, expiry);
    }

    fn read_set_entry(self: *Reader, expiry: ?i64) !void {
        const key = try self.read_string_alloc();
        defer self.allocator.free(key);

        const len = try self.read_length();
        const set = try self.store.create_set(key);
        var i: u64 = 0;
        while (i < len) : (i += 1) {
            const member = try self.read_string_alloc();
            defer self.allocator.free(member);
            _ = try set.add(member);
        }
        try self.apply_expiry(key, expiry);
    }

    fn read_zset_entry(self: *Reader, expiry: ?i64) !void {
        const key = try self.read_string_alloc();
        defer self.allocator.free(key);

        const len = try self.read_length();
        const zset = try self.store.create_zset(key);
        var i: u64 = 0;
        while (i < len) : (i += 1) {
            const member = try self.read_string_alloc();
            defer self.allocator.free(member);
            const bits = try self.reader.interface.takeInt(u64, .little);
            _ = try zset.add(member, @bitCast(bits));
        }
        try self.apply_expiry(key, expiry);
    }

    fn apply_expiry(self: *Reader, key: []const u8, expiry: ?i64) !void {
        const at = expiry orelse return;
        if (at <= self.store.clock.now().toMilliseconds()) {
            _ = self.store.delete(key);
            return;
        }
        _ = try self.store.expire(key, at);
    }

    fn read_length(self: *Reader) !u64 {
        const first_byte = try self.reader.interface.takeByte();

        switch (first_byte) {
            0x00...0x3F => return first_byte,
            0x40...0x7F => {
                const high: u64 = first_byte & 0x3F;
                const low: u64 = try self.reader.interface.takeByte();
                return (high << 8) | low;
            },
            LEN_PREFIX_32_INT => return try self.reader.interface.takeInt(u32, .big),
            LEN_PREFIX_64_INT => return try self.reader.interface.takeInt(u64, .big),
            else => return error.UnknownLengthPrefix,
        }
    }

    fn isInt(self: *Reader) bool {
        const first = self.reader.interface.peekByte() catch return false;
        return first == INT_PREFIX_8_BITS or first == INT_PREFIX_16_BITS or first == INT_PREFIX_32_BITS;
    }

    fn read_int(self: *Reader) !i64 {
        const first = try self.reader.interface.takeByte();
        return switch (first) {
            INT_PREFIX_8_BITS => try self.reader.interface.takeInt(i8, .little),
            INT_PREFIX_16_BITS => try self.reader.interface.takeInt(i16, .little),
            INT_PREFIX_32_BITS => try self.reader.interface.takeInt(i32, .little),
            else => blk: {
                // Not an int marker: the byte was the string's length prefix.
                const len: u64 = switch (first) {
                    0x00...0x3F => first,
                    0x40...0x7F => (@as(u64, first & 0x3F) << 8) | try self.reader.interface.takeByte(),
                    LEN_PREFIX_32_INT => try self.reader.interface.takeInt(u32, .big),
                    LEN_PREFIX_64_INT => try self.reader.interface.takeInt(u64, .big),
                    else => return error.UnknownLengthPrefix,
                };
                const n = std.math.cast(usize, len) orelse return error.MalformedRDB;
                const bytes = try self.reader.interface.readAllocAll(self.allocator, n);
                defer self.allocator.free(bytes);
                break :blk std.fmt.parseInt(i64, bytes, 10);
            },
        };
    }

    fn read_string_alloc(self: *Reader) ![]u8 {
        const len = try self.read_length();
        const n = std.math.cast(usize, len) orelse return error.MalformedRDB;
        return self.reader.interface.readAllocAll(self.allocator, n);
    }

    fn read_primitive(self: *Reader) !PrimitiveValue {
        if (self.isInt()) return .{ .int = try self.read_int() };
        const bytes = try self.read_string_alloc();
        defer self.allocator.free(bytes);
        return PrimitiveValue.from_slice(bytes, self.store.allocator);
    }

    fn skip_scalar(self: *Reader) !void {
        if (self.isInt()) {
            _ = try self.read_int();
            return;
        }
        const bytes = try self.read_string_alloc();
        self.allocator.free(bytes);
    }
};
const testing = std.testing;

test "RDB round-trips strings, lists, hashes, sets and sorted sets with TTLs" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var source = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer source.deinit();

    try source.set("str", "value");
    try source.set_int("num", 42);

    const list = try source.create_list("list");
    try list.append(try PrimitiveValue.from_slice("first", source.allocator));
    try list.append(.{ .int = -7 });

    const hash = try source.create_hash("hash");
    _ = try hash.hset("field", try PrimitiveValue.from_slice("value", source.allocator));

    const set = try source.create_set("set");
    _ = try set.add("a");
    _ = try set.add("b");

    const zset = try source.create_zset("zset");
    _ = try zset.add("low", -2.25);
    _ = try zset.add("high", 1.5);

    const expiry = clock.now().toMilliseconds() + 60_000;
    _ = try source.expire("set", expiry);

    const dir_name = "test-zdb-roundtrip";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var writer = try Writer.init(allocator, &source, "dump.rdb", .{ .dir = dir_name }, testing.io);
    try writer.write_file();
    writer.deinit();

    var target = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer target.deinit();

    var reader = try Reader.init(allocator, &target, testing.io, dir_name, "dump.rdb");
    defer reader.deinit();
    _ = try reader.read_file();

    const asString = struct {
        fn get(value: ZedisValue) []const u8 {
            return switch (value) {
                .string => |s| s,
                .short_string => |ss| ss.as_slice(),
                else => unreachable,
            };
        }
    }.get;
    const asPrimitiveString = struct {
        fn get(value: PrimitiveValue) []const u8 {
            return switch (value) {
                .string => |s| s,
                .short_string => |ss| ss.as_slice(),
                else => unreachable,
            };
        }
    }.get;

    try testing.expectEqualStrings("value", asString(target.get("str").?.value));
    try testing.expectEqual(@as(i64, 42), target.get("num").?.value.int);

    const restored_list = (try target.get_list("list")).?;
    try testing.expectEqual(@as(usize, 2), restored_list.len());
    try testing.expectEqualStrings("first", asPrimitiveString(restored_list.get_by_index(0).?));
    try testing.expectEqual(@as(i64, -7), restored_list.get_by_index(1).?.int);

    const restored_hash = (try target.get_hash("hash")).?;
    try testing.expectEqualStrings("value", asPrimitiveString(restored_hash.hget("field").?));

    const restored_set = (try target.get_set("set")).?;
    try testing.expect(restored_set.contains("a"));
    try testing.expect(restored_set.contains("b"));
    try testing.expectEqual(expiry, target.get_ttl("set").?);

    const restored_zset = (try target.get_zset("zset")).?;
    try testing.expectEqual(@as(?f64, -2.25), restored_zset.score("low"));
    try testing.expectEqual(@as(?f64, 1.5), restored_zset.score("high"));
}

test "SAVE refuses a dataset holding a time series and keeps the old snapshot" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var source = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer source.deinit();

    const dir_name = "test-zdb-unsupported";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    try source.set("keep", "me");
    var first = try Writer.init(allocator, &source, "dump.rdb", .{ .dir = dir_name }, testing.io);
    try first.write_file();
    first.deinit();

    try source.create_time_series("ts", try TimeSeries.init(allocator, 0, null, 1024, null, null, null));

    try testing.expectError(error.UnsupportedType, Writer.init(allocator, &source, "dump.rdb", .{ .dir = dir_name }, testing.io));

    var target = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer target.deinit();
    var reader = try Reader.init(allocator, &target, testing.io, dir_name, "dump.rdb");
    defer reader.deinit();
    _ = try reader.read_file();
    try testing.expectEqualStrings("me", target.get("keep").?.value.short_string.as_slice());
}

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
    try testing.expectEqual(key.len, file_content[1]);
    try testing.expect(mem.eql(u8, file_content[2..6], key));

    try testing.expectEqual(value.len, file_content[key.len + 2]);

    const valueStart = 3 + key.len;
    const valueEnd = valueStart + value.len;
    try testing.expect(mem.eql(u8, file_content[valueStart..valueEnd], value));
}
