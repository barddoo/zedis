const std = @import("std");

pub const Crc64 = @This();

const polynomial: u64 = @bitReverse(@as(u64, 0xad93d23594c935a9));

/// Reflected (LSB-first) lookup tables for slicing-by-8. `tables[0]` is the
/// ordinary byte table; `tables[k]` covers a byte `k` positions ahead.
const tables = blk: {
    @setEvalBranchQuota(100_000);

    var t: [8][256]u64 = undefined;
    for (&t[0], 0..) |*entry, i| {
        var crc: u64 = i;
        for (0..8) |_| {
            crc = (crc >> 1) ^ ((crc & 1) * polynomial);
        }
        entry.* = crc;
    }
    for (1..8) |k| {
        for (0..256) |i| {
            t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
        }
    }
    break :blk t;
};

crc: u64 = 0,

pub fn init() Crc64 {
    return .{};
}

pub fn update(self: *Crc64, bytes: []const u8) void {
    var data = bytes;
    var crc = self.crc;

    while (data.len >= 8) {
        // Fold the next 8 bytes into the register at once; both the register
        // and the chunk are consumed little-endian because the CRC is reflected.
        const x = crc ^ std.mem.readInt(u64, data[0..8], .little);
        crc = tables[7][@as(u8, @truncate(x))] ^
            tables[6][@as(u8, @truncate(x >> 8))] ^
            tables[5][@as(u8, @truncate(x >> 16))] ^
            tables[4][@as(u8, @truncate(x >> 24))] ^
            tables[3][@as(u8, @truncate(x >> 32))] ^
            tables[2][@as(u8, @truncate(x >> 40))] ^
            tables[1][@as(u8, @truncate(x >> 48))] ^
            tables[0][@as(u8, @truncate(x >> 56))];
        data = data[8..];
    }

    for (data) |byte| {
        crc = tables[0][@as(u8, @truncate(crc ^ byte))] ^ (crc >> 8);
    }

    self.crc = crc;
}

pub inline fn updateByte(self: *Crc64, byte: u8) void {
    self.crc = tables[0][@as(u8, @truncate(self.crc ^ byte))] ^ (self.crc >> 8);
}

pub fn final(self: Crc64) u64 {
    return self.crc;
}

pub fn hash(bytes: []const u8) u64 {
    var c = init();
    c.update(bytes);
    return c.final();
}

const testing = std.testing;

test "crc64: known Redis check value" {
    try testing.expectEqual(@as(u64, 0xe9c6d914c4b8d9ca), Crc64.hash("123456789"));
    try testing.expectEqual(@as(u64, 0), Crc64.hash(""));
}

test "crc64: matches std for every length and alignment" {
    const Std = std.hash.crc.@"CRC-64/REDIS";

    var buf: [64 + 8]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    prng.random().bytes(&buf);

    for (0..buf.len - 8 + 1) |offset| {
        for (0..buf.len - offset + 1) |len| {
            const slice = buf[offset..][0..len];

            var std_state = Std.init();
            std_state.update(slice);

            try testing.expectEqual(std_state.final(), Crc64.hash(slice));
        }
    }
}

test "crc64: streaming matches one-shot" {
    const input = "REDIS0011\xfa\x09redis-ver\x051.2.3\xff";
    const one_shot = Crc64.hash(input);

    var state = Crc64.init();
    for (input) |byte| state.updateByte(byte);

    var chunked = Crc64.init();
    chunked.update(input[0..3]);
    chunked.update(input[3..7]);
    chunked.update(input[7..]);

    try testing.expectEqual(one_shot, state.final());
    try testing.expectEqual(one_shot, chunked.final());
}
