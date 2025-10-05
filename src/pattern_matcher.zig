const std = @import("std");

/// Helper function to match glob-style patterns
/// Supports * (matches any sequence) and ? (matches single character)
/// Uses an iterative algorithm with backtracking for better performance
/// Time complexity: O(n + m) average case, O(n * m) worst case
/// Space complexity: O(1)
pub fn matchPattern(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        // If pattern and text match, or pattern has ?, advance both
        if (p_idx < pattern.len and (pattern[p_idx] == text[t_idx] or pattern[p_idx] == '?')) {
            p_idx += 1;
            t_idx += 1;
        }
        // If pattern has *, save position and try to match 0 characters first
        else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        }
        // If no match and we had a previous *, backtrack and try matching 1 more character
        else if (star_idx) |star| {
            p_idx = star + 1;
            match_idx += 1;
            t_idx = match_idx;
        }
        // No match
        else {
            return false;
        }
    }

    // Check remaining pattern characters (should only be *)
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}
