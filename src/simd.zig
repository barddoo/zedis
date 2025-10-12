const std = @import("std");

// SIMD-optimized string equality for longer strings
pub fn simdStringEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    // Check if SIMD is available
    const vec_len = std.simd.suggestVectorLength(u8) orelse return std.mem.eql(u8, a, b);
    if (vec_len < 16) return std.mem.eql(u8, a, b);

    const Vec = @Vector(vec_len, u8);
    var i: usize = 0;

    // Process full vectors
    while (i + vec_len <= a.len) {
        const va: Vec = a[i..][0..vec_len].*;
        const vb: Vec = b[i..][0..vec_len].*;

        // Compare all bytes in parallel
        const comparison = va == vb;
        if (!@reduce(.And, comparison)) {
            return false;
        }
        i += vec_len;
    }

    // Handle remaining bytes (scalar comparison)
    while (i < a.len) {
        if (a[i] != b[i]) return false;
        i += 1;
    }

    return true;
}
