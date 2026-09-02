const std = @import("std");
const InvertedIndex = @import("inverted.zig").InvertedIndex;
const NumericIndex = @import("numeric.zig").NumericIndex;
const TagIndex = @import("tag.zig").TagIndex;
const VectorIndex = @import("vector.zig").VectorIndex;
const VectorParams = @import("vector.zig").VectorParams;

pub const Allocator = std.mem.Allocator;

pub const FieldType = union(enum) {
    text,
    numeric,
    tag,
    vector: VectorParams,
};

pub const FieldDef = struct {
    name: []const u8,
    field_type: FieldType,
};

pub const FieldValue = union(enum) {
    string: []const u8,
    numeric: f64,
};

pub const Document = struct {
    internal_id: u64,
    fields: []?FieldValue,
};

pub const SearchIndex = struct {
    allocator: Allocator,
    fields: []FieldDef,
    field_map: std.StringHashMapUnmanaged(u16) = .empty,
    docs: std.StringHashMapUnmanaged(Document) = .empty,
    doc_counter: u64 = 0,

    inverted: std.AutoHashMapUnmanaged(u16, InvertedIndex) = .empty,
    numeric: std.AutoHashMapUnmanaged(u16, NumericIndex) = .empty,
    tag: std.AutoHashMapUnmanaged(u16, TagIndex) = .empty,
    vector: std.AutoHashMapUnmanaged(u16, VectorIndex) = .empty,

    pub fn init(allocator: Allocator, fields: []FieldDef) SearchIndex {
        var field_map: std.StringHashMapUnmanaged(u16) = .empty;
        field_map.ensureTotalCapacity(allocator, @intCast(fields.len)) catch {};
        for (fields, 0..) |field, i| {
            field_map.putAssumeCapacity(field.name, @intCast(i));
        }
        return .{
            .allocator = allocator,
            .fields = fields,
            .field_map = field_map,
        };
    }

    pub fn deinit(self: *SearchIndex) void {
        var doc_it = self.docs.iterator();
        while (doc_it.next()) |entry| {
            const doc = entry.value_ptr;
            self.free_field_values(doc);
            self.allocator.free(doc.fields);
            self.allocator.free(entry.key_ptr.*);
        }
        self.docs.deinit(self.allocator);
        self.field_map.deinit(self.allocator);

        var inv_it = self.inverted.iterator();
        while (inv_it.next()) |e| e.value_ptr.deinit();
        self.inverted.deinit(self.allocator);

        var num_it = self.numeric.iterator();
        while (num_it.next()) |e| e.value_ptr.deinit();
        self.numeric.deinit(self.allocator);

        var tag_it = self.tag.iterator();
        while (tag_it.next()) |e| e.value_ptr.deinit();
        self.tag.deinit(self.allocator);

        var vec_it = self.vector.iterator();
        while (vec_it.next()) |e| e.value_ptr.deinit();
        self.vector.deinit(self.allocator);

        for (self.fields) |field| {
            self.allocator.free(field.name);
        }
        self.allocator.free(self.fields);
    }

    pub fn field_index(self: *const SearchIndex, name: []const u8) ?u16 {
        return self.field_map.get(name);
    }

    pub fn doc_count(self: *const SearchIndex) u64 {
        return self.docs.count();
    }

    /// Adds a document. `values` must be aligned to `self.fields` (null for
    /// absent fields). Returns error.DocumentExists if the doc id is taken.
    pub fn add_document(self: *SearchIndex, doc_id: []const u8, values: []const ?FieldValue) !void {
        if (self.docs.contains(doc_id)) return error.DocumentExists;
        if (values.len != self.fields.len) return error.FieldCountMismatch;

        const internal_id = self.doc_counter + 1;
        self.doc_counter = internal_id;

        const owned_key = try self.allocator.dupe(u8, doc_id);
        errdefer self.allocator.free(owned_key);

        const owned_fields = try self.allocator.alloc(?FieldValue, self.fields.len);
        errdefer self.allocator.free(owned_fields);
        for (values, 0..) |fv, i| {
            owned_fields[i] = if (fv) |v| switch (v) {
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                .numeric => v,
            } else null;
        }

        const doc = Document{ .internal_id = internal_id, .fields = owned_fields };
        try self.docs.put(self.allocator, owned_key, doc);

        for (self.fields, 0..) |field, i| {
            const fv = owned_fields[i] orelse continue;
            const field_idx: u16 = @intCast(i);
            try self.index_value(field.field_type, field_idx, internal_id, fv);
        }
    }

    /// Removes a document and de-indexes its fields. Returns false if absent.
    pub fn remove_document(self: *SearchIndex, doc_id: []const u8) bool {
        const kv = self.docs.fetchRemove(doc_id) orelse return false;
        const doc = kv.value;

        for (self.fields, 0..) |field, i| {
            const fv = doc.fields[i] orelse continue;
            const field_idx: u16 = @intCast(i);
            self.deindex_value(field.field_type, field_idx, doc.internal_id, fv);
        }

        self.allocator.free(kv.key);
        self.free_field_values(&doc);
        self.allocator.free(doc.fields);
        return true;
    }

    pub fn get_document(self: *const SearchIndex, doc_id: []const u8) ?*const Document {
        return self.docs.getPtr(doc_id);
    }

    pub fn get_inverted(self: *const SearchIndex, field_idx: u16) ?*const InvertedIndex {
        return self.inverted.getPtr(field_idx);
    }

    pub fn get_numeric(self: *const SearchIndex, field_idx: u16) ?*const NumericIndex {
        return self.numeric.getPtr(field_idx);
    }

    pub fn get_tag(self: *const SearchIndex, field_idx: u16) ?*const TagIndex {
        return self.tag.getPtr(field_idx);
    }

    pub fn get_vector(self: *const SearchIndex, field_idx: u16) ?*const VectorIndex {
        return self.vector.getPtr(field_idx);
    }

    fn index_value(self: *SearchIndex, field_type: FieldType, field_idx: u16, doc_id: u64, fv: FieldValue) !void {
        switch (field_type) {
            .text => switch (fv) {
                .string => |s| try self.index_text(field_idx, doc_id, s),
                else => {},
            },
            .numeric => switch (fv) {
                .numeric => |n| try self.index_numeric(field_idx, doc_id, n),
                else => {},
            },
            .tag => switch (fv) {
                .string => |s| try self.index_tag(field_idx, doc_id, s),
                else => {},
            },
            .vector => |vp| switch (fv) {
                .string => |blob| try self.index_vector(field_idx, vp, doc_id, blob),
                else => {},
            },
        }
    }

    fn deindex_value(self: *SearchIndex, field_type: FieldType, field_idx: u16, doc_id: u64, fv: FieldValue) void {
        switch (field_type) {
            .text => switch (fv) {
                .string => |s| if (self.inverted.getPtr(field_idx)) |ii| ii.remove(doc_id, s),
                else => {},
            },
            .numeric => switch (fv) {
                .numeric => |n| {
                    _ = n;
                    if (self.numeric.getPtr(field_idx)) |ni| ni.remove(doc_id);
                },
                else => {},
            },
            .tag => switch (fv) {
                .string => |s| if (self.tag.getPtr(field_idx)) |ti| ti.remove(doc_id, s),
                else => {},
            },
            .vector => switch (fv) {
                .string => |blob| {
                    _ = blob;
                    if (self.vector.getPtr(field_idx)) |vi| vi.remove(doc_id);
                },
                else => {},
            },
        }
    }

    fn index_text(self: *SearchIndex, field_idx: u16, doc_id: u64, text: []const u8) !void {
        const gop = try self.inverted.getOrPut(self.allocator, field_idx);
        if (!gop.found_existing) gop.value_ptr.* = InvertedIndex.init(self.allocator);
        try gop.value_ptr.add(doc_id, text);
    }

    fn index_numeric(self: *SearchIndex, field_idx: u16, doc_id: u64, value: f64) !void {
        const gop = try self.numeric.getOrPut(self.allocator, field_idx);
        if (!gop.found_existing) gop.value_ptr.* = NumericIndex.init(self.allocator);
        try gop.value_ptr.add(doc_id, value);
    }

    fn index_tag(self: *SearchIndex, field_idx: u16, doc_id: u64, value: []const u8) !void {
        const gop = try self.tag.getOrPut(self.allocator, field_idx);
        if (!gop.found_existing) gop.value_ptr.* = TagIndex.init(self.allocator);
        try gop.value_ptr.add(doc_id, value);
    }

    fn index_vector(self: *SearchIndex, field_idx: u16, params: VectorParams, doc_id: u64, blob: []const u8) !void {
        const gop = try self.vector.getOrPut(self.allocator, field_idx);
        if (!gop.found_existing) gop.value_ptr.* = VectorIndex.init(self.allocator, params);
        try gop.value_ptr.add(doc_id, blob);
    }

    fn free_field_values(self: *SearchIndex, doc: *const Document) void {
        for (doc.fields) |field_value| {
            if (field_value) |fv| {
                switch (fv) {
                    .string => |s| self.allocator.free(s),
                    .numeric => {},
                }
            }
        }
    }
};

const testing = std.testing;

fn make_fields() ![]FieldDef {
    return try testing.allocator.dupe(FieldDef, &.{
        .{ .name = try testing.allocator.dupe(u8, "title"), .field_type = .text },
        .{ .name = try testing.allocator.dupe(u8, "price"), .field_type = .numeric },
        .{ .name = try testing.allocator.dupe(u8, "color"), .field_type = .tag },
        .{ .name = try testing.allocator.dupe(u8, "v"), .field_type = .{ .vector = .{
            .dim = 2,
            .typ = .float32,
            .metric = .l2,
        } } },
    });
}

fn vec_f32(values: []const f32) []const u8 {
    return std.mem.sliceAsBytes(values);
}

test "SearchIndex init and deinit" {
    const fields = try make_fields();
    var index = SearchIndex.init(testing.allocator, fields);
    defer index.deinit();

    try testing.expectEqual(@as(usize, 4), index.fields.len);
    try testing.expectEqual(@as(u16, 0), index.field_map.get("title").?);
    try testing.expectEqual(@as(u16, 1), index.field_map.get("price").?);
    try testing.expectEqual(@as(u16, 2), index.field_map.get("color").?);
    try testing.expectEqual(@as(u16, 3), index.field_map.get("v").?);
}

test "SearchIndex add document indexes all field types" {
    const fields = try make_fields();
    var index = SearchIndex.init(testing.allocator, fields);
    defer index.deinit();

    try index.add_document("doc1", &.{
        .{ .string = "the quick fox" },
        .{ .numeric = 9.99 },
        .{ .string = "red,blue" },
        .{ .string = vec_f32(&[_]f32{ 0, 0 }) },
    });
    try index.add_document("doc2", &.{
        .{ .string = "quick dog" },
        .{ .numeric = 25.0 },
        .{ .string = "green" },
        .{ .string = vec_f32(&[_]f32{ 10, 10 }) },
    });

    try testing.expectEqual(@as(u64, 2), index.doc_count());

    const ii = index.get_inverted(0).?;
    try testing.expectEqual(@as(usize, 2), ii.postings("quick").?.len);

    const ni = index.get_numeric(1).?;
    var range: std.ArrayListUnmanaged(u64) = .empty;
    defer range.deinit(testing.allocator);
    try ni.range(10.0, 50.0, &range);
    try testing.expectEqual(@as(usize, 1), range.items.len);

    const ti = index.get_tag(2).?;
    try testing.expect(ti.doc_ids("red").?.contains(index.docs.get("doc1").?.internal_id));

    const vi = index.get_vector(3).?;
    try testing.expectEqual(@as(usize, 2), vi.count());
}

test "SearchIndex remove document de-indexes" {
    const fields = try make_fields();
    var index = SearchIndex.init(testing.allocator, fields);
    defer index.deinit();

    try index.add_document("doc1", &.{
        .{ .string = "alpha beta" },
        .{ .numeric = 1.0 },
        .{ .string = "red" },
        .{ .string = vec_f32(&[_]f32{ 1, 1 }) },
    });

    try testing.expect(index.remove_document("doc1"));
    try testing.expect(!index.remove_document("doc1"));
    try testing.expectEqual(@as(u64, 0), index.doc_count());

    const ii = index.get_inverted(0).?;
    try testing.expectEqual(@as(u32, 0), ii.doc_freq("alpha"));
    try testing.expectEqual(@as(usize, 0), index.get_vector(3).?.count());
}

test "SearchIndex add_document rejects duplicates" {
    const fields = try make_fields();
    var index = SearchIndex.init(testing.allocator, fields);
    defer index.deinit();

    try index.add_document("doc1", &.{ .{ .string = "a" }, null, null, null });
    try testing.expectError(error.DocumentExists, index.add_document("doc1", &.{
        .{ .string = "b" },
        null,
        null,
        null,
    }));
}
