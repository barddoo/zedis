const std = @import("std");
const gorilla = @import("./compression/gorilla.zig");
const BitStream = gorilla.BitStream;
const TimestampCompressor = gorilla.TimestampCompressor;
const ValueCompressor = gorilla.ValueCompressor;
const ChunkCompressor = gorilla.ChunkCompressor;
const simd = @import("./simd.zig");

const eql = simd.simdStringEql;

const Sample = struct {
    timestamp: i64,
    value: f64,
};

pub const Duplicate_Policy = enum {
    BLOCK,
    FIRST,
    LAST,
    MIN,
    MAX,
    SUM,

    pub fn fromString(s: []const u8) ?Duplicate_Policy {
        if (eql(s, "BLOCK")) return Duplicate_Policy.BLOCK;
        if (eql(s, "FIRST")) return Duplicate_Policy.FIRST;
        if (eql(s, "LAST")) return Duplicate_Policy.LAST;
        if (eql(s, "MIN")) return Duplicate_Policy.MIN;
        if (eql(s, "MAX")) return Duplicate_Policy.MAX;
        if (eql(s, "SUM")) return Duplicate_Policy.SUM;
        return null;
    }
};

pub const EncodingType = enum(u8) {
    Uncompressed,
    DeltaXor,

    pub fn fromString(s: []const u8) ?EncodingType {
        if (eql(s, "UNCOMPRESSED")) return EncodingType.Uncompressed;
        if (eql(s, "COMPRESSED")) return EncodingType.DeltaXor;
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

    // The active compressor for the tail chunk.
    compressor: ?ChunkCompressor = null,

    // Buffer for uncompressed samples before sealing chunk
    uncompressed_buffer: ?std.ArrayList(Sample) = null,

    // Track last value for duplicate/IGNORE logic
    last_sample: ?Sample = null,

    pub fn init(
        allocator: std.mem.Allocator,
        retention_ms: u64,
        duplicate_policy: ?Duplicate_Policy,
        max_chunk_samples: u16,
        encoding: ?EncodingType,
        ignore_max_time_diff: ?u64,
        ignore_max_val_diff: ?f64,
    ) TimeSeries {
        return TimeSeries{
            .head = null,
            .tail = null,
            .total_samples = 0,
            .retention_ms = retention_ms,
            .allocator = allocator,
            .duplicate_policy = duplicate_policy orelse Duplicate_Policy.BLOCK,
            .max_chunk_samples = max_chunk_samples,
            .encoding = encoding orelse EncodingType.DeltaXor,
            .ignore_max_time_diff = ignore_max_time_diff orelse 0,
            .ignore_max_val_diff = ignore_max_val_diff orelse 0.0,
        };
    }

    pub fn deinit(self: *TimeSeries) void {
        // Deinit the active compressor if it exists
        if (self.compressor) |*c| c.deinit();

        // Deinit the uncompressed buffer if it exists
        if (self.uncompressed_buffer) |*buffer| buffer.deinit(self.allocator);

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
            switch (self.encoding) {
                .DeltaXor => {
                    if (self.compressor) |*comp| {
                        // The chunk's data slice now points to the compressor's final buffer
                        tail_chunk.data = try comp.stream.buffer.toOwnedSlice(self.allocator);
                        comp.deinit(); // Deinit the old compressor
                        self.compressor = null;
                    }
                },
                .Uncompressed => {
                    if (self.uncompressed_buffer) |*buffer| {
                        const samples = buffer.items;
                        // Each sample = 16 bytes (8 bytes timestamp + 8 bytes value)
                        const byte_size = samples.len * 16;
                        tail_chunk.data = try self.allocator.alloc(u8, byte_size);

                        // Convert samples to binary format
                        for (samples, 0..) |sample, i| {
                            const offset = i * 16;
                            // Write timestamp (8 bytes, little-endian)
                            std.mem.writeInt(i64, tail_chunk.data[offset..][0..8], sample.timestamp, .little);
                            // Write value (8 bytes, reinterpret f64 as u64)
                            const value_bits: u64 = @bitCast(sample.value);
                            std.mem.writeInt(u64, tail_chunk.data[offset + 8 ..][0..8], value_bits, .little);
                        }

                        buffer.deinit(self.allocator);
                        self.uncompressed_buffer = null;
                    }
                },
            }
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

        // Initialize storage based on encoding type
        switch (self.encoding) {
            .DeltaXor => {
                self.compressor = ChunkCompressor.init(self.allocator);
            },
            .Uncompressed => {
                // Pre-allocate capacity for optimal performance
                self.uncompressed_buffer = try std.ArrayList(Sample).initCapacity(
                    self.allocator,
                    self.max_chunk_samples,
                );
            },
        }
    }

    /// Append sample to current chunk storage
    fn appendToChunk(self: *TimeSeries, timestamp: i64, value: f64) !void {
        switch (self.encoding) {
            .DeltaXor => {
                try self.compressor.?.add(timestamp, value);
            },
            .Uncompressed => {
                try self.uncompressed_buffer.?.append(self.allocator, .{
                    .timestamp = timestamp,
                    .value = value,
                });
            },
        }
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
        self.last_sample = .{ .timestamp = timestamp, .value = value };

        // Apply retention policy - evict chunks outside retention window
        self.evictExpiredChunks(timestamp);
    }
};
