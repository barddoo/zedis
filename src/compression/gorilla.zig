const std = @import("std");
const eql = std.mem.eql;

const BitStream = struct {
    buffer: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,
    // Bit position in the stream
    bit_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator) BitStream {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BitStream) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn write_bit(self: *BitStream, bit: u1) !void {
        if (self.bit_offset == 0) {
            try self.buffer.append(self.allocator, 0);
        }
        const last_byte = &self.buffer.items[self.buffer.items.len - 1];
        if (bit == 1) {
            // Write MSB-first (standard bit stream convention)
            const shift: u3 = @intCast(7 - self.bit_offset);
            last_byte.* |= (@as(u8, 1) << shift);
        }
        self.bit_offset = (self.bit_offset + 1) % 8;
    }

    pub fn write_bits(self: *BitStream, value: u64, num_bits: u8) !void {
        var i: u8 = 0;
        while (i < num_bits) : (i += 1) {
            // Write from MSB to LSB (most significant bit first)
            const shift_amount: u6 = @intCast(num_bits - 1 - i);
            const bit: u1 = @intCast((value >> shift_amount) & 1);
            try self.write_bit(bit);
        }
    }

    pub fn read_bit(self: *BitStream) !u1 {
        const byte_index = self.bit_offset / 8;
        const bit_in_byte = self.bit_offset % 8;

        if (byte_index >= self.buffer.items.len) {
            return error.EndOfStream;
        }

        const byte = self.buffer.items[byte_index];
        const shift: u3 = @intCast(7 - bit_in_byte);
        const bit: u1 = @intCast((byte >> shift) & 1);
        self.bit_offset += 1;

        return bit;
    }

    pub fn read_bits(self: *BitStream, num_bits: u8) !u64 {
        var result: u64 = 0;
        var i: u8 = 0;
        while (i < num_bits) : (i += 1) {
            const bit = try self.read_bit();
            result = (result << 1) | bit;
        }
        return result;
    }

    pub fn reset_read(self: *BitStream) void {
        self.bit_offset = 0;
    }

    pub fn toOwnedSlice(self: *BitStream) ![]u8 {
        return self.buffer.toOwnedSlice();
    }

    pub fn items(self: *const BitStream) []const u8 {
        return self.buffer.items;
    }
};

const TimestampCompressor = struct {
    last_ts: i64 = 0,
    previous_delta: i64 = 0,
    count: u64 = 0,
    stream: *BitStream,

    pub fn init(stream: *BitStream) TimestampCompressor {
        return .{ .stream = stream };
    }

    pub fn add(self: *TimestampCompressor, timestamp: i64) !void {
        if (self.count == 0) {
            try self.stream.write_bits(@bitCast(timestamp), 64);
        } else if (self.count == 1) {
            const delta = timestamp - self.last_ts;
            const delta_truncated: i14 = @truncate(delta);
            const delta_u14: u14 = @bitCast(delta_truncated);
            try self.stream.write_bits(delta_u14, 14);
            self.previous_delta = delta;
        } else {
            const delta = timestamp - self.last_ts;
            const delta_of_delta = delta - self.previous_delta;

            if (delta_of_delta == 0) {
                try self.stream.write_bit(0);
            } else if (delta_of_delta >= -63 and delta_of_delta <= 64) {
                try self.stream.write_bits(0b10, 2);
                const dod_truncated: i7 = @truncate(delta_of_delta);
                const dod_u7: u7 = @bitCast(dod_truncated);
                try self.stream.write_bits(dod_u7, 7);
            } else if (delta_of_delta >= -255 and delta_of_delta <= 256) {
                try self.stream.write_bits(0b110, 3);
                const dod_truncated: i9 = @truncate(delta_of_delta);
                const dod_u9: u9 = @bitCast(dod_truncated);
                try self.stream.write_bits(dod_u9, 9);
            } else if (delta_of_delta >= -2047 and delta_of_delta <= 2048) {
                try self.stream.write_bits(0b1110, 4);
                const dod_truncated: i12 = @truncate(delta_of_delta);
                const dod_u12: u12 = @bitCast(dod_truncated);
                try self.stream.write_bits(dod_u12, 12);
            } else {
                try self.stream.write_bits(0b1111, 4);
                const dod_truncated: i32 = @truncate(delta_of_delta);
                const dod_u32: u32 = @bitCast(dod_truncated);
                try self.stream.write_bits(dod_u32, 32);
            }
            self.previous_delta = delta;
        }
        self.last_ts = timestamp;
        self.count += 1;
    }
};

const TimestampDecompressor = struct {
    last_ts: i64 = 0,
    previous_delta: i64 = 0,
    count: u64 = 0,
    stream: *BitStream,

    pub fn init(stream: *BitStream) TimestampDecompressor {
        return .{ .stream = stream };
    }

    pub fn next(self: *TimestampDecompressor) !i64 {
        if (self.count == 0) {
            const ts_bits = try self.stream.read_bits(64);
            self.last_ts = @bitCast(ts_bits);
        } else if (self.count == 1) {
            const delta_bits = try self.stream.read_bits(14);
            const delta_u14: u14 = @truncate(delta_bits);
            const delta_i14: i14 = @bitCast(delta_u14);
            self.previous_delta = delta_i14;
            self.last_ts += self.previous_delta;
        } else {
            const first_bit = try self.stream.read_bit();
            if (first_bit == 0) {
                // delta_of_delta == 0
                self.last_ts += self.previous_delta;
            } else {
                const second_bit = try self.stream.read_bit();
                if (second_bit == 0) {
                    // 7-bit delta_of_delta
                    const dod_bits = try self.stream.read_bits(7);
                    const dod_u7: u7 = @truncate(dod_bits);
                    const dod_i7: i7 = @bitCast(dod_u7);
                    const delta_of_delta: i64 = dod_i7;
                    self.previous_delta += delta_of_delta;
                    self.last_ts += self.previous_delta;
                } else {
                    const third_bit = try self.stream.read_bit();
                    if (third_bit == 0) {
                        // 9-bit delta_of_delta
                        const dod_bits = try self.stream.read_bits(9);
                        const dod_u9: u9 = @truncate(dod_bits);
                        const dod_i9: i9 = @bitCast(dod_u9);
                        const delta_of_delta: i64 = dod_i9;
                        self.previous_delta += delta_of_delta;
                        self.last_ts += self.previous_delta;
                    } else {
                        const fourth_bit = try self.stream.read_bit();
                        if (fourth_bit == 0) {
                            // 12-bit delta_of_delta
                            const dod_bits = try self.stream.read_bits(12);
                            const dod_u12: u12 = @truncate(dod_bits);
                            const dod_i12: i12 = @bitCast(dod_u12);
                            const delta_of_delta: i64 = dod_i12;
                            self.previous_delta += delta_of_delta;
                            self.last_ts += self.previous_delta;
                        } else {
                            // 32-bit delta_of_delta
                            const dod_bits = try self.stream.read_bits(32);
                            const dod_u32: u32 = @truncate(dod_bits);
                            const dod_i32: i32 = @bitCast(dod_u32);
                            const delta_of_delta: i64 = dod_i32;
                            self.previous_delta += delta_of_delta;
                            self.last_ts += self.previous_delta;
                        }
                    }
                }
            }
        }
        self.count += 1;
        return self.last_ts;
    }
};

const ValueCompressor = struct {
    last_value_bits: u64 = 0,
    last_leading_zeros: u8 = 0,
    last_trailing_zeros: u8 = 0,
    count: u64 = 0,
    stream: *BitStream,

    pub fn init(stream: *BitStream) ValueCompressor {
        return .{ .stream = stream };
    }

    pub fn add(self: *ValueCompressor, value: f64) !void {
        const value_bits: u64 = @bitCast(value);
        if (self.count == 0) {
            try self.stream.write_bits(value_bits, 64);
        } else {
            const xor = value_bits ^ self.last_value_bits;

            if (xor == 0) {
                try self.stream.write_bit(0);
            } else {
                const new_leading_zeros = @clz(xor);
                const new_trailing_zeros = @ctz(xor);

                // Note: XOR can never be all zeros here (checked above), so len_meaningful > 0
                if (new_leading_zeros >= self.last_leading_zeros and
                    new_trailing_zeros >= self.last_trailing_zeros)
                {
                    // Case 1: Meaningful bits fit inside previous block
                    try self.stream.write_bits(0b10, 2);
                    const len_meaningful = 64 - self.last_leading_zeros - self.last_trailing_zeros;
                    if (self.last_trailing_zeros < 64) {
                        const shift_amount: u6 = @intCast(self.last_trailing_zeros);
                        const meaningful_bits = xor >> shift_amount;
                        try self.stream.write_bits(meaningful_bits, len_meaningful);
                    } else {
                        // Trailing zeros >= 64 means the whole value is zeros, which shouldn't happen here
                        try self.stream.write_bits(0, len_meaningful);
                    }
                } else {
                    // Case 2: New position for meaningful bits
                    try self.stream.write_bits(0b11, 2);
                    const len_meaningful = 64 - new_leading_zeros - new_trailing_zeros;
                    try self.stream.write_bits(new_leading_zeros, 5);
                    try self.stream.write_bits(len_meaningful, 6);
                    if (new_trailing_zeros < 64) {
                        const shift_amount: u6 = @intCast(new_trailing_zeros);
                        const meaningful_bits = xor >> shift_amount;
                        try self.stream.write_bits(meaningful_bits, len_meaningful);
                    } else {
                        // Trailing zeros >= 64 means the whole value is zeros, which shouldn't happen here
                        try self.stream.write_bits(0, len_meaningful);
                    }
                }
                self.last_leading_zeros = new_leading_zeros;
                self.last_trailing_zeros = new_trailing_zeros;
            }
        }
        self.last_value_bits = value_bits;
        self.count += 1;
    }
};

const ValueDecompressor = struct {
    last_value_bits: u64 = 0,
    last_leading_zeros: u8 = 0,
    last_trailing_zeros: u8 = 0,
    count: u64 = 0,
    stream: *BitStream,

    pub fn init(stream: *BitStream) ValueDecompressor {
        return .{ .stream = stream };
    }

    pub fn next(self: *ValueDecompressor) !f64 {
        if (self.count == 0) {
            self.last_value_bits = try self.stream.read_bits(64);
        } else {
            const first_bit = try self.stream.read_bit();
            if (first_bit == 0) {
                // Value unchanged
            } else {
                const second_bit = try self.stream.read_bit();
                if (second_bit == 0) {
                    // Use previous block position
                    const len_meaningful = 64 - self.last_leading_zeros - self.last_trailing_zeros;
                    if (len_meaningful > 0) {
                        const meaningful_bits = try self.stream.read_bits(len_meaningful);
                        // Safe shift: if trailing_zeros >= 64, result would be 0 anyway
                        const xor = if (self.last_trailing_zeros < 64)
                            meaningful_bits << @as(u6, @intCast(self.last_trailing_zeros))
                        else
                            0;
                        self.last_value_bits ^= xor;
                    }
                } else {
                    // New block position
                    const leading_zeros = try self.stream.read_bits(5);
                    const len_meaningful = try self.stream.read_bits(6);

                    self.last_leading_zeros = @intCast(leading_zeros);
                    self.last_trailing_zeros = 64 - self.last_leading_zeros - @as(u8, @intCast(len_meaningful));

                    if (len_meaningful > 0) {
                        const meaningful_bits = try self.stream.read_bits(@intCast(len_meaningful));
                        // Safe shift: if trailing_zeros >= 64, result would be 0 anyway
                        const xor = if (self.last_trailing_zeros < 64)
                            meaningful_bits << @as(u6, @intCast(self.last_trailing_zeros))
                        else
                            0;
                        self.last_value_bits ^= xor;
                    }
                }
            }
        }
        self.count += 1;
        return @bitCast(self.last_value_bits);
    }
};

// This struct holds the state for compressing a single chunk.
pub const ChunkCompressor = struct {
    stream: BitStream,
    ts_compressor: TimestampCompressor,
    val_compressor: ValueCompressor,

    pub fn init(allocator: std.mem.Allocator) ChunkCompressor {
        return .{
            .stream = BitStream.init(allocator),
            // Initialize with dummy pointers, will be fixed in add()
            .ts_compressor = .{ .stream = undefined, .last_ts = 0, .previous_delta = 0, .count = 0 },
            .val_compressor = .{ .stream = undefined, .last_value_bits = 0, .last_leading_zeros = 0, .last_trailing_zeros = 0, .count = 0 },
        };
    }

    pub fn deinit(self: *ChunkCompressor) void {
        self.stream.deinit();
    }

    pub fn add(self: *ChunkCompressor, timestamp: i64, value: f64) !void {
        // Fix pointers on every call (they point to self.stream which is stable once self is allocated)
        self.ts_compressor.stream = &self.stream;
        self.val_compressor.stream = &self.stream;

        try self.ts_compressor.add(timestamp);
        try self.val_compressor.add(value);
    }
};

pub const ChunkDecompressor = struct {
    stream: BitStream,
    ts_decompressor: TimestampDecompressor,
    val_decompressor: ValueDecompressor,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, compressed_data: []const u8) !ChunkDecompressor {
        var stream = BitStream.init(allocator);
        try stream.buffer.appendSlice(allocator, compressed_data);
        stream.reset_read();

        return .{
            .stream = stream,
            // Initialize with dummy pointers, will be fixed in next()
            .ts_decompressor = .{ .stream = undefined, .last_ts = 0, .previous_delta = 0, .count = 0 },
            .val_decompressor = .{ .stream = undefined, .last_value_bits = 0, .last_leading_zeros = 0, .last_trailing_zeros = 0, .count = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChunkDecompressor) void {
        self.stream.deinit();
    }

    pub fn next(self: *ChunkDecompressor) !struct { timestamp: i64, value: f64 } {
        // Fix pointers on every call
        self.ts_decompressor.stream = &self.stream;
        self.val_decompressor.stream = &self.stream;

        const timestamp = try self.ts_decompressor.next();
        const value = try self.val_decompressor.next();
        return .{ .timestamp = timestamp, .value = value };
    }
};

const testing = std.testing;

test "BitStream: write and read single bit" {
    var stream = BitStream.init(testing.allocator);
    defer stream.deinit();

    try stream.write_bit(1);
    try stream.write_bit(0);
    try stream.write_bit(1);
    try stream.write_bit(1);

    stream.reset_read();

    try testing.expectEqual(@as(u1, 1), try stream.read_bit());
    try testing.expectEqual(@as(u1, 0), try stream.read_bit());
    try testing.expectEqual(@as(u1, 1), try stream.read_bit());
    try testing.expectEqual(@as(u1, 1), try stream.read_bit());
}

test "BitStream: write and read multiple bits" {
    var stream = BitStream.init(testing.allocator);
    defer stream.deinit();

    try stream.write_bits(0b1010, 4);
    try stream.write_bits(0b11001100, 8);
    try stream.write_bits(0b111, 3);

    stream.reset_read();

    try testing.expectEqual(@as(u64, 0b1010), try stream.read_bits(4));
    try testing.expectEqual(@as(u64, 0b11001100), try stream.read_bits(8));
    try testing.expectEqual(@as(u64, 0b111), try stream.read_bits(3));
}

test "ChunkCompressor: compress and decompress simple sequence" {
    const allocator = testing.allocator;

    // Compress data
    var compressor = ChunkCompressor.init(allocator);
    defer compressor.deinit();

    const timestamps = [_]i64{ 1000, 1001, 1002, 1003, 1004 };
    const values = [_]f64{ 10.5, 10.6, 10.7, 10.8, 10.9 };

    for (timestamps, values) |ts, val| {
        try compressor.add(ts, val);
    }

    // Get compressed bytes
    const compressed = compressor.stream.items();

    // Decompress data
    var decompressor = try ChunkDecompressor.init(allocator, compressed);
    defer decompressor.deinit();

    for (timestamps, values) |expected_ts, expected_val| {
        const point = try decompressor.next();
        try testing.expectEqual(expected_ts, point.timestamp);
        try testing.expectEqual(expected_val, point.value);
    }
}

test "ChunkCompressor: compress identical timestamps (optimal delta-of-delta)" {
    const allocator = testing.allocator;

    var compressor = ChunkCompressor.init(allocator);
    defer compressor.deinit();

    // Regular interval - delta_of_delta = 0 (best compression)
    const base: i64 = 1000;
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try compressor.add(base + i * 10, @as(f64, @floatFromInt(i)));
    }

    const compressed = compressor.stream.items();

    var decompressor = try ChunkDecompressor.init(allocator, compressed);
    defer decompressor.deinit();

    i = 0;
    while (i < 10) : (i += 1) {
        const point = try decompressor.next();
        try testing.expectEqual(base + i * 10, point.timestamp);
        try testing.expectEqual(@as(f64, @floatFromInt(i)), point.value);
    }
}

test "ChunkCompressor: compress identical values (optimal XOR compression)" {
    const allocator = testing.allocator;

    var compressor = ChunkCompressor.init(allocator);
    defer compressor.deinit();

    // Same value repeated - XOR = 0 (best compression)
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try compressor.add(1000 + i, 42.0);
    }

    const compressed = compressor.stream.items();

    var decompressor = try ChunkDecompressor.init(allocator, compressed);
    defer decompressor.deinit();

    i = 0;
    while (i < 10) : (i += 1) {
        const point = try decompressor.next();
        try testing.expectEqual(1000 + i, point.timestamp);
        try testing.expectEqual(42.0, point.value);
    }
}

test "ChunkCompressor: compress varying deltas and values" {
    const allocator = testing.allocator;

    var compressor = ChunkCompressor.init(allocator);
    defer compressor.deinit();

    // Irregular intervals and varying values
    const test_data = [_]struct { ts: i64, val: f64 }{
        .{ .ts = 1000, .val = 100.0 },
        .{ .ts = 1005, .val = 105.5 },
        .{ .ts = 1015, .val = 110.2 },
        .{ .ts = 1020, .val = 108.7 },
        .{ .ts = 1100, .val = 200.0 },
    };

    for (test_data) |data| {
        try compressor.add(data.ts, data.val);
    }

    const compressed = compressor.stream.items();

    var decompressor = try ChunkDecompressor.init(allocator, compressed);
    defer decompressor.deinit();

    for (test_data) |expected| {
        const point = try decompressor.next();
        try testing.expectEqual(expected.ts, point.timestamp);
        try testing.expectEqual(expected.val, point.value);
    }
}

test "ChunkCompressor: negative timestamps" {
    const allocator = testing.allocator;

    var compressor = ChunkCompressor.init(allocator);
    defer compressor.deinit();

    const timestamps = [_]i64{ -1000, -900, -800, -700, -600 };
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };

    for (timestamps, values) |ts, val| {
        try compressor.add(ts, val);
    }

    const compressed = compressor.stream.items();

    var decompressor = try ChunkDecompressor.init(allocator, compressed);
    defer decompressor.deinit();

    for (timestamps, values) |expected_ts, expected_val| {
        const point = try decompressor.next();
        try testing.expectEqual(expected_ts, point.timestamp);
        try testing.expectEqual(expected_val, point.value);
    }
}

test "ChunkCompressor: diverse float values" {
    const allocator = testing.allocator;

    var compressor = ChunkCompressor.init(allocator);
    defer compressor.deinit();

    const timestamps = [_]i64{ 1, 2, 3, 4, 5 };
    const values = [_]f64{ 1.0, 2.0, 3.5, 100.123, 0.001 };

    for (timestamps, values) |ts, val| {
        try compressor.add(ts, val);
    }

    const compressed = compressor.stream.items();

    var decompressor = try ChunkDecompressor.init(allocator, compressed);
    defer decompressor.deinit();

    for (timestamps, values) |expected_ts, expected_val| {
        const point = try decompressor.next();
        try testing.expectEqual(expected_ts, point.timestamp);
        try testing.expectEqual(expected_val, point.value);
    }
}
