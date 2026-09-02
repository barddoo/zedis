const std = @import("std");
const SearchIndex = @import("index.zig").SearchIndex;
const query_mod = @import("query.zig");
const Node = query_mod.Node;
const Tokenizer = @import("tokenize.zig").Tokenizer;

pub const Allocator = std.mem.Allocator;

pub const SearchOptions = struct {
    no_content: bool = false,
    with_scores: bool = false,
    sort_by: ?[]const u8 = null,
    sort_asc: bool = false,
    limit_offset: usize = 0,
    limit_count: usize = 10,
    return_fields: ?[]const []const u8 = null,
};

pub const Result = struct {
    doc_id: []const u8,
    internal_id: u64,
    score: f64,
    sort_key: ?f64 = null,
};

const DocSet = std.AutoHashMapUnmanaged(u64, void);

const QueryTerm = struct {
    field: ?u16,
    text: []const u8,
};

/// Runs a search query against `index`. `params` supplies values for `$name`
/// references (e.g. the KNN query vector blob).
pub fn search(
    allocator: Allocator,
    index: *const SearchIndex,
    query_str: []const u8,
    params: ?*const std.StringHashMapUnmanaged([]const u8),
    opts: *const SearchOptions,
) !std.ArrayListUnmanaged(Result) {
    var q = try query_mod.parse(allocator, query_str);
    defer q.deinit();

    var candidates: DocSet = .empty;
    defer candidates.deinit(allocator);
    try collect_candidates(allocator, index, &q.filter, &candidates);

    var results: std.ArrayListUnmanaged(Result) = .empty;
    errdefer results.deinit(allocator);

    if (q.knn) |knn| {
        const field_idx = index.field_index(knn.field) orelse return error.UnknownField;
        const vi = index.get_vector(field_idx) orelse return error.UnknownField;
        const blob = params.?.get(knn.vec_param) orelse return error.MissingParam;

        var knn_res = try vi.knn_filtered(blob, knn.k, &candidates);
        defer knn_res.deinit(allocator);
        for (knn_res.items) |kr| {
            const doc_id = find_doc_id(index, kr.doc_id) orelse continue;
            try results.append(allocator, .{
                .doc_id = doc_id,
                .internal_id = kr.doc_id,
                .score = kr.score,
            });
        }
    } else {
        var terms: std.ArrayListUnmanaged(QueryTerm) = .empty;
        defer terms.deinit(allocator);
        try collect_terms(allocator, index, &q.filter, &terms);

        var it = candidates.iterator();
        while (it.next()) |e| {
            const internal_id = e.key_ptr.*;
            const doc_id = find_doc_id(index, internal_id) orelse continue;
            const score = score_doc(index, terms.items, internal_id);
            try results.append(allocator, .{
                .doc_id = doc_id,
                .internal_id = internal_id,
                .score = score,
            });
        }

        try apply_sort(index, &results, opts);
    }

    // LIMIT offset count
    if (opts.limit_offset >= results.items.len) {
        results.clearRetainingCapacity();
    } else {
        const end = @min(results.items.len, opts.limit_offset + opts.limit_count);
        const keep = results.items[opts.limit_offset..end];
        // Move the kept window to the front (items overlap within the slice).
        std.mem.copyForwards(Result, results.items[0 .. end - opts.limit_offset], keep);
        results.shrinkRetainingCapacity(end - opts.limit_offset);
    }

    return results;
}

fn collect_candidates(allocator: Allocator, index: *const SearchIndex, node: *const Node, set: *DocSet) !void {
    switch (node.*) {
        .all => {
            var it = index.docs.iterator();
            while (it.next()) |e| try set.put(allocator, e.value_ptr.internal_id, {});
        },
        .term => |t| {
            for (index.fields, 0..) |f, i| {
                if (f.field_type != .text) continue;
                if (index.get_inverted(@intCast(i))) |ii| {
                    if (ii.postings(t.text)) |posts| {
                        for (posts) |p| try set.put(allocator, p.doc_id, {});
                    }
                }
            }
        },
        .phrase => |p| {
            // AND of the phrase's words across all text fields.
            var tokenizer = Tokenizer.init(allocator);
            defer tokenizer.deinit();
            try tokenizer.tokenize(p.text);
            for (tokenizer.tokens.items) |word| {
                var word_set: DocSet = .empty;
                defer word_set.deinit(allocator);
                for (index.fields, 0..) |f, i| {
                    if (f.field_type != .text) continue;
                    if (index.get_inverted(@intCast(i))) |ii| {
                        if (ii.postings(word)) |posts| {
                            for (posts) |post| try word_set.put(allocator, post.doc_id, {});
                        }
                    }
                }
                if (set.count() == 0) {
                    // First word: adopt the word set.
                    var it = word_set.iterator();
                    while (it.next()) |e| try set.put(allocator, e.key_ptr.*, {});
                } else {
                    try intersect_with(allocator, set, &word_set);
                }
            }
        },
        .field_term => |ft| {
            const field_idx = index.field_index(ft.field) orelse return error.UnknownField;
            const ii = index.get_inverted(field_idx) orelse return error.UnknownField;
            if (ii.postings(ft.term)) |posts| {
                for (posts) |p| try set.put(allocator, p.doc_id, {});
            }
        },
        .numeric => |n| {
            const field_idx = index.field_index(n.field) orelse return error.UnknownField;
            const ni = index.get_numeric(field_idx) orelse return error.UnknownField;
            var out: std.ArrayListUnmanaged(u64) = .empty;
            defer out.deinit(allocator);
            try ni.range(n.min, n.max, &out);
            for (out.items) |id| try set.put(allocator, id, {});
        },
        .tag => |t| {
            const field_idx = index.field_index(t.field) orelse return error.UnknownField;
            const ti = index.get_tag(field_idx) orelse return error.UnknownField;
            for (t.tags) |tag| {
                if (ti.doc_ids(tag)) |ids| {
                    var it = ids.iterator();
                    while (it.next()) |e| try set.put(allocator, e.key_ptr.*, {});
                }
            }
        },
        .conjunction => |children| {
            // Start from all docs, intersect each child set.
            var all: DocSet = .empty;
            defer all.deinit(allocator);
            var it = index.docs.iterator();
            while (it.next()) |e| try all.put(allocator, e.value_ptr.internal_id, {});
            try intersect_with(allocator, &all, set);
            var out = all;

            for (children) |*child| {
                var child_set: DocSet = .empty;
                defer child_set.deinit(allocator);
                try collect_candidates(allocator, index, child, &child_set);
                try intersect_with(allocator, &out, &child_set);
            }
            // Copy `out` back into `set`.
            set.clearRetainingCapacity();
            var oit = out.iterator();
            while (oit.next()) |e| try set.put(allocator, e.key_ptr.*, {});
        },
        .disjunction => |children| {
            for (children) |*child| try collect_candidates(allocator, index, child, set);
        },
        .not => |child| {
            var child_set: DocSet = .empty;
            defer child_set.deinit(allocator);
            try collect_candidates(allocator, index, child, &child_set);
            var it = index.docs.iterator();
            while (it.next()) |e| {
                if (!child_set.contains(e.value_ptr.internal_id)) {
                    try set.put(allocator, e.value_ptr.internal_id, {});
                }
            }
        },
    }
}

fn intersect_with(allocator: Allocator, a: *DocSet, b: *const DocSet) !void {
    var it = a.iterator();
    var to_remove: std.ArrayListUnmanaged(u64) = .empty;
    defer to_remove.deinit(allocator);
    while (it.next()) |e| {
        if (!b.contains(e.key_ptr.*)) try to_remove.append(allocator, e.key_ptr.*);
    }
    for (to_remove.items) |id| _ = a.remove(id);
}

fn collect_terms(allocator: Allocator, index: *const SearchIndex, node: *const Node, out: *std.ArrayListUnmanaged(QueryTerm)) !void {
    switch (node.*) {
        .term => |t| try out.append(allocator, .{ .field = null, .text = t.text }),
        .field_term => |ft| {
            const field_idx = index.field_index(ft.field) orelse return error.UnknownField;
            try out.append(allocator, .{ .field = field_idx, .text = ft.term });
        },
        .phrase => |p| {
            var tokenizer = Tokenizer.init(allocator);
            defer tokenizer.deinit();
            try tokenizer.tokenize(p.text);
            for (tokenizer.tokens.items) |word| try out.append(allocator, .{ .field = null, .text = word });
        },
        .disjunction => |children| {
            for (children) |*child| try collect_terms(allocator, index, child, out);
        },
        .conjunction => |children| {
            for (children) |*child| try collect_terms(allocator, index, child, out);
        },
        else => {},
    }
}

fn score_doc(index: *const SearchIndex, terms: []const QueryTerm, internal_id: u64) f64 {
    var score: f64 = 0;
    for (terms) |t| {
        if (t.field) |field_idx| {
            if (index.get_inverted(field_idx)) |ii| {
                score += ii.bm25(internal_id, ii.doc_freq(t.text), ii.tf(internal_id, t.text));
            }
        } else {
            for (index.fields, 0..) |f, i| {
                if (f.field_type != .text) continue;
                if (index.get_inverted(@intCast(i))) |ii| {
                    score += ii.bm25(internal_id, ii.doc_freq(t.text), ii.tf(internal_id, t.text));
                }
            }
        }
    }
    return score;
}

fn find_doc_id(index: *const SearchIndex, internal_id: u64) ?[]const u8 {
    var it = index.docs.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.internal_id == internal_id) return e.key_ptr.*;
    }
    return null;
}

const SortCtx = struct {
    ascending: bool,
};

fn score_less_than(ctx: SortCtx, a: Result, b: Result) bool {
    return if (ctx.ascending) a.score < b.score else a.score > b.score;
}

fn sort_key_less_than(ctx: SortCtx, a: Result, b: Result) bool {
    const av = a.sort_key orelse -std.math.inf(f64);
    const bv = b.sort_key orelse -std.math.inf(f64);
    return if (ctx.ascending) av < bv else av > bv;
}

fn apply_sort(index: *const SearchIndex, results: *std.ArrayListUnmanaged(Result), opts: *const SearchOptions) !void {
    if (opts.sort_by) |sb| {
        if (std.ascii.eqlIgnoreCase(sb, "score")) {
            const ctx: SortCtx = .{ .ascending = opts.sort_asc };
            std.mem.sort(Result, results.items, ctx, score_less_than);
            return;
        }
        const field_idx = index.field_index(sb) orelse return error.UnknownField;
        for (results.items) |*r| {
            const doc = index.get_document(r.doc_id) orelse continue;
            r.sort_key = doc_field_value(doc, field_idx);
        }
        const ctx: SortCtx = .{ .ascending = opts.sort_asc };
        std.mem.sort(Result, results.items, ctx, sort_key_less_than);
        return;
    }
    const ctx: SortCtx = .{ .ascending = false };
    std.mem.sort(Result, results.items, ctx, score_less_than);
}

fn doc_field_value(doc: *const @import("index.zig").Document, field_idx: u16) ?f64 {
    const fv = doc.fields[field_idx] orelse return null;
    return switch (fv) {
        .numeric => |n| n,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
    };
}

const testing = std.testing;
