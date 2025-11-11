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
        var samples: std.ArrayList(Sample) = .{};
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
