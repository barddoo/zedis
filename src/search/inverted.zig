const std = @import("std");
const Tokenizer = @import("tokenize.zig").Tokenizer;

pub const Allocator = std.mem.Allocator;

const k1: f64 = 1.2;
const b: f64 = 0.75;

pub const TermPosting = struct {
    doc_id: u64,
    tf: u32,
};

pub const TermInfo = struct {
    ddff: u32 = 0,
    posts: std.ArrayListUnmanaged(TermPosting) = .empty,
};

/// Per-field inverted index: term -> (df, postings), plus per-doc lengths
/// for BM25 scoring.
pub const InvertedIndex = struct {
    allocator: Allocator,
    terms: std.StringHashMapUnmanaged(TermInfo) = .empty,
    doc_len: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    num_docs: u64 = 0,
    total_len: u64 = 0,

    pub fn init(allocator: Allocator) InvertedIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InvertedIndex) void {
        var it = self.terms.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.posts.deinit(self.allocator);
        }
        self.terms.deinit(self.allocator);
        self.doc_len.deinit(self.allocator);
    }

    pub fn add(self: *InvertedIndex, doc_id: u64, text: []const u8) !void {
        var tokenizer = Tokenizer.init(self.allocator);
        defer tokenizer.deinit();
        try tokenizer.tokenize(text);

        var uniques = tokenizer.unique_tokens();
        defer uniques.deinit(self.allocator);

        for (uniques.items) |u| {
            const gop = try self.terms.getOrPut(self.allocator, u.token);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, u.token);
                gop.value_ptr.* = .{};
            }
            gop.value_ptr.df += 1;
            try gop.value_ptr.posts.append(self.allocator, .{ .doc_id = doc_id, .tf = u.count });
        }

        try self.doc_len.put(self.allocator, doc_id, @intCast(tokenizer.tokens.items.len));
        self.num_docs += 1;
        self.total_len += tokenizer.tokens.items.len;
    }

    /// Removes a document from the index by scanning postings for its id.
    pub fn remove(self: *InvertedIndex, doc_id: u64, text: []const u8) void {
        var tokenizer = Tokenizer.init(self.allocator);
        defer tokenizer.deinit();
        tokenizer.tokenize(text) catch return;

        var uniques = tokenizer.unique_tokens();
        defer uniques.deinit(self.allocator);

        for (uniques.items) |u| {
            if (self.terms.getPtr(u.token)) |info| {
                for (info.posts.items, 0..) |p, idx| {
                    if (p.doc_id == doc_id) {
                        _ = info.posts.swapRemove(idx);
                        info.df -= 1;
                        break;
                    }
                }
                if (info.df == 0) {
                    if (self.terms.fetchRemove(u.token)) |kv| {
                        self.allocator.free(kv.key);
                        var term_value = kv.value;
                        term_value.posts.deinit(self.allocator);
                    }
                }
            }
        }

        if (self.doc_len.fetchRemove(doc_id)) |kv| {
            self.num_docs -= 1;
            self.total_len -= kv.value;
        }
    }

    pub fn avg_doc_len(self: *const InvertedIndex) f64 {
        if (self.num_docs == 0) return 0;
        return @as(f64, @floatFromInt(self.total_len)) / @as(f64, @floatFromInt(self.num_docs));
    }

    pub fn idf(self: *const InvertedIndex, df: u32) f64 {
        const n: f64 = @floatFromInt(self.num_docs);
        const d: f64 = @floatFromInt(df);
        return @log(1 + (n - d + 0.5) / (d + 0.5));
    }

    pub fn bm25(self: *const InvertedIndex, doc_id: u64, df: u32, freq: u32) f64 {
        const avgdl = self.avg_doc_len();
        const dl: f64 = @floatFromInt(self.doc_len.get(doc_id) orelse 0);
        const t: f64 = @floatFromInt(freq);
        const denom = t + k1 * (1 - b + b * dl / (if (avgdl == 0) 1.0 else avgdl));
        return self.idf(df) * (t * (k1 + 1)) / denom;
    }

    /// Term frequency for a (doc, term) pair, if present.
    pub fn tf(self: *const InvertedIndex, doc_id: u64, term: []const u8) u32 {
        const info = self.terms.get(term) orelse return 0;
        for (info.posts.items) |p| {
            if (p.doc_id == doc_id) return p.tf;
        }
        return 0;
    }

    pub fn postings(self: *const InvertedIndex, term: []const u8) ?[]const TermPosting {
        const info = self.terms.get(term) orelse return null;
        return info.posts.items;
    }

    pub fn doc_freq(self: *const InvertedIndex, term: []const u8) u32 {
        const info = self.terms.get(term) orelse return 0;
        return info.df;
    }

    pub fn term_count(self: *const InvertedIndex) usize {
        return self.terms.count();
    }

    pub fn doc_length(self: *const InvertedIndex, doc_id: u64) u32 {
        return self.doc_len.get(doc_id) orelse 0;
    }
};

const testing = std.testing;

test "inverted add and search postings" {
    var ii = InvertedIndex.init(testing.allocator);
    defer ii.deinit();

    try ii.add(1, "the quick brown fox");
    try ii.add(2, "the lazy dog");
    try ii.add(3, "quick quick fox");

    const posts = ii.postings("quick").?;
    try testing.expectEqual(@as(usize, 2), posts.len);
    // doc 1 has tf 1, doc 3 has tf 2
    for (posts) |p| {
        if (p.doc_id == 1) try testing.expectEqual(@as(u32, 1), p.tf);
        if (p.doc_id == 3) try testing.expectEqual(@as(u32, 2), p.tf);
    }

    try testing.expectEqual(@as(u32, 3), ii.num_docs);
    try testing.expect(ii.postings("nonexistent") == null);
}

test "inverted remove document" {
    var ii = InvertedIndex.init(testing.allocator);
    defer ii.deinit();

    try ii.add(1, "alpha beta");
    try ii.add(2, "alpha gamma");
    try testing.expectEqual(@as(u32, 2), ii.doc_freq("alpha"));

    ii.remove(1, "alpha beta");

    try testing.expectEqual(@as(u32, 1), ii.doc_freq("alpha"));
    try testing.expect(ii.doc_freq("beta") == 0);
    try testing.expect(ii.terms.get("beta") == null);
    try testing.expectEqual(@as(u64, 1), ii.num_docs);
}

test "inverted bm25 prefers rare term in short doc" {
    var ii = InvertedIndex.init(testing.allocator);
    defer ii.deinit();

    try ii.add(1, "cat");
    try ii.add(2, "cat dog bird fish bear wolf deer elk");

    const s1 = ii.bm25(1, ii.doc_freq("cat"), ii.tf(1, "cat"));
    const s2 = ii.bm25(2, ii.doc_freq("cat"), ii.tf(2, "cat"));
    // Equal tf, but shorter doc should score higher (bm25 length normalization)
    try testing.expect(s1 > s2);
}
