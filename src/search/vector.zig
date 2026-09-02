const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const VectorType = enum {
    float32,
    float64,

    pub fn from_slice(s: []const u8) ?VectorType {
        if (std.ascii.eqlIgnoreCase(s, "FLOAT32")) return .float32;
        if (std.ascii.eqlIgnoreCase(s, "FLOAT64")) return .float64;
        return null;
    }

    pub fn elem_size(self: VectorType) usize {
        return switch (self) {
            .float32 => 4,
            .float64 => 8,
        };
    }
};

pub const DistanceMetric = enum {
    l2,
    ip,
    cosine,

    pub fn from_slice(s: []const u8) ?DistanceMetric {
        if (std.ascii.eqlIgnoreCase(s, "L2")) return .l2;
        if (std.ascii.eqlIgnoreCase(s, "IP")) return .ip;
        if (std.ascii.eqlIgnoreCase(s, "COSINE")) return .cosine;
        return null;
    }
};

pub const VectorParams = struct {
    dim: u16,
    typ: VectorType,
    metric: DistanceMetric,
};

pub const VecEntry = struct {
    doc_id: u64,
    data: []u8, // owned raw little-endian blob
};

/// FLAT (exact) vector index: stores vectors in insertion order and computes
/// distances to every entry on search. O(N*D) exact KNN.
pub const VectorIndex = struct {
    allocator: Allocator,
    params: VectorParams,
    entries: std.ArrayListUnmanaged(VecEntry) = .empty,

    pub fn init(allocator: Allocator, params: VectorParams) VectorIndex {
        return .{ .allocator = allocator, .params = params };
    }

    pub fn deinit(self: *VectorIndex) void {
        for (self.entries.items) |e| self.allocator.free(e.data);
        self.entries.deinit(self.allocator);
    }

    pub fn count(self: *const VectorIndex) usize {
        return self.entries.items.len;
    }

    pub fn add(self: *VectorIndex, doc_id: u64, blob: []const u8) !void {
        if (blob.len != @as(usize, self.params.dim) * self.params.typ.elem_size()) {
            return error.VectorDimensionMismatch;
        }
        const owned = try self.allocator.dupe(u8, blob);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, .{ .doc_id = doc_id, .data = owned });
    }

    pub fn remove(self: *VectorIndex, doc_id: u64) void {
        for (self.entries.items, 0..) |e, i| {
            if (e.doc_id == doc_id) {
                self.allocator.free(e.data);
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    /// Higher = more similar. L2 is negated so all metrics share "maximize".
    pub fn similarity(self: *const VectorIndex, a: []const u8, b: []const u8) f64 {
        const dim: usize = self.params.dim;
        switch (self.params.typ) {
            .float32 => return similarity_for(f32, self.params.metric, a, b, dim),
            .float64 => return similarity_for(f64, self.params.metric, a, b, dim),
        }
    }

    /// Returns the k nearest entries (sorted best-first) with their scores.
    pub fn knn(self: *const VectorIndex, query: []const u8, k: usize) !std.ArrayListUnmanaged(KnnResult) {
        var results: std.ArrayListUnmanaged(KnnResult) = .empty;
        errdefer results.deinit(self.allocator);

        for (self.entries.items) |e| {
            const sim = self.similarity(query, e.data);
            try results.append(self.allocator, .{ .doc_id = e.doc_id, .score = sim });
        }

        std.mem.sort(KnnResult, results.items, {}, struct {
            fn lt(_: void, a: KnnResult, b: KnnResult) bool {
                return a.score > b.score;
            }
        }.lt);

        if (results.items.len > k) results.shrinkRetainingCapacity(k);
        return results;
    }

    /// KNN restricted to doc ids present in `candidates`. Returns top-k sorted
    /// best-first with their scores.
    pub fn knn_filtered(
        self: *const VectorIndex,
        query: []const u8,
        k: usize,
        candidates: *const std.AutoHashMapUnmanaged(u64, void),
    ) !std.ArrayListUnmanaged(KnnResult) {
        var results: std.ArrayListUnmanaged(KnnResult) = .empty;
        errdefer results.deinit(self.allocator);

        for (self.entries.items) |e| {
            if (!candidates.contains(e.doc_id)) continue;
            const sim = self.similarity(query, e.data);
            try results.append(self.allocator, .{ .doc_id = e.doc_id, .score = sim });
        }

        std.mem.sort(KnnResult, results.items, {}, struct {
            fn lt(_: void, a: KnnResult, b: KnnResult) bool {
                return a.score > b.score;
            }
        }.lt);

        if (results.items.len > k) results.shrinkRetainingCapacity(k);
        return results;
    }
};

pub const KnnResult = struct {
    doc_id: u64,
    score: f64,
};

inline fn read_float(comptime T: type, blob: []const u8, i: usize) T {
    var tmp: [@sizeOf(T)]u8 align(@alignOf(T)) = undefined;
    @memcpy(tmp[0..], blob[i * @sizeOf(T) ..][0..@sizeOf(T)]);
    return std.mem.bytesToValue(T, &tmp);
}

/// Native SIMD block size, in elements of `T`, for the compile-target CPU
/// (e.g. 4 on aarch64/SSE2 for f32, 8 with AVX2, 16 with AVX-512).
fn vec_len(comptime T: type) comptime_int {
    return std.simd.suggestVectorLength(T) orelse 4;
}

/// Loads vec_len(T) floats (unaligned byte blob) into a vector.
inline fn load_vec(comptime T: type, blob: []const u8, offset: usize) @Vector(vec_len(T), T) {
    const len = comptime vec_len(T);
    const bytes = blob[offset * @sizeOf(T) ..][0 .. len * @sizeOf(T)];
    var buf: [len * @sizeOf(T)]u8 align(@alignOf(T)) = undefined;
    @memcpy(buf[0..], bytes);
    return @bitCast(buf);
}

fn dot(comptime T: type, a: []const u8, b: []const u8, dim: usize) f64 {
    const len = comptime vec_len(T);
    var total: f64 = 0;
    var i: usize = 0;
    while (i + len <= dim) : (i += len) {
        const av = load_vec(T, a, i);
        const bv = load_vec(T, b, i);
        total += @as(f64, @floatCast(@reduce(.Add, av * bv)));
    }
    while (i < dim) : (i += 1) {
        total += @as(f64, @floatCast(read_float(T, a, i))) * @as(f64, @floatCast(read_float(T, b, i)));
    }
    return total;
}

fn norm(comptime T: type, a: []const u8, dim: usize) f64 {
    const len = comptime vec_len(T);
    var total: f64 = 0;
    var i: usize = 0;
    while (i + len <= dim) : (i += len) {
        const av = load_vec(T, a, i);
        total += @as(f64, @floatCast(@reduce(.Add, av * av)));
    }
    while (i < dim) : (i += 1) {
        const av = read_float(T, a, i);
        total += @as(f64, @floatCast(av)) * @as(f64, @floatCast(av));
    }
    return @sqrt(total);
}

fn l2_sq(comptime T: type, a: []const u8, b: []const u8, dim: usize) f64 {
    const len = comptime vec_len(T);
    var total: f64 = 0;
    var i: usize = 0;
    while (i + len <= dim) : (i += len) {
        const av = load_vec(T, a, i);
        const bv = load_vec(T, b, i);
        const diff = av - bv;
        total += @as(f64, @floatCast(@reduce(.Add, diff * diff)));
    }
    while (i < dim) : (i += 1) {
        const av = read_float(T, a, i);
        const bv = read_float(T, b, i);
        const d = @as(f64, @floatCast(av - bv));
        total += d * d;
    }
    return total;
}

fn similarity_for(comptime T: type, metric: DistanceMetric, a: []const u8, b: []const u8, dim: usize) f64 {
    switch (metric) {
        .l2 => return -l2_sq(T, a, b, dim),
        .ip => return dot(T, a, b, dim),
        .cosine => {
            const d = dot(T, a, b, dim);
            const na = norm(T, a, dim);
            const nb = norm(T, b, dim);
            if (na == 0 or nb == 0) return 0;
            return d / (na * nb);
        },
    }
}

const testing = std.testing;

fn vec_f32(values: []const f32) []const u8 {
    return std.mem.sliceAsBytes(values);
}

test "vector l2 similarity negates distance" {
    var vi = VectorIndex.init(testing.allocator, .{
        .dim = 2,
        .typ = .float32,
        .metric = .l2,
    });
    defer vi.deinit();

    try vi.add(1, vec_f32(&[_]f32{ 1, 1 }));
    try vi.add(2, vec_f32(&[_]f32{ 0, 0 }));

    const query = vec_f32(&[_]f32{ 1, 1 });
    const s1 = vi.similarity(query, vi.entries.items[0].data);
    const s2 = vi.similarity(query, vi.entries.items[1].data);
    try testing.expect(s1 > s2); // identical vector scores highest
}

test "vector knn returns nearest first" {
    var vi = VectorIndex.init(testing.allocator, .{
        .dim = 2,
        .typ = .float32,
        .metric = .l2,
    });
    defer vi.deinit();

    try vi.add(1, vec_f32(&[_]f32{ 0, 0 }));
    try vi.add(2, vec_f32(&[_]f32{ 10, 10 }));
    try vi.add(3, vec_f32(&[_]f32{ 1, 1 }));

    const query = vec_f32(&[_]f32{ 1, 1 });
    var results = try vi.knn(query, 2);
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), results.items.len);
    try testing.expectEqual(@as(u64, 3), results.items[0].doc_id); // closest
    try testing.expectEqual(@as(u64, 1), results.items[1].doc_id);
}

test "vector rejects wrong blob length" {
    var vi = VectorIndex.init(testing.allocator, .{
        .dim = 2,
        .typ = .float32,
        .metric = .l2,
    });
    defer vi.deinit();

    try testing.expectError(error.VectorDimensionMismatch, vi.add(1, vec_f32(&[_]f32{1})));
}

test "vector remove" {
    var vi = VectorIndex.init(testing.allocator, .{
        .dim = 1,
        .typ = .float32,
        .metric = .l2,
    });
    defer vi.deinit();

    try vi.add(1, vec_f32(&[_]f32{1}));
    try vi.add(2, vec_f32(&[_]f32{2}));
    vi.remove(1);
    try testing.expectEqual(@as(usize, 1), vi.count());
    try testing.expectEqual(@as(u64, 2), vi.entries.items[0].doc_id);
}
