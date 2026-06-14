const std = @import("std");
const gorilla = @import("./compression/gorilla.zig");
const BitStream = gorilla.BitStream;
const TimestampCompressor = gorilla.TimestampCompressor;
const ValueCompressor = gorilla.ValueCompressor;
const ChunkCompressor = gorilla.ChunkCompressor;
const ChunkDecompressor = gorilla.ChunkDecompressor;
const ValueDecompressor = gorilla.ValueDecompressor;

const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const eql = std.mem.eql;

const Store = @import("store.zig").Store;
const Value = @import("parser.zig").Value;

const Sample = struct {
    timestamp: i64,
    value: f64,
};

pub const AggregationType = enum {
    AVG,
    SUM,
    MIN,
    MAX,
    RANGE,
    COUNT,
    FIRST,
    LAST,
    STD_P,
    STD_S,
    VAR_P,
    VAR_S,

    pub fn fromString(s: []const u8) !AggregationType {
        if (eqlIgnoreCase(s, "AVG")) return .AVG;
        if (eqlIgnoreCase(s, "SUM")) return .SUM;
        if (eqlIgnoreCase(s, "MIN")) return .MIN;
        if (eqlIgnoreCase(s, "MAX")) return .MAX;
        if (eqlIgnoreCase(s, "COUNT")) return .COUNT;
        if (eqlIgnoreCase(s, "RANGE")) return .RANGE;
        if (eqlIgnoreCase(s, "FIRST")) return .FIRST;
        if (eqlIgnoreCase(s, "LAST")) return .LAST;
        if (eqlIgnoreCase(s, "STD.P")) return .STD_P;
        if (eqlIgnoreCase(s, "STD.S")) return .STD_S;
        if (eqlIgnoreCase(s, "VAR.P")) return .VAR_P;
        if (eqlIgnoreCase(s, "VAR.S")) return .VAR_S;
        return error.SyntaxError;
    }
};

pub const Aggregation = struct {
    agg_type: AggregationType,
    time_bucket: u64,
};

pub const Duplicate_Policy = enum {
    BLOCK,
    FIRST,
    LAST,
    MIN,
    MAX,
    SUM,

    pub fn fromString(s: []const u8) ?Duplicate_Policy {
        if (eqlIgnoreCase(s, "BLOCK")) return .BLOCK;
        if (eqlIgnoreCase(s, "FIRST")) return .FIRST;
        if (eqlIgnoreCase(s, "LAST")) return .LAST;
        if (eqlIgnoreCase(s, "MIN")) return .MIN;
        if (eqlIgnoreCase(s, "MAX")) return .MAX;
        if (eqlIgnoreCase(s, "SUM")) return .SUM;
        return null;
    }
};

pub const EncodingType = enum(u8) {
    Uncompressed,
    DeltaXor,

    pub fn fromString(s: []const u8) ?EncodingType {
        if (eqlIgnoreCase(s, "UNCOMPRESSED")) return .Uncompressed;
        if (eqlIgnoreCase(s, "COMPRESSED")) return .DeltaXor;
        return null;
    }
};

const Chunk = struct {
    prev: ?*Chunk,
    next: ?*Chunk,
    first_ts: i64,
    last_ts: i64,
    sample_count: u16,
    encoding: EncodingType,
    // The data is now a slice of the final compressed bytes
    data: []u8,
};

pub const TimeSeries = struct {
    head: ?*Chunk,
    tail: ?*Chunk,

    total_samples: u64,
    retention_ms: u64,
    allocator: std.mem.Allocator,
    duplicate_policy: Duplicate_Policy,
    max_chunk_samples: u16,
    encoding: EncodingType,
    ignore_max_time_diff: u64,
    ignore_max_val_diff: f64,

    // Active chunk samples - always kept uncompressed for real-time queries
    // Compression (based on encoding setting) only applies when sealing chunks
    // Boxed to reduce TimeSeries size
    active_samples: *std.ArrayList(Sample),

    // Track last value for duplicate/IGNORE logic
    // Boxed to reduce TimeSeries size
    last_sample: ?*Sample = null,

    pub fn init(
        allocator: std.mem.Allocator,
        retention_ms: u64,
        duplicate_policy: ?Duplicate_Policy,
        max_chunk_samples: u16,
        encoding: ?EncodingType,
        ignore_max_time_diff: ?u64,
        ignore_max_val_diff: ?f64,
    ) !TimeSeries {
        const active_samples_ptr = try allocator.create(std.ArrayList(Sample));
        active_samples_ptr.* = .empty;

        return TimeSeries{
            .head = null,
            .tail = null,
            .total_samples = 0,
            .retention_ms = retention_ms,
            .allocator = allocator,
            .duplicate_policy = duplicate_policy orelse .BLOCK,
            .max_chunk_samples = max_chunk_samples,
            .encoding = encoding orelse .DeltaXor,
            .ignore_max_time_diff = ignore_max_time_diff orelse 0,
            .ignore_max_val_diff = ignore_max_val_diff orelse 0.0,
            .active_samples = active_samples_ptr,
        };
    }

    pub fn deinit(self: *TimeSeries) void {
        // Deinit the active samples buffer
        self.active_samples.deinit(self.allocator);
        self.allocator.destroy(self.active_samples);

        // Free last_sample if present
        if (self.last_sample) |sample_ptr| {
            self.allocator.destroy(sample_ptr);
        }

        var chunk = self.head;
        while (chunk) |c| {
            const next = c.next;
            // Free the chunk's data
            if (c.data.len > 0) {
                self.allocator.free(c.data);
            }
            // Free the chunk itself
            self.allocator.destroy(c);
            chunk = next;
        }
    }

    pub fn evictExpiredChunks(self: *TimeSeries, current_timestamp: i64) void {
        // If retention is 0, no eviction
        if (self.retention_ms == 0) return;

        const retention_cutoff = current_timestamp - @as(i64, @intCast(self.retention_ms));

        // Walk from head and remove chunks older than retention window
        var chunk = self.head;
        while (chunk) |c| {
            // If chunk's last timestamp is within retention window, stop
            if (c.last_ts >= retention_cutoff) break;

            const next = c.next;

            // Free chunk data
            if (c.data.len > 0) {
                self.allocator.free(c.data);
            }

            // Free chunk itself
            self.allocator.destroy(c);

            // Move head forward
            self.head = next;
            if (next) |n| {
                n.prev = null;
            } else {
                // No more chunks, clear tail too
                self.tail = null;
            }

            chunk = next;
        }
    }

    fn sealCurrentChunk(self: *TimeSeries) !void {
        if (self.tail) |tail_chunk| {
            // Seal by compressing active_samples based on encoding type
            const samples = self.active_samples.items;

            switch (self.encoding) {
                .DeltaXor => {
                    // Compress using Gorilla compression
                    var compressor = ChunkCompressor.init(self.allocator);
                    defer compressor.deinit();

                    for (samples) |sample| {
                        try compressor.add(sample.timestamp, sample.value);
                    }

                    // Transfer ownership of compressed data to chunk
                    tail_chunk.data = try compressor.stream.buffer.toOwnedSlice(self.allocator);
                },
                .Uncompressed => {
                    // Store samples in binary format (16 bytes per sample)
                    const byte_size = samples.len * 16;
                    tail_chunk.data = try self.allocator.alloc(u8, byte_size);

                    for (samples, 0..) |sample, i| {
                        const offset = i * 16;
                        std.mem.writeInt(i64, tail_chunk.data[offset..][0..8], sample.timestamp, .little);
                        const value_bits: u64 = @bitCast(sample.value);
                        std.mem.writeInt(u64, tail_chunk.data[offset + 8 ..][0..8], value_bits, .little);
                    }
                },
            }

            // Clear active samples for next chunk
            self.active_samples.clearRetainingCapacity();
        }
    }

    /// Check if sample should be handled based on duplicate policy
    /// Returns true if sample should be skipped
    fn handleDuplicatePolicy(self: *TimeSeries, timestamp: i64, value: f64) !bool {
        if (self.tail) |tail| {
            if (timestamp == tail.last_ts) {
                switch (self.duplicate_policy) {
                    .BLOCK => return error.TSDB_DuplicateTimestamp,
                    .FIRST => return true, // Skip new value, keep original
                    .LAST => return false, // Will update the sample
                    .MIN => {
                        if (self.last_sample) |last_sample| {
                            if (value >= last_sample.value) return true; // Skip, keep min
                        }
                        return false;
                    },
                    .MAX => {
                        if (self.last_sample) |last_sample| {
                            if (value <= last_sample.value) return true; // Skip, keep max
                        }
                        return false;
                    },
                    .SUM => {
                        if (self.last_sample) |last_sample| {
                            // For SUM, we need to update the value
                            _ = last_sample.value + value;
                            // TODO: Need to modify last sample
                            return true; // For now, skip
                        }
                        return false;
                    },
                }
            }
        }
        return false;
    }

    /// Check if sample should be ignored based on IGNORE parameters
    /// Returns true if sample should be ignored
    fn shouldIgnoreSample(self: *TimeSeries, timestamp: i64, value: f64) bool {
        // IGNORE only applies to LAST policy and in-order samples
        if (self.duplicate_policy != .LAST) return false;

        if (self.tail) |tail| {
            if (timestamp >= tail.last_ts) {
                if (self.last_sample) |last_sample| {
                    const time_diff = timestamp - tail.last_ts;
                    const val_diff = @abs(value - last_sample.value);

                    if (time_diff <= self.ignore_max_time_diff and val_diff <= self.ignore_max_val_diff) {
                        return true; // Ignore this sample
                    }
                }
            }
        }
        return false;
    }

    /// Create a new chunk and initialize storage
    fn createNewChunk(self: *TimeSeries, timestamp: i64) !void {
        // Finalize the previous chunk before creating a new one
        try self.sealCurrentChunk();

        // Create new chunk header
        const new_chunk = try self.allocator.create(Chunk);
        new_chunk.* = Chunk{
            .prev = self.tail,
            .next = null,
            .first_ts = timestamp,
            .last_ts = timestamp,
            .sample_count = 0,
            .encoding = self.encoding,
            .data = &[_]u8{}, // Starts empty
        };

        // Link chunk to list
        if (self.tail) |old_tail| {
            old_tail.next = new_chunk;
        } else {
            self.head = new_chunk;
        }
        self.tail = new_chunk;

        // active_samples is always ready - no per-encoding initialization needed
        // Compression happens only during sealing based on encoding type
    }

    /// Append sample to active chunk (always stored uncompressed)
    fn appendToChunk(self: *TimeSeries, timestamp: i64, value: f64) !void {
        try self.active_samples.append(self.allocator, .{
            .timestamp = timestamp,
            .value = value,
        });
    }

    pub fn addSample(self: *TimeSeries, timestamp: i64, value: f64) !void {
        // Check duplicate policy - returns true if sample should be skipped
        if (try self.handleDuplicatePolicy(timestamp, value)) return;

        // Check IGNORE filtering - returns true if sample should be ignored
        if (self.shouldIgnoreSample(timestamp, value)) return;

        // Create new chunk if needed (no tail or current chunk is full)
        if (self.tail == null or self.tail.?.sample_count >= self.max_chunk_samples) {
            try self.createNewChunk(timestamp);
        }

        // Append sample to current chunk storage
        try self.appendToChunk(timestamp, value);

        // Update chunk and series metadata
        const tail = self.tail.?;
        tail.last_ts = timestamp;
        tail.sample_count += 1;
        self.total_samples += 1;

        // Track last sample for duplicate/IGNORE logic
        if (self.last_sample) |sample_ptr| {
            // Reuse existing allocation
            sample_ptr.* = .{ .timestamp = timestamp, .value = value };
        } else {
            // Allocate new sample
            const sample_ptr = try self.allocator.create(Sample);
            sample_ptr.* = .{ .timestamp = timestamp, .value = value };
            self.last_sample = sample_ptr;
        }

        // Apply retention policy - evict chunks outside retention window
        self.evictExpiredChunks(timestamp);
    }

    /// Get the last value in the time series, or 0.0 if empty
    pub fn getLastValue(self: *const TimeSeries) f64 {
        if (self.last_sample) |sample| {
            return sample.value;
        }
        return 0.0;
    }

    pub fn range(self: *const TimeSeries, start: []const u8, end: []const u8, count: ?usize, aggregation: ?Aggregation) !std.ArrayList(Sample) {
        // start and end can be special values: "-" for negative infinity, "+" for positive infinity
        const start_ts: i64 = if (eql(u8, start, "-")) std.math.minInt(i64) else try std.fmt.parseInt(i64, start, 10);
        const end_ts: i64 = if (eql(u8, end, "+")) std.math.maxInt(i64) else try std.fmt.parseInt(i64, end, 10);

        var samples: std.ArrayList(Sample) = .empty;
        errdefer samples.deinit(self.allocator);

        // Early return if count is 0
        if (count) |limit| {
            if (limit == 0) return samples;
        }

        var chunk = self.head;
        while (chunk) |c| {
            // If chunk is completely before the range, skip
            if (c.last_ts < start_ts) {
                chunk = c.next;
                continue;
            }
            if (c.first_ts > end_ts) break;

            // Decompress/deserialize chunk based on encoding
            var chunk_samples = try self.decompressChunk(c);
            defer chunk_samples.deinit(self.allocator);

            // Add chunk samples to the result
            for (chunk_samples.items) |sample| {
                if (sample.timestamp >= start_ts and sample.timestamp <= end_ts) {
                    try samples.append(self.allocator, sample);

                    // Check if we've reached the count limit (only if no aggregation)
                    if (aggregation == null) {
                        if (count) |limit| {
                            if (samples.items.len >= limit) {
                                return samples;
                            }
                        }
                    }
                }
            }

            chunk = c.next;
        }

        // Apply aggregation if specified
        if (aggregation) |agg| {
            return try self.applyAggregation(samples, agg, count);
        }

        return samples;
    }

    fn applyAggregation(self: TimeSeries, mut_samples: std.ArrayList(Sample), aggregation: Aggregation, count: ?usize) !std.ArrayList(Sample) {
        var samples = mut_samples;
        var aggregated: std.ArrayList(Sample) = .empty;
        errdefer aggregated.deinit(self.allocator);
        if (samples.items.len == 0) return aggregated;

        // Group samples into time buckets
        const bucket_size = @as(i64, @intCast(aggregation.time_bucket));
        var current_bucket: ?i64 = null;
        var bucket_samples: std.ArrayList(f64) = .empty;
        defer bucket_samples.deinit(self.allocator);

        for (samples.items) |sample| {
            const bucket_ts = @divFloor(sample.timestamp, bucket_size) * bucket_size;

            // If we're in a new bucket, process the previous one
            if (current_bucket) |prev_bucket| {
                if (bucket_ts != prev_bucket) {
                    // Compute aggregation for previous bucket
                    if (bucket_samples.items.len > 0) {
                        const agg_value = try computeAggregation(bucket_samples.items, aggregation.agg_type);
                        try aggregated.append(self.allocator, .{
                            .timestamp = prev_bucket,
                            .value = agg_value,
                        });

                        // Check count limit
                        if (count) |limit| {
                            if (aggregated.items.len >= limit) {
                                // Clean up original samples before returning
                                samples.deinit(self.allocator);
                                return aggregated;
                            }
                        }
                    }
                    bucket_samples.clearRetainingCapacity();
                }
            }

            current_bucket = bucket_ts;
            try bucket_samples.append(self.allocator, sample.value);
        }

        // Process the last bucket
        if (current_bucket != null and bucket_samples.items.len > 0) {
            const agg_value = try computeAggregation(bucket_samples.items, aggregation.agg_type);
            try aggregated.append(self.allocator, .{
                .timestamp = current_bucket.?,
                .value = agg_value,
            });
        }

        // Clean up original samples
        samples.deinit(self.allocator);

        return aggregated;
    }

    /// Compute aggregation value for a set of values
    fn computeAggregation(values: []const f64, agg_type: AggregationType) !f64 {
        if (values.len == 0) return 0.0;

        switch (agg_type) {
            .AVG => {
                var sum: f64 = 0.0;
                for (values) |v| sum += v;
                return sum / @as(f64, @floatFromInt(values.len));
            },
            .SUM => {
                var sum: f64 = 0.0;
                for (values) |v| sum += v;
                return sum;
            },
            .MIN => {
                var min = values[0];
                for (values[1..]) |v| {
                    if (v < min) min = v;
                }
                return min;
            },
            .MAX => {
                var max = values[0];
                for (values[1..]) |v| {
                    if (v > max) max = v;
                }
                return max;
            },
            .RANGE => {
                var min = values[0];
                var max = values[0];
                for (values[1..]) |v| {
                    if (v < min) min = v;
                    if (v > max) max = v;
                }
                return max - min;
            },
            .COUNT => {
                return @floatFromInt(values.len);
            },
            .FIRST => {
                return values[0];
            },
            .LAST => {
                return values[values.len - 1];
            },
            .STD_P => {
                // Population standard deviation
                const mean = blk: {
                    var sum: f64 = 0.0;
                    for (values) |v| sum += v;
                    break :blk sum / @as(f64, @floatFromInt(values.len));
                };
                var variance: f64 = 0.0;
                for (values) |v| {
                    const diff = v - mean;
                    variance += diff * diff;
                }
                variance /= @as(f64, @floatFromInt(values.len));
                return @sqrt(variance);
            },
            .STD_S => {
                // Sample standard deviation
                if (values.len <= 1) return 0.0;
                const mean = blk: {
                    var sum: f64 = 0.0;
                    for (values) |v| sum += v;
                    break :blk sum / @as(f64, @floatFromInt(values.len));
                };
                var variance: f64 = 0.0;
                for (values) |v| {
                    const diff = v - mean;
                    variance += diff * diff;
                }
                variance /= @as(f64, @floatFromInt(values.len - 1));
                return @sqrt(variance);
            },
            .VAR_P => {
                // Population variance
                const mean = blk: {
                    var sum: f64 = 0.0;
                    for (values) |v| sum += v;
                    break :blk sum / @as(f64, @floatFromInt(values.len));
                };
                var variance: f64 = 0.0;
                for (values) |v| {
                    const diff = v - mean;
                    variance += diff * diff;
                }
                return variance / @as(f64, @floatFromInt(values.len));
            },
            .VAR_S => {
                // Sample variance
                if (values.len <= 1) return 0.0;
                const mean = blk: {
                    var sum: f64 = 0.0;
                    for (values) |v| sum += v;
                    break :blk sum / @as(f64, @floatFromInt(values.len));
                };
                var variance: f64 = 0.0;
                for (values) |v| {
                    const diff = v - mean;
                    variance += diff * diff;
                }
                return variance / @as(f64, @floatFromInt(values.len - 1));
            },
        }
    }

    fn decompressChunk(self: *const TimeSeries, chunk: *const Chunk) !std.ArrayList(Sample) {
        var samples: std.ArrayList(Sample) = .empty;
        errdefer samples.deinit(self.allocator);

        // Check if this is the active tail chunk with unsealed data
        const is_active_tail = chunk == self.tail and chunk.data.len == 0;

        if (is_active_tail) {
            // Active chunk: always read from uncompressed active_samples buffer
            // This works for both DeltaXor and Uncompressed encodings because
            // compression only happens during sealing
            for (self.active_samples.items) |sample| {
                try samples.append(self.allocator, sample);
            }
        } else {
            // Read from sealed chunk data
            switch (chunk.encoding) {
                .DeltaXor => {
                    // Use Gorilla decompressor (zero-copy, no allocation)
                    var decompressor = ChunkDecompressor.init(chunk.data);
                    defer decompressor.deinit();

                    // Iterate based on sample count
                    for (0..chunk.sample_count) |_| {
                        const sample = try decompressor.next();
                        try samples.append(self.allocator, .{
                            .timestamp = sample.timestamp,
                            .value = sample.value,
                        });
                    }
                },
                .Uncompressed => {
                    // Deserialize binary format (16 bytes per sample)
                    const num_samples = chunk.data.len / 16;
                    for (0..num_samples) |i| {
                        const offset = i * 16;
                        const timestamp = std.mem.readInt(i64, chunk.data[offset..][0..8], .little);
                        const value_bits = std.mem.readInt(u64, chunk.data[offset + 8 ..][0..8], .little);
                        const value: f64 = @bitCast(value_bits);
                        try samples.append(self.allocator, .{ .timestamp = timestamp, .value = value });
                    }
                },
            }
        }

        return samples;
    }

    /// Alter time series properties
    pub fn alter(
        self: *TimeSeries,
        retention_ms: ?u64,
        duplicate_policy: ?Duplicate_Policy,
        chunk_size: ?u16,
    ) void {
        if (retention_ms) |r| self.retention_ms = r;
        if (duplicate_policy) |dp| self.duplicate_policy = dp;
        if (chunk_size) |cs| self.max_chunk_samples = cs;
    }
};

test "TimeSeries: basic uncompressed storage" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0, // no retention
        .BLOCK,
        100, // max samples per chunk
        .Uncompressed,
        0, // no ignore time diff
        0.0, // no ignore val diff
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.5);
    try ts.addSample(1001, 20.5);
    try ts.addSample(1002, 30.5);

    try testing.expectEqual(@as(u64, 3), ts.total_samples);
    try testing.expect(ts.tail != null);
    try testing.expectEqual(@as(i64, 1002), ts.tail.?.last_ts);
}

test "TimeSeries: basic compressed storage" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .DeltaXor,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 100.0);
    try ts.addSample(1010, 105.0);
    try ts.addSample(1020, 110.0);

    try testing.expectEqual(@as(u64, 3), ts.total_samples);
}

test "TimeSeries: duplicate policy BLOCK" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);

    // Duplicate timestamp should return error
    const result = ts.addSample(1000, 20.0);
    try testing.expectError(error.TSDB_DuplicateTimestamp, result);
}

test "TimeSeries: duplicate policy FIRST" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .FIRST,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(1000, 20.0); // Should be ignored

    try testing.expectEqual(@as(u64, 1), ts.total_samples);
    try testing.expectEqual(@as(f64, 10.0), ts.last_sample.?.value);
}

test "TimeSeries: duplicate policy LAST" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .LAST,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(1000, 20.0); // Should update

    try testing.expectEqual(@as(u64, 2), ts.total_samples);
    try testing.expectEqual(@as(f64, 20.0), ts.last_sample.?.value);
}

test "TimeSeries: duplicate policy MIN" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .MIN,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(1000, 20.0); // Should be ignored (10 < 20)

    try testing.expectEqual(@as(f64, 10.0), ts.last_sample.?.value);

    try ts.addSample(1001, 30.0);
    try ts.addSample(1001, 5.0); // Should be kept (5 < 30)

    try testing.expectEqual(@as(f64, 5.0), ts.last_sample.?.value);
}

test "TimeSeries: duplicate policy MAX" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .MAX,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(1000, 20.0); // Should be kept (20 > 10)

    try testing.expectEqual(@as(f64, 20.0), ts.last_sample.?.value);

    try ts.addSample(1001, 30.0);
    try ts.addSample(1001, 15.0); // Should be ignored (15 < 30)

    try testing.expectEqual(@as(f64, 30.0), ts.last_sample.?.value);
}

test "TimeSeries: IGNORE parameter filters samples" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .LAST, // IGNORE only works with LAST policy
        100,
        .Uncompressed,
        1000, // ignore_max_time_diff = 1000ms
        5.0, // ignore_max_val_diff = 5.0
    );
    defer ts.deinit();

    try ts.addSample(1000, 100.0);

    // Time diff = 500ms, val diff = 2.0 - both within threshold, should be ignored
    try ts.addSample(1500, 102.0);
    try testing.expectEqual(@as(u64, 1), ts.total_samples);

    // Time diff = 2000ms - exceeds threshold, should be added
    try ts.addSample(3000, 102.0);
    try testing.expectEqual(@as(u64, 2), ts.total_samples);

    // Time diff = 500ms, val diff = 10.0 - val exceeds threshold, should be added
    try ts.addSample(3500, 112.0);
    try testing.expectEqual(@as(u64, 3), ts.total_samples);
}

test "TimeSeries: IGNORE does not apply to non-LAST policies" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK, // Not LAST policy
        100,
        .Uncompressed,
        1000,
        5.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 100.0);

    // Even though within IGNORE thresholds, should be added (BLOCK policy)
    try ts.addSample(1500, 102.0);
    try testing.expectEqual(@as(u64, 2), ts.total_samples);
}

test "TimeSeries: retention policy evicts old chunks" {
    var ts = try TimeSeries.init(
        testing.allocator,
        5000, // 5 second retention
        .BLOCK,
        2, // 2 samples per chunk - forces multiple chunks
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Add samples that will create multiple chunks
    try ts.addSample(1000, 10.0);
    try ts.addSample(2000, 20.0);
    try testing.expectEqual(@as(u64, 2), ts.total_samples);

    // New chunk
    try ts.addSample(3000, 30.0);
    try ts.addSample(4000, 40.0);
    try testing.expectEqual(@as(u64, 4), ts.total_samples);

    // New chunk
    try ts.addSample(5000, 50.0);
    try ts.addSample(6000, 60.0);
    try testing.expectEqual(@as(u64, 6), ts.total_samples);

    // Add sample at 10000ms - retention window is [5000, 10000]
    // First chunk (1000-2000) should be evicted
    try ts.addSample(10000, 100.0);

    // Should still have samples from chunks 2 and 3
    try testing.expect(ts.head != null);
    try testing.expect(ts.head.?.first_ts >= 3000);
}

test "TimeSeries: retention policy with zero retention" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0, // No retention - keep all data
        .BLOCK,
        2,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(2000, 20.0);
    try ts.addSample(3000, 30.0);
    try ts.addSample(100000, 100.0); // Much later timestamp

    // All samples should be retained
    try testing.expectEqual(@as(u64, 4), ts.total_samples);
    try testing.expect(ts.head != null);
    try testing.expectEqual(@as(i64, 1000), ts.head.?.first_ts);
}

test "TimeSeries: chunk sealing creates new chunk when full" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        3, // Only 3 samples per chunk
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(1001, 11.0);
    try ts.addSample(1002, 12.0);

    // First chunk should be full
    try testing.expect(ts.tail != null);
    try testing.expectEqual(@as(u16, 3), ts.tail.?.sample_count);

    // Adding another sample should create a new chunk
    try ts.addSample(1003, 13.0);

    try testing.expect(ts.tail != null);
    try testing.expectEqual(@as(u16, 1), ts.tail.?.sample_count);
    try testing.expect(ts.tail.?.prev != null);
}

test "TimeSeries: multiple chunks with retention" {
    var ts = try TimeSeries.init(
        testing.allocator,
        10000, // 10 second retention
        .BLOCK,
        2,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Create 5 chunks over time
    try ts.addSample(1000, 1.0);
    try ts.addSample(2000, 2.0);

    try ts.addSample(3000, 3.0);
    try ts.addSample(4000, 4.0);

    try ts.addSample(5000, 5.0);
    try ts.addSample(6000, 6.0);

    try ts.addSample(7000, 7.0);
    try ts.addSample(8000, 8.0);

    try ts.addSample(9000, 9.0);
    try ts.addSample(10000, 10.0);

    // All should still exist (within 10s window from 10000)
    try testing.expectEqual(@as(u64, 10), ts.total_samples);

    // Add sample at 15000 - retention window [5000, 15000]
    // First two chunks should be evicted
    try ts.addSample(15000, 15.0);

    try testing.expect(ts.head != null);
    try testing.expect(ts.head.?.first_ts >= 5000);
}

test "TimeSeries: out of order samples with LAST policy" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .LAST,
        10,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(2000, 20.0);

    // Out of order sample (IGNORE only applies to in-order)
    try ts.addSample(1500, 15.0);

    try testing.expectEqual(@as(u64, 3), ts.total_samples);
}

test "TimeSeries: edge case - empty time series retention" {
    var ts = try TimeSeries.init(
        testing.allocator,
        5000,
        .BLOCK,
        10,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Empty time series - eviction should be a no-op
    ts.evictExpiredChunks(10000);

    try testing.expect(ts.head == null);
    try testing.expect(ts.tail == null);
}

test "TimeSeries: all chunks evicted clears head and tail" {
    var ts = try TimeSeries.init(
        testing.allocator,
        1000, // 1 second retention
        .BLOCK,
        2,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(1500, 15.0);

    // Add sample way in the future - all old chunks should be evicted
    try ts.addSample(10000, 100.0);

    // Old chunk should be gone, only new chunk remains
    try testing.expect(ts.head != null);
    try testing.expect(ts.head == ts.tail);
    try testing.expectEqual(@as(i64, 10000), ts.head.?.first_ts);
}

test "TimeSeries: getLastValue returns last value" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        10,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Empty time series should return 0.0
    try testing.expectEqual(@as(f64, 0.0), ts.getLastValue());

    // Add samples
    try ts.addSample(1000, 10.0);
    try testing.expectEqual(@as(f64, 10.0), ts.getLastValue());

    try ts.addSample(2000, 20.5);
    try testing.expectEqual(@as(f64, 20.5), ts.getLastValue());
}

test "TimeSeries: alter updates properties" {
    var ts = try TimeSeries.init(
        testing.allocator,
        1000,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Alter retention
    ts.alter(5000, null, null);
    try testing.expectEqual(@as(u64, 5000), ts.retention_ms);

    // Alter duplicate policy
    ts.alter(null, .LAST, null);
    try testing.expectEqual(Duplicate_Policy.LAST, ts.duplicate_policy);

    // Alter chunk size
    ts.alter(null, null, 200);
    try testing.expectEqual(@as(u16, 200), ts.max_chunk_samples);

    // Alter multiple at once
    ts.alter(10000, .MIN, 50);
    try testing.expectEqual(@as(u64, 10000), ts.retention_ms);
    try testing.expectEqual(Duplicate_Policy.MIN, ts.duplicate_policy);
    try testing.expectEqual(@as(u16, 50), ts.max_chunk_samples);
}

// Command-level tests
const ts_commands = @import("commands/time_series.zig");

// Test aliases
const testing = std.testing;
const mem = std.mem;
const Clock = @import("clock.zig");
const Io = std.Io;
const Writer = Io.Writer;

test "TS.INCRBY increments from zero" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create time series
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
        .{ .data = "RETENTION" },
        .{ .data = "0" },
        .{ .data = "ENCODING" },
        .{ .data = "UNCOMPRESSED" },
        .{ .data = "DUPLICATE_POLICY" },
        .{ .data = "LAST" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    // Increment by 5.0 (should start from 0.0)
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const incrby_args = [_]Value{
        .{ .data = "TS.INCRBY" },
        .{ .data = "myts" },
        .{ .data = "1000" },
        .{ .data = "5.0" },
    };
    try ts_commands.ts_incrby(&writer, &store, &incrby_args);

    // Should return timestamp
    try testing.expectEqualStrings(":1000\r\n", writer.buffered());

    // Verify value is 5.0 (formatted as "5" in RESP)
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const get_args = [_]Value{
        .{ .data = "TS.GET" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_get(&writer, &store, &get_args);

    const output = writer.buffered();
    try testing.expect(mem.indexOf(u8, output, "$1\r\n5\r\n") != null or mem.indexOf(u8, output, "$3\r\n5.0\r\n") != null);
}

test "TS.INCRBY increments from existing value" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create and add initial value
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const add_args = [_]Value{
        .{ .data = "TS.ADD" },
        .{ .data = "myts" },
        .{ .data = "1000" },
        .{ .data = "10.0" },
    };
    try ts_commands.ts_add(&writer, &store, &add_args);

    // Increment by 3.0
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const incrby_args = [_]Value{
        .{ .data = "TS.INCRBY" },
        .{ .data = "myts" },
        .{ .data = "2000" },
        .{ .data = "3.0" },
    };
    try ts_commands.ts_incrby(&writer, &store, &incrby_args);

    // Verify value is 13.0 (formatted as "13" in RESP)
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const get_args = [_]Value{
        .{ .data = "TS.GET" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_get(&writer, &store, &get_args);

    const output = writer.buffered();
    try testing.expect(mem.indexOf(u8, output, "$2\r\n13\r\n") != null or mem.indexOf(u8, output, "$4\r\n13.0\r\n") != null);
}

test "TS.DECRBY decrements value" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create and add initial value
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const add_args = [_]Value{
        .{ .data = "TS.ADD" },
        .{ .data = "myts" },
        .{ .data = "1000" },
        .{ .data = "20.0" },
    };
    try ts_commands.ts_add(&writer, &store, &add_args);

    // Decrement by 7.0
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const decrby_args = [_]Value{
        .{ .data = "TS.DECRBY" },
        .{ .data = "myts" },
        .{ .data = "2000" },
        .{ .data = "7.0" },
    };
    try ts_commands.ts_decrby(&writer, &store, &decrby_args);

    // Verify value is 13.0 (formatted as "13" in RESP)
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const get_args = [_]Value{
        .{ .data = "TS.GET" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_get(&writer, &store, &get_args);

    const output = writer.buffered();
    try testing.expect(mem.indexOf(u8, output, "$2\r\n13\r\n") != null or mem.indexOf(u8, output, "$4\r\n13.0\r\n") != null);
}

test "TS.ALTER changes retention" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create with retention 1000
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
        .{ .data = "RETENTION" },
        .{ .data = "1000" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    // Alter retention to 5000
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const alter_args = [_]Value{
        .{ .data = "TS.ALTER" },
        .{ .data = "myts" },
        .{ .data = "RETENTION" },
        .{ .data = "5000" },
    };
    try ts_commands.ts_alter(&writer, &store, &alter_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    // Verify the retention was changed
    const ts = try store.getTimeSeries("myts");
    try testing.expectEqual(@as(u64, 5000), ts.?.retention_ms);
}

test "TS.ALTER changes duplicate policy" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create with BLOCK policy
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
        .{ .data = "DUPLICATE_POLICY" },
        .{ .data = "BLOCK" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    // Alter to LAST policy
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const alter_args = [_]Value{
        .{ .data = "TS.ALTER" },
        .{ .data = "myts" },
        .{ .data = "DUPLICATE_POLICY" },
        .{ .data = "LAST" },
    };
    try ts_commands.ts_alter(&writer, &store, &alter_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    // Verify the policy was changed
    const ts = try store.getTimeSeries("myts");
    try testing.expectEqual(Duplicate_Policy.LAST, ts.?.duplicate_policy);
}

test "TS.RANGE returns samples from active unsealed chunk - Uncompressed" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100, // Large chunk size to avoid sealing
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Add samples without sealing the chunk
    try ts.addSample(1000, 10.0);
    try ts.addSample(2000, 20.0);
    try ts.addSample(3000, 30.0);

    // Verify chunk is active (not sealed)
    try testing.expect(ts.tail != null);
    try testing.expectEqual(@as(usize, 0), ts.tail.?.data.len); // No sealed data yet

    // Query range - should read from active buffer
    var samples = try ts.range("-", "+", null, null);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), samples.items.len);
    try testing.expectEqual(@as(i64, 1000), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 10.0), samples.items[0].value);
    try testing.expectEqual(@as(i64, 2000), samples.items[1].timestamp);
    try testing.expectEqual(@as(f64, 20.0), samples.items[1].value);
    try testing.expectEqual(@as(i64, 3000), samples.items[2].timestamp);
    try testing.expectEqual(@as(f64, 30.0), samples.items[2].value);
}

test "TS.RANGE can read from active unsealed chunk (hybrid approach)" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .DeltaXor, // Compressed encoding
        0,
        0.0,
    );
    defer ts.deinit();

    // Add samples without sealing
    try ts.addSample(1000, 100.0);
    try ts.addSample(2000, 105.0);
    try ts.addSample(3000, 110.0);

    // Verify chunk is active (unsealed)
    try testing.expect(ts.tail != null);
    try testing.expectEqual(@as(usize, 0), ts.tail.?.data.len);

    // Query range - with hybrid approach, active chunks are always readable
    // Active samples are kept uncompressed regardless of encoding setting
    // Compression only happens during chunk sealing
    var samples = try ts.range("-", "+", null, null);
    defer samples.deinit(testing.allocator);

    // Active chunk should return all 3 samples
    try testing.expectEqual(@as(usize, 3), samples.items.len);
    try testing.expectEqual(@as(i64, 1000), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 100.0), samples.items[0].value);
    try testing.expectEqual(@as(i64, 2000), samples.items[1].timestamp);
    try testing.expectEqual(@as(f64, 105.0), samples.items[1].value);
    try testing.expectEqual(@as(i64, 3000), samples.items[2].timestamp);
    try testing.expectEqual(@as(f64, 110.0), samples.items[2].value);
}

test "TS.RANGE with COUNT parameter limits results" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Add 10 samples
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try ts.addSample(1000 + i * 100, @as(f64, @floatFromInt(i)));
    }

    // Query with COUNT 5
    var samples = try ts.range("-", "+", 5, null);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), samples.items.len);
    try testing.expectEqual(@as(i64, 1000), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 0.0), samples.items[0].value);
    try testing.expectEqual(@as(i64, 1400), samples.items[4].timestamp);
    try testing.expectEqual(@as(f64, 4.0), samples.items[4].value);
}

test "TS.RANGE with COUNT larger than available samples returns all" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    try ts.addSample(1000, 10.0);
    try ts.addSample(2000, 20.0);
    try ts.addSample(3000, 30.0);

    // Request 100 samples but only 3 exist
    var samples = try ts.range("-", "+", 100, null);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), samples.items.len);
}

test "TS.RANGE with COUNT across multiple chunks" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        3, // Small chunks to force multiple
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Add 10 samples, creating multiple chunks
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try ts.addSample(1000 + i * 100, @as(f64, @floatFromInt(i)));
    }

    // Query with COUNT 7 - should span across 3 chunks
    var samples = try ts.range("-", "+", 7, null);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 7), samples.items.len);
    try testing.expectEqual(@as(i64, 1000), samples.items[0].timestamp);
    try testing.expectEqual(@as(i64, 1600), samples.items[6].timestamp);
}

test "TS.RANGE command with COUNT parameter" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create time series with uncompressed encoding
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
        .{ .data = "ENCODING" },
        .{ .data = "UNCOMPRESSED" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    // Add 5 samples
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        buffer = mem.zeroes([4096]u8);
        writer = Writer.fixed(&buffer);
        const timestamp_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{1000 + i * 100});
        const value_str = try std.fmt.allocPrint(testing.allocator, "{d}.0", .{i * 10});
        const add_args = [_]Value{
            .{ .data = "TS.ADD" },
            .{ .data = "myts" },
            .{ .data = timestamp_str },
            .{ .data = value_str },
        };
        try ts_commands.ts_add(&writer, &store, &add_args);
    }

    // Range with COUNT 3
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const range_args = [_]Value{
        .{ .data = "TS.RANGE" },
        .{ .data = "myts" },
        .{ .data = "-" },
        .{ .data = "+" },
        .{ .data = "COUNT" },
        .{ .data = "3" },
    };
    try ts_commands.ts_range(&writer, &store, &range_args);

    const output = writer.buffered();
    // Should return array of 3 elements
    try testing.expect(mem.startsWith(u8, output, "*3\r\n"));
}

test "TS.RANGE with 5000 random samples using compressed encoding" {

    // Create a PRNG with fixed seed for reproducibility
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    // Create time series with compressed encoding and reasonable chunk size
    var ts = try TimeSeries.init(
        testing.allocator,
        0, // No retention
        .BLOCK,
        100, // 100 samples per chunk - will create ~50 chunks
        .DeltaXor, // Use compression to test Gorilla codec at scale
        0,
        0.0,
    );
    defer ts.deinit();

    // Generate and add 5000 random samples
    const num_samples = 5000;
    var i: i64 = 0;
    while (i < num_samples) : (i += 1) {
        const timestamp = 1000000 + i * 1000; // Start at 1000000, increment by 1 second
        const value = 20.0 + random.float(f64) * 10.0; // Random temperature between 20-30°C
        try ts.addSample(timestamp, value);
    }

    // Verify all samples were added
    try testing.expectEqual(@as(u64, num_samples), ts.total_samples);

    // Fetch all samples using range query
    var samples = try ts.range("-", "+", null, null);
    defer samples.deinit(testing.allocator);

    // Verify we got all samples back
    try testing.expectEqual(@as(usize, num_samples), samples.items.len);

    // Verify the timestamps are sequential (data integrity check)
    for (samples.items, 0..) |sample, idx| {
        const expected_ts = 1000000 + @as(i64, @intCast(idx)) * 1000;
        try testing.expectEqual(expected_ts, sample.timestamp);
        // Verify value is in expected range
        try testing.expect(sample.value >= 20.0 and sample.value <= 30.0);
    }

    // Test range query with specific start and end timestamps
    const start_ts = 1000000 + 1000 * 1000; // Sample 1000
    const end_ts = 1000000 + 2000 * 1000; // Sample 2000
    const start_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{start_ts});
    defer testing.allocator.free(start_str);
    const end_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{end_ts});
    defer testing.allocator.free(end_str);

    var range_samples = try ts.range(start_str, end_str, null, null);
    defer range_samples.deinit(testing.allocator);

    // Should get samples from 1000 to 2000 inclusive (1001 samples)
    try testing.expectEqual(@as(usize, 1001), range_samples.items.len);
    try testing.expectEqual(start_ts, range_samples.items[0].timestamp);
    try testing.expectEqual(end_ts, range_samples.items[range_samples.items.len - 1].timestamp);

    // Test range query with COUNT parameter
    var limited_samples = try ts.range("-", "+", 500, null);
    defer limited_samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 500), limited_samples.items.len);
    try testing.expectEqual(@as(i64, 1000000), limited_samples.items[0].timestamp);
}

test "TS.RANGE with 5000 random samples using uncompressed encoding" {
    var prng = std.Random.DefaultPrng.init(67890);
    const random = prng.random();

    // Create time series with uncompressed encoding
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed, // Test uncompressed path as well
        0,
        0.0,
    );
    defer ts.deinit();

    // Generate and add 5000 random samples
    const num_samples = 5000;
    var i: i64 = 0;
    while (i < num_samples) : (i += 1) {
        const timestamp = 2000000 + i * 500; // Different base timestamp and interval
        const value = 15.0 + random.float(f64) * 20.0; // Random values between 15-35
        try ts.addSample(timestamp, value);
    }

    try testing.expectEqual(@as(u64, num_samples), ts.total_samples);

    // Fetch all samples
    var samples = try ts.range("-", "+", null, null);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, num_samples), samples.items.len);

    // Verify data integrity
    for (samples.items, 0..) |sample, idx| {
        const expected_ts = 2000000 + @as(i64, @intCast(idx)) * 500;
        try testing.expectEqual(expected_ts, sample.timestamp);
        try testing.expect(sample.value >= 15.0 and sample.value <= 35.0);
    }
}

// Aggregation tests

test "TS.RANGE with AVG aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Add samples with known values across time buckets
    // Bucket 0-999: samples at 0, 500 with values 10, 20 (avg = 15)
    // Bucket 1000-1999: samples at 1000, 1500 with values 30, 50 (avg = 40)
    // Bucket 2000-2999: samples at 2000 with value 100 (avg = 100)
    try ts.addSample(0, 10.0);
    try ts.addSample(500, 20.0);
    try ts.addSample(1000, 30.0);
    try ts.addSample(1500, 50.0);
    try ts.addSample(2000, 100.0);

    const agg = Aggregation{
        .agg_type = .AVG,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), samples.items.len);

    // Bucket 0: avg(10, 20) = 15
    try testing.expectEqual(@as(i64, 0), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 15.0), samples.items[0].value);

    // Bucket 1000: avg(30, 50) = 40
    try testing.expectEqual(@as(i64, 1000), samples.items[1].timestamp);
    try testing.expectEqual(@as(f64, 40.0), samples.items[1].value);

    // Bucket 2000: avg(100) = 100
    try testing.expectEqual(@as(i64, 2000), samples.items[2].timestamp);
    try testing.expectEqual(@as(f64, 100.0), samples.items[2].value);
}

test "TS.RANGE with SUM aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Add samples: bucket 0 (0-99): 5+10=15, bucket 100 (100-199): 20+30=50
    try ts.addSample(10, 5.0);
    try ts.addSample(50, 10.0);
    try ts.addSample(110, 20.0);
    try ts.addSample(150, 30.0);

    const agg = Aggregation{
        .agg_type = .SUM,
        .time_bucket = 100,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(i64, 0), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 15.0), samples.items[0].value);
    try testing.expectEqual(@as(i64, 100), samples.items[1].timestamp);
    try testing.expectEqual(@as(f64, 50.0), samples.items[1].value);
}

test "TS.RANGE with MIN aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: values 100, 50, 75 -> min = 50
    // Bucket 1000: values 200, 150 -> min = 150
    try ts.addSample(100, 100.0);
    try ts.addSample(200, 50.0);
    try ts.addSample(500, 75.0);
    try ts.addSample(1000, 200.0);
    try ts.addSample(1500, 150.0);

    const agg = Aggregation{
        .agg_type = .MIN,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 50.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 150.0), samples.items[1].value);
}

test "TS.RANGE with MAX aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: values 100, 50, 75 -> max = 100
    // Bucket 1000: values 200, 150 -> max = 200
    try ts.addSample(100, 100.0);
    try ts.addSample(200, 50.0);
    try ts.addSample(500, 75.0);
    try ts.addSample(1000, 200.0);
    try ts.addSample(1500, 150.0);

    const agg = Aggregation{
        .agg_type = .MAX,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 100.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 200.0), samples.items[1].value);
}

test "TS.RANGE with COUNT aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: 3 samples
    // Bucket 1000: 2 samples
    // Bucket 2000: 1 sample
    try ts.addSample(100, 1.0);
    try ts.addSample(200, 2.0);
    try ts.addSample(500, 3.0);
    try ts.addSample(1000, 4.0);
    try ts.addSample(1500, 5.0);
    try ts.addSample(2000, 6.0);

    const agg = Aggregation{
        .agg_type = .COUNT,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), samples.items.len);
    try testing.expectEqual(@as(f64, 3.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 2.0), samples.items[1].value);
    try testing.expectEqual(@as(f64, 1.0), samples.items[2].value);
}

test "TS.RANGE with FIRST aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: first = 10
    // Bucket 1000: first = 30
    try ts.addSample(100, 10.0);
    try ts.addSample(200, 20.0);
    try ts.addSample(1000, 30.0);
    try ts.addSample(1500, 40.0);

    const agg = Aggregation{
        .agg_type = .FIRST,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 10.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 30.0), samples.items[1].value);
}

test "TS.RANGE with LAST aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: last = 20
    // Bucket 1000: last = 40
    try ts.addSample(100, 10.0);
    try ts.addSample(200, 20.0);
    try ts.addSample(1000, 30.0);
    try ts.addSample(1500, 40.0);

    const agg = Aggregation{
        .agg_type = .LAST,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 20.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 40.0), samples.items[1].value);
}

test "TS.RANGE with RANGE aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: values 10, 50, 30 -> range = 50 - 10 = 40
    // Bucket 1000: values 100, 200 -> range = 200 - 100 = 100
    try ts.addSample(100, 10.0);
    try ts.addSample(200, 50.0);
    try ts.addSample(500, 30.0);
    try ts.addSample(1000, 100.0);
    try ts.addSample(1500, 200.0);

    const agg = Aggregation{
        .agg_type = .RANGE,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 40.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 100.0), samples.items[1].value);
}

test "TS.RANGE with STD.P (population standard deviation) aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: values 10, 20, 30 -> mean = 20, variance = ((10-20)^2 + (20-20)^2 + (30-20)^2)/3 = 66.666.../3 ≈ 66.67/3, std = sqrt(66.67/3)
    try ts.addSample(0, 10.0);
    try ts.addSample(100, 20.0);
    try ts.addSample(200, 30.0);

    const agg = Aggregation{
        .agg_type = .STD_P,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: sqrt(((10-20)^2 + (20-20)^2 + (30-20)^2)/3) = sqrt((100 + 0 + 100)/3) = sqrt(66.666...) ≈ 8.165
    const expected_std = @sqrt(200.0 / 3.0);
    try testing.expectApproxEqAbs(expected_std, samples.items[0].value, 0.001);
}

test "TS.RANGE with STD.S (sample standard deviation) aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: values 10, 20, 30 -> sample std uses n-1 in denominator
    try ts.addSample(0, 10.0);
    try ts.addSample(100, 20.0);
    try ts.addSample(200, 30.0);

    const agg = Aggregation{
        .agg_type = .STD_S,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: sqrt(((10-20)^2 + (20-20)^2 + (30-20)^2)/2) = sqrt((100 + 0 + 100)/2) = sqrt(100) = 10
    try testing.expectEqual(@as(f64, 10.0), samples.items[0].value);
}

test "TS.RANGE with VAR.P (population variance) aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: values 10, 20, 30
    try ts.addSample(0, 10.0);
    try ts.addSample(100, 20.0);
    try ts.addSample(200, 30.0);

    const agg = Aggregation{
        .agg_type = .VAR_P,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: ((10-20)^2 + (20-20)^2 + (30-20)^2)/3 = 200/3 ≈ 66.666...
    const expected_var = 200.0 / 3.0;
    try testing.expectApproxEqAbs(expected_var, samples.items[0].value, 0.001);
}

test "TS.RANGE with VAR.S (sample variance) aggregation" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Bucket 0: values 10, 20, 30
    try ts.addSample(0, 10.0);
    try ts.addSample(100, 20.0);
    try ts.addSample(200, 30.0);

    const agg = Aggregation{
        .agg_type = .VAR_S,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: ((10-20)^2 + (20-20)^2 + (30-20)^2)/2 = 200/2 = 100
    try testing.expectEqual(@as(f64, 100.0), samples.items[0].value);
}

test "TS.RANGE aggregation with COUNT limit" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        100,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Create 10 buckets with 1 sample each
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try ts.addSample(i * 1000, @as(f64, @floatFromInt(i)));
    }

    const agg = Aggregation{
        .agg_type = .AVG,
        .time_bucket = 1000,
    };

    // Request only first 5 buckets
    var samples = try ts.range("-", "+", 5, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), samples.items.len);
    try testing.expectEqual(@as(i64, 0), samples.items[0].timestamp);
    try testing.expectEqual(@as(i64, 4000), samples.items[4].timestamp);
}

test "TS.RANGE aggregation across multiple chunks" {
    var ts = try TimeSeries.init(
        testing.allocator,
        0,
        .BLOCK,
        5, // Small chunks to force multiple
        .Uncompressed,
        0,
        0.0,
    );
    defer ts.deinit();

    // Add samples across multiple chunks
    // Bucket 0: 4 samples
    // Bucket 1000: 4 samples
    try ts.addSample(0, 10.0);
    try ts.addSample(100, 20.0);
    try ts.addSample(200, 30.0);
    try ts.addSample(300, 40.0);
    try ts.addSample(1000, 50.0);
    try ts.addSample(1100, 60.0);
    try ts.addSample(1200, 70.0);
    try ts.addSample(1300, 80.0);

    const agg = Aggregation{
        .agg_type = .SUM,
        .time_bucket = 1000,
    };

    var samples = try ts.range("-", "+", null, agg);
    defer samples.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 100.0), samples.items[0].value); // 10+20+30+40
    try testing.expectEqual(@as(f64, 260.0), samples.items[1].value); // 50+60+70+80
}

test "TS.RANGE command with aggregation parameter" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create time series
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    // Add samples across multiple buckets
    const timestamps = [_][]const u8{ "0", "500", "1000", "1500", "2000", "2500" };
    const values = [_][]const u8{ "10", "20", "30", "40", "50", "60" };

    for (timestamps, values) |ts_str, val_str| {
        buffer = mem.zeroes([4096]u8);
        writer = Writer.fixed(&buffer);
        const add_args = [_]Value{
            .{ .data = "TS.ADD" },
            .{ .data = "myts" },
            .{ .data = ts_str },
            .{ .data = val_str },
        };
        try ts_commands.ts_add(&writer, &store, &add_args);
    }

    // Range with AVG aggregation, bucket size 1000
    buffer = mem.zeroes([4096]u8);
    writer = Writer.fixed(&buffer);
    const range_args = [_]Value{
        .{ .data = "TS.RANGE" },
        .{ .data = "myts" },
        .{ .data = "-" },
        .{ .data = "+" },
        .{ .data = "AGGREGATION" },
        .{ .data = "AVG" },
        .{ .data = "1000" },
    };
    try ts_commands.ts_range(&writer, &store, &range_args);

    const output = writer.buffered();
    // Should return 3 buckets: [0-999], [1000-1999], [2000-2999]
    try testing.expect(mem.startsWith(u8, output, "*3\r\n"));
}
