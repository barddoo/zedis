const std = @import("std");

pub const Allocator = std.mem.Allocator;

/// Bytes processed per SIMD iteration, tuned to the compile-target CPU
/// (16 on aarch64/SSE2, 32 with AVX2, 64 with AVX-512 for u8).
const VEC_LEN = std.simd.suggestVectorLength(u8) orelse 16;

/// Widest type that can hold a VEC_LEN-bit separator mask.
const MaskInt = std.meta.Int(.unsigned, VEC_LEN);

/// Splits text into lowercased tokens, splitting on non-alphanumeric bytes.
/// UTF-8 bytes (>= 0x80) are treated as token characters so unicode words
/// still tokenize as whole units (ASCII-only lowercasing for now).
///
/// The separator classification is SIMD: VEC_LEN bytes are loaded at once into
/// a `@Vector(VEC_LEN, u8)`, classified with vector compares, and the
/// resulting flag vector is reduced to a bitmask via `@select` +
/// `@reduce(.Add)`.
pub const Tokenizer = struct {
    allocator: Allocator,
    tokens: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator) Tokenizer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.reset();
        self.tokens.deinit(self.allocator);
    }

    pub fn reset(self: *Tokenizer) void {
        for (self.tokens.items) |t| self.allocator.free(t);
        self.tokens.clearRetainingCapacity();
    }

    /// Tokenizes `input`. Resulting tokens are owned by this Tokenizer and
    /// freed on `reset`/`deinit`.
    pub fn tokenize(self: *Tokenizer, input: []const u8) !void {
        self.reset();
        var start: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            const chunk_len = @min(input.len - i, VEC_LEN);

            var chunk: [VEC_LEN]u8 = undefined;
            @memset(&chunk, 0);
            @memcpy(chunk[0..chunk_len], input[i..][0..chunk_len]);

            const flags: @Vector(VEC_LEN, u8) = sep_mask(chunk);
            const mask: MaskInt = to_mask(flags);

            var b: usize = 0;
            while (b < VEC_LEN) : (b += 1) {
                const abs_pos = i + b;
                // Zero-padded positions beyond the input are treated as separators
                // so the final token is flushed at the end of the input.
                const sep = if (abs_pos < input.len) (mask & (@as(MaskInt, 1) << @intCast(b))) != 0 else true;
                if (sep) {
                    if (abs_pos > start) {
                        const token = try self.allocator.dupe(u8, input[start..abs_pos]);
                        for (token) |*c| c.* = std.ascii.toLower(c.*);
                        try self.tokens.append(self.allocator, token);
                    }
                    start = abs_pos + 1;
                }
            }
            i += chunk_len;
        }
    }

    /// Counts unique tokens and their term frequencies via linear scan.
    /// Returned slices borrow from `self.tokens`.
    pub fn unique_tokens(self: *const Tokenizer) std.ArrayListUnmanaged(TokenCount) {
        var uniques: std.ArrayListUnmanaged(TokenCount) = .empty;
        for (self.tokens.items) |tok| {
            var found = false;
            for (uniques.items) |*u| {
                if (std.mem.eql(u8, u.token, tok)) {
                    u.count += 1;
                    found = true;
                    break;
                }
            }
            if (!found) {
                uniques.append(self.allocator, .{ .token = tok, .count = 1 }) catch break;
            }
        }
        return uniques;
    }
};

pub const TokenCount = struct {
    token: []const u8,
    count: u32,
};

/// Classifies each of the VEC_LEN bytes as a separator using vector compares.
/// Returns a `@Vector(VEC_LEN, u8)` of 0/1 flags: 1 at separator positions.
/// (Uses `@select` + bitwise ops because Zig's `and`/`or` keywords do not
/// operate element-wise on boolean vectors.)
inline fn sep_mask(chunk: [VEC_LEN]u8) @Vector(VEC_LEN, u8) {
    const vec: @Vector(VEC_LEN, u8) = chunk;
    const one = @as(@Vector(VEC_LEN, u8), @splat(1));
    const zero = @as(@Vector(VEC_LEN, u8), @splat(0));
    const v_zero = @as(@Vector(VEC_LEN, u8), @splat('0'));
    const v_nine = @as(@Vector(VEC_LEN, u8), @splat('9'));
    const v_cap_a = @as(@Vector(VEC_LEN, u8), @splat('A'));
    const v_cap_z = @as(@Vector(VEC_LEN, u8), @splat('Z'));
    const v_low_a = @as(@Vector(VEC_LEN, u8), @splat('a'));
    const v_low_z = @as(@Vector(VEC_LEN, u8), @splat('z'));
    const v_high = @as(@Vector(VEC_LEN, u8), @splat(0x80));

    const is_digit = @select(u8, vec >= v_zero, one, zero) & @select(u8, vec <= v_nine, one, zero);
    const is_upper = @select(u8, vec >= v_cap_a, one, zero) & @select(u8, vec <= v_cap_z, one, zero);
    const is_lower = @select(u8, vec >= v_low_a, one, zero) & @select(u8, vec <= v_low_z, one, zero);
    const is_high = @select(u8, vec >= v_high, one, zero);

    const is_token = is_digit | is_upper | is_lower | is_high;
    return (is_token ^ one) & one;
}

/// Reduces a 0/1 flag vector to a bitmask: bit k set means position k is a
/// separator. Uses `std.simd.iota` to build the {1<<0, 1<<1, ...} weights.
inline fn to_mask(flags: @Vector(VEC_LEN, u8)) MaskInt {
    const weights: @Vector(VEC_LEN, MaskInt) = @as(@Vector(VEC_LEN, MaskInt), @splat(1)) << std.simd.iota(MaskInt, VEC_LEN);
    const w: @Vector(VEC_LEN, MaskInt) = @intCast(flags);
    return @reduce(.Add, w * weights);
}

const testing = std.testing;

test "tokenize splits on non-alphanumeric and lowercases" {
    var t = Tokenizer.init(testing.allocator);
    defer t.deinit();
    try t.tokenize("Hello, World! Redis-Rocks");
    try testing.expectEqual(@as(usize, 4), t.tokens.items.len);
    try testing.expectEqualStrings("hello", t.tokens.items[0]);
    try testing.expectEqualStrings("world", t.tokens.items[1]);
    try testing.expectEqualStrings("redis", t.tokens.items[2]);
    try testing.expectEqualStrings("rocks", t.tokens.items[3]);
}

test "tokenize counts term frequencies" {
    var t = Tokenizer.init(testing.allocator);
    defer t.deinit();
    try t.tokenize("foo bar foo baz foo");
    var uniques = t.unique_tokens();
    defer uniques.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), uniques.items.len);
    var foo_count: u32 = 0;
    for (uniques.items) |u| {
        if (std.mem.eql(u8, u.token, "foo")) foo_count = u.count;
    }
    try testing.expectEqual(@as(u32, 3), foo_count);
}

test "tokenize keeps unicode words whole" {
    var t = Tokenizer.init(testing.allocator);
    defer t.deinit();
    try t.tokenize("héllo wörld");
    try testing.expectEqual(@as(usize, 2), t.tokens.items.len);
    try testing.expectEqualStrings("h\u{e9}llo", t.tokens.items[0]);
}

test "tokenize handles input longer than one vector" {
    var t = Tokenizer.init(testing.allocator);
    defer t.deinit();
    try t.tokenize("alpha beta gamma delta epsilon");
    try testing.expectEqual(@as(usize, 5), t.tokens.items.len);
    try testing.expectEqualStrings("alpha", t.tokens.items[0]);
    try testing.expectEqualStrings("epsilon", t.tokens.items[4]);
}

test "tokenize handles trailing and leading separators" {
    var t = Tokenizer.init(testing.allocator);
    defer t.deinit();
    try t.tokenize("  spaced  out  ");
    try testing.expectEqual(@as(usize, 2), t.tokens.items.len);
    try testing.expectEqualStrings("spaced", t.tokens.items[0]);
    try testing.expectEqualStrings("out", t.tokens.items[1]);
}

test "tokenize empty input" {
    var t = Tokenizer.init(testing.allocator);
    defer t.deinit();
    try t.tokenize("");
    try testing.expectEqual(@as(usize, 0), t.tokens.items.len);
}
