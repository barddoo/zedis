const std = @import("std");
const testing = std.testing;
const pattern_matcher = @import("../pattern_matcher.zig");

test "matchPattern with exact match" {
    try testing.expect(pattern_matcher.matchPattern("hello", "hello"));
    try testing.expect(!pattern_matcher.matchPattern("hello", "world"));
}

test "matchPattern with * wildcard" {
    try testing.expect(pattern_matcher.matchPattern("h*o", "hello"));
    try testing.expect(pattern_matcher.matchPattern("*", "anything"));
    try testing.expect(pattern_matcher.matchPattern("h*", "hello"));
    try testing.expect(pattern_matcher.matchPattern("*o", "hello"));
    try testing.expect(pattern_matcher.matchPattern("h*l*o", "hello"));
}

test "matchPattern with ? wildcard" {
    try testing.expect(pattern_matcher.matchPattern("h?llo", "hello"));
    try testing.expect(pattern_matcher.matchPattern("h?llo", "hallo"));
    try testing.expect(!pattern_matcher.matchPattern("h?llo", "hllo"));
    try testing.expect(!pattern_matcher.matchPattern("h?llo", "helllo"));
}

test "matchPattern with mixed wildcards" {
    try testing.expect(pattern_matcher.matchPattern("h?ll*", "hello"));
    try testing.expect(pattern_matcher.matchPattern("h*l?o", "hello"));
    try testing.expect(pattern_matcher.matchPattern("*?*", "a"));
}

test "matchPattern with multiple consecutive *" {
    try testing.expect(pattern_matcher.matchPattern("a**b", "ab"));
    try testing.expect(pattern_matcher.matchPattern("a**b", "axxxb"));
    try testing.expect(pattern_matcher.matchPattern("***hello***", "hello"));
}

test "matchPattern with complex backtracking" {
    // Tests that would be slow with naive recursive approach
    try testing.expect(pattern_matcher.matchPattern("a*a*a*a*b", "aaaaab"));
    try testing.expect(!pattern_matcher.matchPattern("a*a*a*a*b", "aaaaac"));
    try testing.expect(pattern_matcher.matchPattern("*a*b*c*d*e*", "axbxcxdxe"));
}

test "matchPattern edge cases" {
    // Empty pattern and text
    try testing.expect(pattern_matcher.matchPattern("", ""));

    // Pattern with only wildcards
    try testing.expect(pattern_matcher.matchPattern("*", ""));
    try testing.expect(pattern_matcher.matchPattern("***", ""));
    try testing.expect(pattern_matcher.matchPattern("*", "anything"));

    // Pattern longer than text
    try testing.expect(!pattern_matcher.matchPattern("hello", "hell"));

    // Text longer than pattern (without *)
    try testing.expect(!pattern_matcher.matchPattern("hell", "hello"));
}

test "matchPattern performance scenario" {
    // Pattern that would cause exponential backtracking in naive implementation
    const long_text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaac";
    const bad_pattern = "a*a*a*a*a*a*a*b";

    // Should return false quickly
    try testing.expect(!pattern_matcher.matchPattern(bad_pattern, long_text));
}
