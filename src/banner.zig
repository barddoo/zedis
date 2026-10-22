const std = @import("std");

/// `n` copies of `s` as a comptime array.
///
/// 0.17 removed the `"x" ** n` array-multiplication operator. A single-byte
/// pattern is just `@splat`, but the banner rules repeat the three-byte "█"
/// glyph, which `@splat` cannot express (it splats one element, not a pattern).
pub fn repeat(comptime s: []const u8, comptime n: usize) [n * s.len]u8 {
    if (s.len == 1) return @splat(s[0]);

    var buf: [n * s.len]u8 = undefined;
    for (0..n) |i| {
        @memcpy(buf[i * s.len ..][0..s.len], s);
    }
    return buf;
}
