const std = @import("std");

/// Helper function to match glob-style patterns
/// Supports * (matches any sequence) and ? (matches single character)
/// Uses an iterative algorithm with backtracking for better performance
/// Time complexity: O(n + m) average case, O(n * m) worst case
/// Space complexity: O(1)
pub fn matchPattern(pattern: []const u8, text: []const u8) bool {
    var pattern_idx: usize = 0;
    var text_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (text_idx < text.len) {
        // If pattern and text match, or pattern has ?, advance both
        if (pattern_idx < pattern.len and (pattern[pattern_idx] == text[text_idx] or pattern[pattern_idx] == '?')) {
            pattern_idx += 1;
            text_idx += 1;
        }
        // If pattern has *, save position and try to match 0 characters first
        else if (pattern_idx < pattern.len and pattern[pattern_idx] == '*') {
            star_idx = pattern_idx;
            match_idx = text_idx;
            pattern_idx += 1;
        }
        // If no match and we had a previous *, backtrack and try matching 1 more character
        else if (star_idx) |star| {
            pattern_idx = star + 1;
            match_idx += 1;
            text_idx = match_idx;
        }
        // No match
        else {
            return false;
        }
    }

    // Check remaining pattern characters (should only be *)
    while (pattern_idx < pattern.len and pattern[pattern_idx] == '*') {
        pattern_idx += 1;
    }

    return pattern_idx == pattern.len;
}
