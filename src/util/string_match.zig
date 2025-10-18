// TODO: Add character class support and escape character support.
pub fn string_match(pattern: []const u8, str: []const u8) bool {
    var pIndex: usize = 0;
    var sIndex: usize = 0;

    while (pIndex < pattern.len and sIndex < str.len) {
        if (pattern[pIndex] == '*') {
            // Skip consecutive '*' characters
            while (pIndex + 1 < pattern.len and pattern[pIndex + 1] == '*') : (pIndex += 1) {}
            if (pIndex + 1 == pattern.len) {
                return true; // Trailing '*' matches the rest of the string
            }
            pIndex += 1;
            while (sIndex < str.len) {
                if (string_match(pattern[pIndex..], str[sIndex..])) {
                    return true;
                }
                sIndex += 1;
            }
            return false;
        } else if (pattern[pIndex] == '?' or pattern[pIndex] == str[sIndex]) {
            pIndex += 1;
            sIndex += 1;
        } else {
            return false;
        }
    }

    // Check for remaining characters in pattern
    while (pIndex < pattern.len and pattern[pIndex] == '*') : (pIndex += 1) {}

    return pIndex == pattern.len and sIndex == str.len;
}

const testing = @import("std").testing;

test "string_match: exact match" {
    try testing.expect(string_match("hello", "hello"));
    try testing.expect(string_match("", ""));
    try testing.expect(string_match("a", "a"));
    try testing.expect(string_match("test123", "test123"));
}

test "string_match: no match - different strings" {
    try testing.expect(!string_match("hello", "world"));
    try testing.expect(!string_match("a", "b"));
    try testing.expect(!string_match("test", "testing"));
    try testing.expect(!string_match("testing", "test"));
}

test "string_match: no match - different lengths" {
    try testing.expect(!string_match("hello", "hello!"));
    try testing.expect(!string_match("hello!", "hello"));
    try testing.expect(!string_match("", "a"));
    try testing.expect(!string_match("a", ""));
}

// ============================================================================
// Wildcard '?' Tests (single character match)
// ============================================================================

test "string_match: single ? wildcard" {
    try testing.expect(string_match("h?llo", "hello"));
    try testing.expect(string_match("h?llo", "hallo"));
    try testing.expect(string_match("h?llo", "hxllo"));
    try testing.expect(string_match("?", "a"));
    try testing.expect(string_match("?", "x"));
}

test "string_match: multiple ? wildcards" {
    try testing.expect(string_match("h??lo", "hello"));
    try testing.expect(string_match("???", "abc"));
    try testing.expect(string_match("?e?t", "test"));
    try testing.expect(string_match("????", "1234"));
}

test "string_match: ? at start and end" {
    try testing.expect(string_match("?ello", "hello"));
    try testing.expect(string_match("hell?", "hello"));
    try testing.expect(string_match("?ell?", "hello"));
}

test "string_match: ? no match - wrong length" {
    try testing.expect(!string_match("h?llo", "hllo")); // too short
    try testing.expect(!string_match("h?llo", "heello")); // too long
    try testing.expect(!string_match("?", "")); // empty string
    try testing.expect(!string_match("??", "a")); // too short
}

// ============================================================================
// Wildcard '*' Tests (zero or more characters)
// ============================================================================

test "string_match: single * matches everything" {
    try testing.expect(string_match("*", ""));
    try testing.expect(string_match("*", "a"));
    try testing.expect(string_match("*", "hello"));
    try testing.expect(string_match("*", "anything at all"));
}

test "string_match: * at start" {
    try testing.expect(string_match("*llo", "hello"));
    try testing.expect(string_match("*llo", "llo"));
    try testing.expect(string_match("*llo", "llo"));
    try testing.expect(string_match("*world", "hello world"));
}

test "string_match: * at end" {
    try testing.expect(string_match("hello*", "hello"));
    try testing.expect(string_match("hello*", "hello world"));
    try testing.expect(string_match("hello*", "hello123"));
    try testing.expect(string_match("test*", "test"));
}

test "string_match: * in middle" {
    try testing.expect(string_match("h*o", "hello"));
    try testing.expect(string_match("h*o", "ho"));
    try testing.expect(string_match("h*o", "hxxxxxo"));
    try testing.expect(string_match("a*z", "abcdefghijklmnopqrstuvwxyz"));
}

test "string_match: multiple * wildcards" {
    try testing.expect(string_match("*h*o*", "hello"));
    try testing.expect(string_match("*h*o*", "ho"));
    try testing.expect(string_match("*h*o*", "xhxoxxx"));
    try testing.expect(string_match("**", "anything"));
    try testing.expect(string_match("***", "test"));
}

test "string_match: consecutive * wildcards" {
    // Multiple consecutive * should be treated as single *
    try testing.expect(string_match("a**b", "ab"));
    try testing.expect(string_match("a**b", "axb"));
    try testing.expect(string_match("a***b", "axxxb"));
    try testing.expect(string_match("****", "anything"));
}

test "string_match: * no match" {
    try testing.expect(!string_match("*abc", "xyz"));
    try testing.expect(!string_match("abc*", "xyz"));
    try testing.expect(!string_match("a*c", "ab"));
    try testing.expect(!string_match("x*y", "xyz"));
}

// ============================================================================
// Combined Wildcards Tests (* and ?)
// ============================================================================

test "string_match: combining * and ?" {
    try testing.expect(string_match("h*?o", "hello"));
    try testing.expect(string_match("h*?o", "helo"));
    try testing.expect(string_match("h?*o", "hello"));
    try testing.expect(string_match("?*?", "ab"));
    try testing.expect(string_match("?*?", "abc"));
}

test "string_match: complex patterns" {
    try testing.expect(string_match("a*b?c", "axxxbxc")); // fixed: need char between b and c
    try testing.expect(string_match("a*b?c", "abxc"));
    try testing.expect(string_match("?*?*?", "abc"));
    try testing.expect(string_match("*?*?*", "ab"));
}

test "string_match: pattern longer than string with wildcards" {
    try testing.expect(!string_match("hello?world", "helloworld"));
    try testing.expect(string_match("hello*world", "helloworld"));
}

// ============================================================================
// Edge Cases
// ============================================================================

test "string_match: empty pattern and string" {
    try testing.expect(string_match("", ""));
}

test "string_match: empty pattern with non-empty string" {
    try testing.expect(!string_match("", "hello"));
}

test "string_match: empty string with wildcard pattern" {
    try testing.expect(string_match("*", ""));
    try testing.expect(string_match("**", ""));
    try testing.expect(string_match("***", ""));
    try testing.expect(!string_match("?", ""));
    try testing.expect(!string_match("*?", ""));
}

test "string_match: pattern with only wildcards" {
    try testing.expect(string_match("???", "abc"));
    try testing.expect(string_match("***", "test"));
    try testing.expect(string_match("*?*", "x"));
}

// ============================================================================
// Real-World Use Cases (Redis KEYS pattern matching)
// ============================================================================

test "string_match: redis key patterns" {
    // Match all keys
    try testing.expect(string_match("*", "user:1000"));
    try testing.expect(string_match("*", "session:abc123"));

    // Match keys with prefix
    try testing.expect(string_match("user:*", "user:1000"));
    try testing.expect(string_match("user:*", "user:1000:profile"));
    try testing.expect(!string_match("user:*", "session:1000"));

    // Match keys with suffix
    try testing.expect(string_match("*:profile", "user:1000:profile"));
    try testing.expect(!string_match("*:profile", "user:1000:settings"));

    // Match keys with pattern in middle
    try testing.expect(string_match("user:*:profile", "user:1000:profile"));
    try testing.expect(string_match("user:*:profile", "user:admin:profile"));
    try testing.expect(!string_match("user:*:profile", "user:1000:settings"));

    // Single character wildcard
    try testing.expect(string_match("user:?", "user:1"));
    try testing.expect(string_match("user:?", "user:a"));
    try testing.expect(!string_match("user:?", "user:10"));

    // Complex patterns
    try testing.expect(string_match("user:*:setting?", "user:1000:settings"));
    try testing.expect(string_match("*:temp:*", "cache:temp:123"));
}

// ============================================================================
// Special Characters
// ============================================================================

test "string_match: special characters in string" {
    try testing.expect(string_match("hello-world", "hello-world"));
    try testing.expect(string_match("hello_world", "hello_world"));
    try testing.expect(string_match("hello:world", "hello:world"));
    try testing.expect(string_match("hello.world", "hello.world"));
    try testing.expect(string_match("hello@world", "hello@world"));
}

test "string_match: special characters with wildcards" {
    try testing.expect(string_match("hello-*", "hello-world"));
    try testing.expect(string_match("*-world", "hello-world"));
    try testing.expect(string_match("hello_?_world", "hello_x_world"));
    try testing.expect(string_match("*:*", "key:value"));
}

// ============================================================================
// Performance/Stress Tests
// ============================================================================

test "string_match: long strings" {
    const long_str = "abcdefghijklmnopqrstuvwxyz0123456789";
    try testing.expect(string_match("*", long_str));
    try testing.expect(string_match("abc*xyz0123456789", long_str));
    try testing.expect(string_match("*9", long_str));
    try testing.expect(string_match("a*", long_str));
}

test "string_match: many wildcards" {
    try testing.expect(string_match("*a*b*c*", "abc"));
    try testing.expect(string_match("*a*b*c*", "xaybzc"));
    try testing.expect(string_match("*a*b*c*", "aabbcc"));
    try testing.expect(string_match("*a*b*c*d*e*", "abcde"));
}

test "string_match: alternating ? and *" {
    try testing.expect(string_match("?*?*?", "abc"));
    try testing.expect(string_match("?*?*?*?", "abcd"));
    try testing.expect(string_match("*?*?*?*", "abc"));
}

// ============================================================================
// Regression Tests (potential edge cases)
// ============================================================================

test "string_match: * not matching beyond required" {
    try testing.expect(!string_match("a*b*c", "aXbYd")); // missing 'c'
    try testing.expect(string_match("a*b*c", "aXbYc"));
}

test "string_match: greedy * matching" {
    try testing.expect(string_match("*ab", "aaab"));
    try testing.expect(string_match("*ab", "ab"));
    try testing.expect(string_match("a*ab", "aab"));
    try testing.expect(string_match("a*ab", "aaaab"));
}

test "string_match: pattern ends with multiple wildcards" {
    try testing.expect(string_match("test*?", "test12"));
    try testing.expect(string_match("test?*", "test12"));
    try testing.expect(string_match("test**", "test"));
    try testing.expect(string_match("test??**", "test12"));
}
