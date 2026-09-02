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
    const key = args[1].as_slice();

    if (store.exists(key)) return error.AlreadyExists;

    // Scan forward for the SCHEMA marker.
    var i: usize = 2;
    var schema_start: ?usize = null;
    while (i < args.len) : (i += 1) {
        if (eqlIgnoreCase(args[i].as_slice(), "SCHEMA")) {
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
        const fname = args[i].as_slice();
        if (i + 1 >= args.len) return error.SyntaxError;
        const ftype = args[i + 1].as_slice();

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
            const algo = args[i + 2].as_slice();
            if (!eqlIgnoreCase(algo, "FLAT")) return error.UnsupportedVectorAlgorithm;
            const attr_tokens = try args[i + 3].as_u64();
            if (attr_tokens % 2 != 0) return error.InvalidArgument;
            if (i + 4 + attr_tokens > args.len) return error.SyntaxError;

            var params: VectorParams = undefined;
            var dim_set = false;
            var type_set = false;
            var metric_set = false;

            var j: usize = i + 4;
            var token: u64 = 0;
            while (token < attr_tokens) : (token += 2) {
                const attr = args[j].as_slice();
                const val = args[j + 1].as_slice();
                if (eqlIgnoreCase(attr, "TYPE")) {
                    params.typ = VectorType.from_slice(val) orelse return error.InvalidArgument;
                    type_set = true;
                } else if (eqlIgnoreCase(attr, "DIM")) {
                    params.dim = try args[j + 1].as_u16();
                    if (params.dim == 0) return error.InvalidArgument;
                    dim_set = true;
                } else if (eqlIgnoreCase(attr, "DISTANCE_METRIC")) {
                    params.metric = DistanceMetric.from_slice(val) orelse return error.InvalidArgument;
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
    try store.create_search_index(key, si);

    try resp.write_ok(writer);
}

pub fn ft_dropindex(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.DROPINDEX idx [DD]
    const key = args[1].as_slice();
    if (!store.delete(key)) return error.KeyNotFound;
    try resp.write_ok(writer);
}

pub fn ft_list(writer: *Writer, store: *Store, args: []const Value) !void {
    _ = args;
    const all_keys = try store.keys(store.allocator, "");
    defer store.allocator.free(all_keys);

    var count: usize = 0;
    for (all_keys) |k| {
        if (store.get_type(k) == .search_index) count += 1;
    }

    try resp.write_list_len(writer, count);
    for (all_keys) |k| {
        if (store.get_type(k) == .search_index) {
            try resp.write_bulk_string(writer, k);
        }
    }
}

fn type_string(field_type: FieldType) []const u8 {
    return switch (field_type) {
        .text => "TEXT",
        .numeric => "NUMERIC",
        .tag => "TAG",
        .vector => "VECTOR",
    };
}

pub fn ft_info(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.INFO idx
    const key = args[1].as_slice();
    const index = try store.get_search_index(key) orelse return error.KeyNotFound;

    try resp.write_list_len(writer, 6);
    try resp.write_bulk_string(writer, "index_name");
    try resp.write_bulk_string(writer, key);
    try resp.write_bulk_string(writer, "num_docs");
    try resp.write_int(writer, @as(i64, @intCast(index.doc_count())));
    try resp.write_bulk_string(writer, "attributes");
    try resp.write_list_len(writer, index.fields.len * 2);
    for (index.fields) |f| {
        try resp.write_bulk_string(writer, f.name);
        try resp.write_bulk_string(writer, type_string(f.field_type));
    }
}

pub fn ft_add(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.ADD idx docId score [NOSAVE] [REPLACE] [LANGUAGE lang] FIELDS n f1 v1 ...
    if (args.len < 4) return error.WrongNumberOfArguments;
    const key = args[1].as_slice();
    const doc_id = args[2].as_slice();
    _ = try args[3].as_f64(); // legacy score; unused for ranking

    var replace = false;
    var fields_start: ?usize = null;
    var i: usize = 4;
    while (i < args.len) {
        const a = args[i].as_slice();
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
    const pair_count = try args[start].as_u64();
    if (start + 1 + 2 * pair_count > args.len) return error.SyntaxError;

    const index = try store.get_search_index(key) orelse return error.KeyNotFound;
    if (index.get_document(doc_id) != null and !replace) return error.DocumentExists;

    const values = try store.allocator.alloc(?FieldValue, index.fields.len);
    defer store.allocator.free(values);
    for (values) |*v| v.* = null;

    var p: usize = 0;
    while (p < pair_count) : (p += 1) {
        const fname = args[start + 1 + 2 * p].as_slice();
        const fval = args[start + 1 + 2 * p + 1].as_slice();
        const fidx = index.field_index(fname) orelse return error.FieldNotFound;
        switch (index.fields[fidx].field_type) {
            .numeric => {
                values[fidx] = .{ .numeric = std.fmt.parseFloat(f64, fval) catch return error.InvalidFloat };
            },
            else => values[fidx] = .{ .string = fval },
        }
    }

    if (replace and index.get_document(doc_id) != null) {
        _ = index.remove_document(doc_id);
    }
    try index.add_document(doc_id, values);
    try resp.write_ok(writer);
}

pub fn ft_del(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.DEL idx docId [DD]
    const key = args[1].as_slice();
    const doc_id = args[2].as_slice();
    const index = try store.get_search_index(key) orelse return error.KeyNotFound;
    const removed = index.remove_document(doc_id);
    try resp.write_int(writer, @as(i64, @intFromBool(removed)));
}

pub fn ft_get(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.GET idx docId
    const key = args[1].as_slice();
    const doc_id = args[2].as_slice();
    const index = try store.get_search_index(key) orelse return error.KeyNotFound;
    const doc = index.get_document(doc_id) orelse return error.DocumentNotFound;

    try resp.write_list_len(writer, index.fields.len * 2);
    for (index.fields, 0..) |f, fi| {
        try resp.write_bulk_string(writer, f.name);
        const fv = doc.fields[fi];
        if (fv) |v| switch (v) {
            .string => |s| try resp.write_bulk_string(writer, s),
            .numeric => |n| try resp.write_double_bulk_string(writer, n),
        } else try resp.write_null(writer);
    }
}

pub fn ft_search(writer: *Writer, store: *Store, args: []const Value) !void {
    // FT.SEARCH idx query [NOCONTENT] [WITHSCORES] [SORTBY f [ASC|DESC]]
    //                   [LIMIT off num] [RETURN n f...] [PARAMS n k v...] [DIALECT n]
    if (args.len < 3) return error.WrongNumberOfArguments;
    const key = args[1].as_slice();
    const query_str = args[2].as_slice();
    const index = try store.get_search_index(key) orelse return error.KeyNotFound;

    var opts = SearchOptions{};
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(store.allocator);

    var i: usize = 3;
    while (i < args.len) {
        const a = args[i].as_slice();
        if (eqlIgnoreCase(a, "NOCONTENT")) {
            opts.no_content = true;
            i += 1;
        } else if (eqlIgnoreCase(a, "WITHSCORES")) {
            opts.with_scores = true;
            i += 1;
        } else if (eqlIgnoreCase(a, "SORTBY")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            opts.sort_by = args[i + 1].as_slice();
            i += 2;
            if (i < args.len and eqlIgnoreCase(args[i].as_slice(), "ASC")) {
                opts.sort_asc = true;
                i += 1;
            } else if (i < args.len and eqlIgnoreCase(args[i].as_slice(), "DESC")) {
                opts.sort_asc = false;
                i += 1;
            }
        } else if (eqlIgnoreCase(a, "LIMIT")) {
            if (i + 2 >= args.len) return error.SyntaxError;
            opts.limit_offset = try args[i + 1].as_usize();
            opts.limit_count = try args[i + 2].as_usize();
            i += 3;
        } else if (eqlIgnoreCase(a, "RETURN")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            const count = try args[i + 1].as_usize();
            if (i + 1 + count >= args.len + 1) return error.SyntaxError;
            var fields: std.ArrayListUnmanaged([]const u8) = .empty;
            defer fields.deinit(store.allocator);
            var j: usize = 0;
            while (j < count) : (j += 1) {
                try fields.append(store.allocator, args[i + 2 + j].as_slice());
            }
            opts.return_fields = try fields.toOwnedSlice(store.allocator);
            defer store.allocator.free(opts.return_fields.?);
            i += 2 + count;
        } else if (eqlIgnoreCase(a, "PARAMS")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            const count = try args[i + 1].as_usize();
            if (i + 1 + 2 * count > args.len) return error.SyntaxError;
            var j: usize = 0;
            while (j < count) : (j += 1) {
                const name = args[i + 2 + 2 * j].as_slice();
                const value = args[i + 3 + 2 * j].as_slice();
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

    try resp.write_list_len(writer, results.items.len);
    for (results.items) |r| {
        try resp.write_bulk_string(writer, r.doc_id);
        if (opts.with_scores) try resp.write_double_bulk_string(writer, r.score);
        if (opts.no_content) continue;

        const doc = index.get_document(r.doc_id) orelse continue;
        const nfields = if (opts.return_fields) |rfs| rfs.len else index.fields.len;
        try resp.write_list_len(writer, nfields * 2);

        if (opts.return_fields) |rfs| {
            for (rfs) |fname| {
                try resp.write_bulk_string(writer, fname);
                const field_idx = index.field_index(fname) orelse {
                    try resp.write_null(writer);
                    continue;
                };
                const fv = doc.fields[field_idx];
                if (fv) |v| switch (v) {
                    .string => |s| try resp.write_bulk_string(writer, s),
                    .numeric => |n| try resp.write_double_bulk_string(writer, n),
                } else try resp.write_null(writer);
            }
        } else {
            for (index.fields, 0..) |f, fi| {
                try resp.write_bulk_string(writer, f.name);
                const fv = doc.fields[fi];
                if (fv) |v| switch (v) {
                    .string => |s| try resp.write_bulk_string(writer, s),
                    .numeric => |n| try resp.write_double_bulk_string(writer, n),
                } else try resp.write_null(writer);
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
    try testing.expect(store.get_search_index("idx1") == null);
}

fn vec_f32_blob(values: []const f32) []const u8 {
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
    kv.attach_store(&store);

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
        .{ .data = "FT.ADD" }, .{ .data = "vidx" },           .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "4" },              .{ .data = "title" }, .{ .data = "the quick brown fox jumps over the lazy dog, repeatedly, with many words to grow the posting arrays well beyond any initial capacity" },
        .{ .data = "price" },  .{ .data = "9.99" },           .{ .data = "color" }, .{ .data = "red,blue" },
        .{ .data = "v" },      vec_f32_blob(&[_]f32{ 0, 0 }),
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
        .{ .data = "FT.ADD" }, .{ .data = "vidx" },           .{ .data = "doc1" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "2" },              .{ .data = "title" }, .{ .data = "first" },
        .{ .data = "v" },      vec_f32_blob(&[_]f32{ 0, 0 }),
    };
    var buf2: [8192]u8 = undefined;
    var writer2 = Writer.fixed(&buf2);
    try ft_add(&writer2, &store, &add);

    const add2 = [_]Value{
        .{ .data = "FT.ADD" }, .{ .data = "vidx" },             .{ .data = "doc2" },  .{ .data = "1.0" },
        .{ .data = "FIELDS" }, .{ .data = "2" },                .{ .data = "title" }, .{ .data = "second" },
        .{ .data = "v" },      vec_f32_blob(&[_]f32{ 10, 10 }),
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
        vec_f32_blob(&[_]f32{ 0, 0 }),
        .{ .data = "DIALECT" },
        .{ .data = "2" },
    };
    try ft_search(&writer4, &store, &search_args);
    const out = writer4.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "doc1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doc2") == null);
}
