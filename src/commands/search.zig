const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");
const SearchIndex = @import("../search/index.zig").SearchIndex;
const FieldDef = @import("../search/index.zig").FieldDef;
const FieldValue = @import("../search/index.zig").FieldValue;
const FieldType = @import("../search/index.zig").FieldType;
const VectorParams = @import("../search/vector.zig").VectorParams;
const VectorType = @import("../search/vector.zig").VectorType;
const DistanceMetric = @import("../search/vector.zig").DistanceMetric;
const Clock = @import("../clock.zig");
const search_engine = @import("../search/search.zig");
const SearchOptions = search_engine.SearchOptions;

const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

pub fn ft_create(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.CREATE index [ON HASH] [PREFIX count prefix...] SCHEMA field type [type options]...
    if (args.len < 2) return error.WrongNumberOfArguments;
    const key = args[1].asSlice();

    if (store.exists(key)) return error.AlreadyExists;

    // Scan forward for the SCHEMA marker.
    var i: usize = 2;
    var schema_start: ?usize = null;
    while (i < args.len) : (i += 1) {
        if (eqlIgnoreCase(args[i].asSlice(), "SCHEMA")) {
            schema_start = i + 1;
            break;
        }
    }
    const start = schema_start orelse return error.SyntaxError;
    if (start >= args.len) return error.SyntaxError;

    var fields: std.ArrayListUnmanaged(FieldDef) = .empty;
    errdefer {
        for (fields.items) |f| store.allocator.free(f.name);
        fields.deinit(store.allocator);
    }

    i = start;
    while (i < args.len) {
        const fname = args[i].asSlice();
        if (i + 1 >= args.len) return error.SyntaxError;
        const ftype = args[i + 1].asSlice();

        const name_owned = try store.allocator.dupe(u8, fname);
        errdefer store.allocator.free(name_owned);

        if (eqlIgnoreCase(ftype, "TEXT")) {
            try fields.append(store.allocator, .{ .name = name_owned, .field_type = .text });
            i += 2;
        } else if (eqlIgnoreCase(ftype, "NUMERIC")) {
            try fields.append(store.allocator, .{ .name = name_owned, .field_type = .numeric });
            i += 2;
        } else if (eqlIgnoreCase(ftype, "TAG")) {
            try fields.append(store.allocator, .{ .name = name_owned, .field_type = .tag });
            i += 2;
        } else if (eqlIgnoreCase(ftype, "VECTOR")) {
            // VECTOR <algo> <count> <attr> <val> ...  (count = number of tokens)
            if (i + 3 >= args.len) return error.SyntaxError;
            const algo = args[i + 2].asSlice();
            if (!eqlIgnoreCase(algo, "FLAT")) return error.UnsupportedVectorAlgorithm;
            const attr_tokens = try args[i + 3].asU64();
            if (attr_tokens % 2 != 0) return error.InvalidArgument;
            if (i + 4 + attr_tokens > args.len) return error.SyntaxError;

            var params: VectorParams = undefined;
            var dim_set = false;
            var type_set = false;
            var metric_set = false;

            var j: usize = i + 4;
            var token: u64 = 0;
            while (token < attr_tokens) : (token += 2) {
                const attr = args[j].asSlice();
                const val = args[j + 1].asSlice();
                if (eqlIgnoreCase(attr, "TYPE")) {
                    params.typ = VectorType.fromSlice(val) orelse return error.InvalidArgument;
                    type_set = true;
                } else if (eqlIgnoreCase(attr, "DIM")) {
                    params.dim = try args[j + 1].asU16();
                    if (params.dim == 0) return error.InvalidArgument;
                    dim_set = true;
                } else if (eqlIgnoreCase(attr, "DISTANCE_METRIC")) {
                    params.metric = DistanceMetric.fromSlice(val) orelse return error.InvalidArgument;
                    metric_set = true;
                }
                j += 2;
            }
            if (!(dim_set and type_set and metric_set)) return error.InvalidArgument;

            try fields.append(store.allocator, .{ .name = name_owned, .field_type = .{ .vector = params } });
            i = j;
        } else {
            return error.InvalidArgument;
        }
    }

    // Reject duplicate field names.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(store.allocator);
    for (fields.items) |f| {
        if (seen.contains(f.name)) return error.InvalidArgument;
        try seen.put(store.allocator, f.name, {});
    }

    const owned_fields = try fields.toOwnedSlice(store.allocator);
    const si = SearchIndex.init(store.allocator, owned_fields);
    try store.createSearchIndex(key, si);

    try resp.writeOK(writer);
}

pub fn ft_dropindex(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.DROPINDEX idx [DD]
    const key = args[1].asSlice();
    if (!store.delete(key)) return error.KeyNotFound;
    try resp.writeOK(writer);
}

pub fn ft_list(writer: *Writer, store: *Store, args: []const Value) !void {
    _ = args;
    const all_keys = try store.keys(store.allocator, "");
    defer store.allocator.free(all_keys);

    var count: usize = 0;
    for (all_keys) |k| {
        if (store.getType(k) == .search_index) count += 1;
    }

    try resp.writeListLen(writer, count);
    for (all_keys) |k| {
        if (store.getType(k) == .search_index) {
            try resp.writeBulkString(writer, k);
        }
    }
}

fn typeString(field_type: FieldType) []const u8 {
    return switch (field_type) {
        .text => "TEXT",
        .numeric => "NUMERIC",
        .tag => "TAG",
        .vector => "VECTOR",
    };
}

pub fn ft_info(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.INFO idx
    const key = args[1].asSlice();
    const index = try store.getSearchIndex(key) orelse return error.KeyNotFound;

    try resp.writeListLen(writer, 6);
    try resp.writeBulkString(writer, "index_name");
    try resp.writeBulkString(writer, key);
    try resp.writeBulkString(writer, "num_docs");
    try resp.writeInt(writer, @as(i64, @intCast(index.docCount())));
    try resp.writeBulkString(writer, "attributes");
    try resp.writeListLen(writer, index.fields.len * 2);
    for (index.fields) |f| {
        try resp.writeBulkString(writer, f.name);
        try resp.writeBulkString(writer, typeString(f.field_type));
    }
}

pub fn ft_add(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.ADD idx docId score [NOSAVE] [REPLACE] [LANGUAGE lang] FIELDS n f1 v1 ...
    if (args.len < 4) return error.WrongNumberOfArguments;
    const key = args[1].asSlice();
    const doc_id = args[2].asSlice();
    _ = try args[3].asF64(); // legacy score; unused for ranking

    var replace = false;
    var fields_start: ?usize = null;
    var i: usize = 4;
    while (i < args.len) {
        const a = args[i].asSlice();
        if (eqlIgnoreCase(a, "REPLACE")) {
            replace = true;
            i += 1;
        } else if (eqlIgnoreCase(a, "NOSAVE")) {
            i += 1;
        } else if (eqlIgnoreCase(a, "LANGUAGE")) {
            i += 2;
        } else if (eqlIgnoreCase(a, "FIELDS")) {
            fields_start = i + 1;
            break;
        } else {
            i += 1;
        }
    }

    const start = fields_start orelse return error.SyntaxError;
    if (start >= args.len) return error.SyntaxError;
    const pair_count = try args[start].asU64();
    if (start + 1 + 2 * pair_count > args.len) return error.SyntaxError;

    const index = try store.getSearchIndex(key) orelse return error.KeyNotFound;
    if (index.getDocument(doc_id) != null and !replace) return error.DocumentExists;

    const values = try store.allocator.alloc(?FieldValue, index.fields.len);
    defer store.allocator.free(values);
    for (values) |*v| v.* = null;

    var p: usize = 0;
    while (p < pair_count) : (p += 1) {
        const fname = args[start + 1 + 2 * p].asSlice();
        const fval = args[start + 1 + 2 * p + 1].asSlice();
        const fidx = index.fieldIndex(fname) orelse return error.FieldNotFound;
        switch (index.fields[fidx].field_type) {
            .numeric => {
                values[fidx] = .{ .numeric = std.fmt.parseFloat(f64, fval) catch return error.InvalidFloat };
            },
            else => values[fidx] = .{ .string = fval },
        }
    }

    if (replace and index.getDocument(doc_id) != null) {
        _ = index.removeDocument(doc_id);
    }
    try index.addDocument(doc_id, values);
    try resp.writeOK(writer);
}

pub fn ft_del(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.DEL idx docId [DD]
    const key = args[1].asSlice();
    const doc_id = args[2].asSlice();
    const index = try store.getSearchIndex(key) orelse return error.KeyNotFound;
    const removed = index.removeDocument(doc_id);
    try resp.writeInt(writer, @as(i64, @intFromBool(removed)));
}

pub fn ft_get(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.GET idx docId
    const key = args[1].asSlice();
    const doc_id = args[2].asSlice();
    const index = try store.getSearchIndex(key) orelse return error.KeyNotFound;
    const doc = index.getDocument(doc_id) orelse return error.DocumentNotFound;

    try resp.writeListLen(writer, index.fields.len * 2);
    for (index.fields, 0..) |f, fi| {
        try resp.writeBulkString(writer, f.name);
        const fv = doc.fields[fi];
        if (fv) |v| switch (v) {
            .string => |s| try resp.writeBulkString(writer, s),
            .numeric => |n| try resp.writeDoubleBulkString(writer, n),
        } else try resp.writeNull(writer);
    }
}

pub fn ft_search(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.SEARCH idx query [NOCONTENT] [WITHSCORES] [SORTBY f [ASC|DESC]]
    //                   [LIMIT off num] [RETURN n f...] [PARAMS n k v...] [DIALECT n]
    if (args.len < 3) return error.WrongNumberOfArguments;
    const key = args[1].asSlice();
    const query_str = args[2].asSlice();
    const index = try store.getSearchIndex(key) orelse return error.KeyNotFound;

    var opts = SearchOptions{};
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(store.allocator);

    var i: usize = 3;
    while (i < args.len) {
        const a = args[i].asSlice();
        if (eqlIgnoreCase(a, "NOCONTENT")) {
            opts.no_content = true;
            i += 1;
        } else if (eqlIgnoreCase(a, "WITHSCORES")) {
            opts.with_scores = true;
            i += 1;
        } else if (eqlIgnoreCase(a, "SORTBY")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            opts.sort_by = args[i + 1].asSlice();
            i += 2;
            if (i < args.len and eqlIgnoreCase(args[i].asSlice(), "ASC")) {
                opts.sort_asc = true;
                i += 1;
            } else if (i < args.len and eqlIgnoreCase(args[i].asSlice(), "DESC")) {
                opts.sort_asc = false;
                i += 1;
            }
        } else if (eqlIgnoreCase(a, "LIMIT")) {
            if (i + 2 >= args.len) return error.SyntaxError;
            opts.limit_offset = try args[i + 1].asUsize();
            opts.limit_count = try args[i + 2].asUsize();
            i += 3;
        } else if (eqlIgnoreCase(a, "RETURN")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            const count = try args[i + 1].asUsize();
            if (i + 1 + count >= args.len + 1) return error.SyntaxError;
            var fields: std.ArrayListUnmanaged([]const u8) = .empty;
            defer fields.deinit(store.allocator);
            var j: usize = 0;
            while (j < count) : (j += 1) {
                try fields.append(store.allocator, args[i + 2 + j].asSlice());
            }
            opts.return_fields = try fields.toOwnedSlice(store.allocator);
            defer store.allocator.free(opts.return_fields.?);
            i += 2 + count;
        } else if (eqlIgnoreCase(a, "PARAMS")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            const count = try args[i + 1].asUsize();
            if (i + 1 + 2 * count > args.len) return error.SyntaxError;
            var j: usize = 0;
            while (j < count) : (j += 1) {
                const name = args[i + 2 + 2 * j].asSlice();
                const value = args[i + 3 + 2 * j].asSlice();
                try params.put(store.allocator, name, value);
            }
            i += 2 + 2 * count;
        } else if (eqlIgnoreCase(a, "DIALECT")) {
            i += 2;
        } else {
            return error.SyntaxError;
        }
    }

    var results = try search_engine.search(store.allocator, index, query_str, &params, &opts);
    defer results.deinit(store.allocator);

    try resp.writeListLen(writer, results.items.len);
    for (results.items) |r| {
        try resp.writeBulkString(writer, r.doc_id);
        if (opts.with_scores) try resp.writeDoubleBulkString(writer, r.score);
        if (opts.no_content) continue;

        const doc = index.getDocument(r.doc_id) orelse continue;
        const nfields = if (opts.return_fields) |rfs| rfs.len else index.fields.len;
        try resp.writeListLen(writer, nfields * 2);

        if (opts.return_fields) |rfs| {
            for (rfs) |fname| {
                try resp.writeBulkString(writer, fname);
                const field_idx = index.fieldIndex(fname) orelse {
                    try resp.writeNull(writer);
                    continue;
                };
                const fv = doc.fields[field_idx];
                if (fv) |v| switch (v) {
                    .string => |s| try resp.writeBulkString(writer, s),
                    .numeric => |n| try resp.writeDoubleBulkString(writer, n),
                } else try resp.writeNull(writer);
            }
        } else {
            for (index.fields, 0..) |f, fi| {
                try resp.writeBulkString(writer, f.name);
                const fv = doc.fields[fi];
                if (fv) |v| switch (v) {
                    .string => |s| try resp.writeBulkString(writer, s),
                    .numeric => |n| try resp.writeDoubleBulkString(writer, n),
                } else try resp.writeNull(writer);
            }
        }
    }
}

const testing = std.testing;

test "FT.CREATE then FT.INFO" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);

    const create_args = [_]Value{
        .{ .data = "FT.CREATE" },
        .{ .data = "idx" },
        .{ .data = "SCHEMA" },
        .{ .data = "title" },
        .{ .data = "TEXT" },
        .{ .data = "price" },
        .{ .data = "NUMERIC" },
    };
    try ft_create(&writer, &store, &create_args);
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    const info_args = [_]Value{ .{ .data = "FT.INFO" }, .{ .data = "idx" } };
    try ft_info(&writer2, &store, &info_args);
    const out = writer2.buffered();
    try testing.expect(out[0] == '*');
}

test "FT.CREATE with VECTOR field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);

    const create_args = [_]Value{
        .{ .data = "FT.CREATE" },
        .{ .data = "vecidx" },
        .{ .data = "SCHEMA" },
        .{ .data = "v" },
        .{ .data = "VECTOR" },
        .{ .data = "FLAT" },
        .{ .data = "6" },
        .{ .data = "TYPE" },
        .{ .data = "FLOAT32" },
        .{ .data = "DIM" },
        .{ .data = "2" },
        .{ .data = "DISTANCE_METRIC" },
        .{ .data = "L2" },
    };
    try ft_create(&writer, &store, &create_args);
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 1), store.size());
}

test "FT.ADD document then FT.GET" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" }, .{ .data = "idx" },  .{ .data = "SCHEMA" },
        .{ .data = "title" },     .{ .data = "TEXT" }, .{ .data = "price" },
        .{ .data = "NUMERIC" },
    };
    try ft_create(&writer, &store, &create_args);

    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    const add_args = [_]Value{
        .{ .data = "FT.ADD" },
        .{ .data = "idx" },
        .{ .data = "doc1" },
        .{ .data = "1.0" },
        .{ .data = "FIELDS" },
        .{ .data = "2" },
        .{ .data = "title" },
        .{ .data = "hello world" },
        .{ .data = "price" },
        .{ .data = "9.99" },
    };
    try ft_add(&writer2, &store, &add_args);
    try testing.expectEqualStrings("+OK\r\n", writer2.buffered());

    var buf3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buf3);
    const get_args = [_]Value{ .{ .data = "FT.GET" }, .{ .data = "idx" }, .{ .data = "doc1" } };
    try ft_get(&writer3, &store, &get_args);
    const out = writer3.buffered();
    try testing.expect(out[0] == '*');

    var buf4: [4096]u8 = undefined;
    var writer4 = Writer.fixed(&buf4);
    const del_args = [_]Value{ .{ .data = "FT.DEL" }, .{ .data = "idx" }, .{ .data = "doc1" } };
    try ft_del(&writer4, &store, &del_args);
    try testing.expectEqualStrings(":1\r\n", writer4.buffered());
}

test "FT.ADD rejects duplicate without REPLACE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" }, .{ .data = "idx" },  .{ .data = "SCHEMA" },
        .{ .data = "title" },     .{ .data = "TEXT" },
    };
    try ft_create(&writer, &store, &create_args);

    const add = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "idx" }, .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "1" },   .{ .data = "title" }, .{ .data = "a" },
    };
    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    try ft_add(&writer2, &store, &add);

    var buf3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buf3);
    try testing.expectError(error.DocumentExists, ft_add(&writer3, &store, &add));
}

test "FT._LIST returns created indexes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" }, .{ .data = "idx1" }, .{ .data = "SCHEMA" },
        .{ .data = "title" },     .{ .data = "TEXT" },
    };
    try ft_create(&writer, &store, &create_args);
    try store.set("notanindex", "x");

    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    const list_args = [_]Value{.{ .data = "FT._LIST" }};
    try ft_list(&writer2, &store, &list_args);
    const out = writer2.buffered();
    try testing.expect(out[0] == '*');
    try testing.expect(std.mem.indexOf(u8, out, "idx1") != null);
}

test "FT.DROPINDEX removes index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" }, .{ .data = "idx1" }, .{ .data = "SCHEMA" },
        .{ .data = "title" },     .{ .data = "TEXT" },
    };
    try ft_create(&writer, &store, &create_args);

    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    const drop_args = [_]Value{ .{ .data = "FT.DROPINDEX" }, .{ .data = "idx1" } };
    try ft_dropindex(&writer2, &store, &drop_args);
    try testing.expectEqualStrings("+OK\r\n", writer2.buffered());
    try testing.expect(store.getSearchIndex("idx1") == null);
}

fn vecF32Blob(values: []const f32) []const u8 {
    return std.mem.sliceAsBytes(values);
}

test "FT.ADD under kv allocator does not OOM" {
    const KeyValueAllocator = @import("../kv_allocator.zig");
    var kv = try KeyValueAllocator.init(testing.allocator, 1024 * 1024, .allkeys_lru);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 16,
        .eviction_policy = .allkeys_lru,
    });
    defer store.deinit();
    kv.attachStore(&store);

    var buf: [8192]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" },
        .{ .data = "vidx" },
        .{ .data = "SCHEMA" },
        .{ .data = "title" },
        .{ .data = "TEXT" },
        .{ .data = "price" },
        .{ .data = "NUMERIC" },
        .{ .data = "color" },
        .{ .data = "TAG" },
        .{ .data = "v" },
        .{ .data = "VECTOR" },
        .{ .data = "FLAT" },
        .{ .data = "6" },
        .{ .data = "TYPE" },
        .{ .data = "FLOAT32" },
        .{ .data = "DIM" },
        .{ .data = "2" },
        .{ .data = "DISTANCE_METRIC" },
        .{ .data = "L2" },
    };
    try ft_create(&writer, &store, &create_args);

    var buf2: [8192]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    const add = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "vidx" },         .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "4" },            .{ .data = "title" }, .{ .data = "the quick brown fox jumps over the lazy dog, repeatedly, with many words to grow the posting arrays well beyond any initial capacity" },
        .{ .data = "price" },  .{ .data = "9.99" },         .{ .data = "color" }, .{ .data = "red,blue" },
        .{ .data = "v" },      vecF32Blob(&[_]f32{ 0, 0 }),
    };
    try ft_add(&writer2, &store, &add);
    try testing.expectEqualStrings("+OK\r\n", writer2.buffered());
}

test "FT.SEARCH text query returns matching docs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" }, .{ .data = "idx" },  .{ .data = "SCHEMA" },
        .{ .data = "title" },     .{ .data = "TEXT" },
    };
    try ft_create(&writer, &store, &create_args);

    const add = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "idx" }, .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "1" },   .{ .data = "title" }, .{ .data = "the quick fox" },
    };
    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    try ft_add(&writer2, &store, &add);

    const add2 = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "idx" }, .{ .data = "doc2" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "1" },   .{ .data = "title" }, .{ .data = "the lazy dog" },
    };
    var buf3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buf3);
    try ft_add(&writer3, &store, &add2);

    var buf4: [4096]u8 = undefined;
    var writer4 = Writer.fixed(&buf4);
    const search_args = [_]Value{
        .{ .data = "FT.SEARCH" }, .{ .data = "idx" }, .{ .data = "quick" },
    };
    try ft_search(&writer4, &store, &search_args);
    const out = writer4.buffered();
    try testing.expect(out[0] == '*');
    try testing.expect(std.mem.indexOf(u8, out, "doc1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doc2") == null);
}

test "FT.SEARCH numeric range filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" }, .{ .data = "idx" },     .{ .data = "SCHEMA" },
        .{ .data = "price" },     .{ .data = "NUMERIC" },
    };
    try ft_create(&writer, &store, &create_args);

    const add = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "idx" }, .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "1" },   .{ .data = "price" }, .{ .data = "9.99" },
    };
    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    try ft_add(&writer2, &store, &add);

    const add2 = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "idx" }, .{ .data = "doc2" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "1" },   .{ .data = "price" }, .{ .data = "80.00" },
    };
    var buf3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buf3);
    try ft_add(&writer3, &store, &add2);

    var buf4: [4096]u8 = undefined;
    var writer4 = Writer.fixed(&buf4);
    const search_args = [_]Value{
        .{ .data = "FT.SEARCH" }, .{ .data = "idx" }, .{ .data = "@price:[0 50]" },
    };
    try ft_search(&writer4, &store, &search_args);
    const out = writer4.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "doc1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doc2") == null);
}

test "FT.SEARCH tag filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" }, .{ .data = "idx" }, .{ .data = "SCHEMA" },
        .{ .data = "color" },     .{ .data = "TAG" },
    };
    try ft_create(&writer, &store, &create_args);

    const add = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "idx" }, .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "1" },   .{ .data = "color" }, .{ .data = "red,blue" },
    };
    var buf2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    try ft_add(&writer2, &store, &add);

    const add2 = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "idx" }, .{ .data = "doc2" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "1" },   .{ .data = "color" }, .{ .data = "green" },
    };
    var buf3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buf3);
    try ft_add(&writer3, &store, &add2);

    var buf4: [4096]u8 = undefined;
    var writer4 = Writer.fixed(&buf4);
    const search_args = [_]Value{
        .{ .data = "FT.SEARCH" }, .{ .data = "idx" }, .{ .data = "@color:{red}" },
    };
    try ft_search(&writer4, &store, &search_args);
    const out = writer4.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "doc1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doc2") == null);
}

test "FT.SEARCH vector KNN returns nearest doc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    const create_args = [_]Value{
        .{ .data = "FT.CREATE" },
        .{ .data = "vidx" },
        .{ .data = "SCHEMA" },
        .{ .data = "title" },
        .{ .data = "TEXT" },
        .{ .data = "v" },
        .{ .data = "VECTOR" },
        .{ .data = "FLAT" },
        .{ .data = "6" },
        .{ .data = "TYPE" },
        .{ .data = "FLOAT32" },
        .{ .data = "DIM" },
        .{ .data = "2" },
        .{ .data = "DISTANCE_METRIC" },
        .{ .data = "L2" },
    };
    try ft_create(&writer, &store, &create_args);

    const add = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "vidx" },         .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "2" },            .{ .data = "title" }, .{ .data = "first" },
        .{ .data = "v" },      vecF32Blob(&[_]f32{ 0, 0 }),
    };
    var buf2: [8192]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    try ft_add(&writer2, &store, &add);

    const add2 = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "vidx" },           .{ .data = "doc2" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "2" },              .{ .data = "title" }, .{ .data = "second" },
        .{ .data = "v" },      vecF32Blob(&[_]f32{ 10, 10 }),
    };
    var buf3: [8192]u8 = undefined;
    var writer3 = Writer.fixed(&buf3);
    try ft_add(&writer3, &store, &add2);

    var buf4: [8192]u8 = undefined;
    var writer4 = Writer.fixed(&buf4);
    const search_args = [_]Value{
        .{ .data = "FT.SEARCH" },
        .{ .data = "vidx" },
        .{ .data = "*=>[KNN 1 @v $B]" },
        .{ .data = "PARAMS" },
        .{ .data = "2" },
        .{ .data = "B" },
        vecF32Blob(&[_]f32{ 0, 0 }),
        .{ .data = "DIALECT" },
        .{ .data = "2" },
    };
    try ft_search(&writer4, &store, &search_args);
    const out = writer4.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "doc1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doc2") == null);
}
