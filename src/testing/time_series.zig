const std = @import("std");
const testing = std.testing;
const ts_mod = @import("../time_series.zig");
const TimeSeries = ts_mod.TimeSeries;
const Duplicate_Policy = @import("../time_series.zig").Duplicate_Policy;
const EncodingType = @import("../time_series.zig").EncodingType;

test "TimeSeries: basic uncompressed storage" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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

test "TimeSeries: compressed vs uncompressed encoding" {
    const allocator = testing.allocator;

    var ts_compressed = try TimeSeries.init(
        allocator,
        0,
        .BLOCK,
        10,
        .DeltaXor,
        0,
        0.0,
    );
    defer ts_compressed.deinit();

    var ts_uncompressed = try TimeSeries.init(
        allocator,
        0,
        .BLOCK,
        10,
        .Uncompressed,
        0,
        0.0,
    );
    defer ts_uncompressed.deinit();

    // Add same samples to both
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try ts_compressed.addSample(1000 + i, @as(f64, @floatFromInt(i)));
        try ts_uncompressed.addSample(1000 + i, @as(f64, @floatFromInt(i)));
    }

    try testing.expectEqual(@as(u64, 5), ts_compressed.total_samples);
    try testing.expectEqual(@as(u64, 5), ts_uncompressed.total_samples);
}

test "TimeSeries: multiple chunks with retention" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
const Store = @import("../store.zig").Store;
const Value = @import("../parser.zig").Value;
const ts_commands = @import("../commands/time_series.zig");

test "TS.INCRBY increments from zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

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
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
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
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
    const get_args = [_]Value{
        .{ .data = "TS.GET" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_get(&writer, &store, &get_args);

    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "$1\r\n5\r\n") != null or std.mem.indexOf(u8, output, "$3\r\n5.0\r\n") != null);
}

test "TS.INCRBY increments from existing value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create and add initial value
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
    const add_args = [_]Value{
        .{ .data = "TS.ADD" },
        .{ .data = "myts" },
        .{ .data = "1000" },
        .{ .data = "10.0" },
    };
    try ts_commands.ts_add(&writer, &store, &add_args);

    // Increment by 3.0
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
    const incrby_args = [_]Value{
        .{ .data = "TS.INCRBY" },
        .{ .data = "myts" },
        .{ .data = "2000" },
        .{ .data = "3.0" },
    };
    try ts_commands.ts_incrby(&writer, &store, &incrby_args);

    // Verify value is 13.0 (formatted as "13" in RESP)
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
    const get_args = [_]Value{
        .{ .data = "TS.GET" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_get(&writer, &store, &get_args);

    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "$2\r\n13\r\n") != null or std.mem.indexOf(u8, output, "$4\r\n13.0\r\n") != null);
}

test "TS.DECRBY decrements value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create and add initial value
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
    const add_args = [_]Value{
        .{ .data = "TS.ADD" },
        .{ .data = "myts" },
        .{ .data = "1000" },
        .{ .data = "20.0" },
    };
    try ts_commands.ts_add(&writer, &store, &add_args);

    // Decrement by 7.0
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
    const decrby_args = [_]Value{
        .{ .data = "TS.DECRBY" },
        .{ .data = "myts" },
        .{ .data = "2000" },
        .{ .data = "7.0" },
    };
    try ts_commands.ts_decrby(&writer, &store, &decrby_args);

    // Verify value is 13.0 (formatted as "13" in RESP)
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
    const get_args = [_]Value{
        .{ .data = "TS.GET" },
        .{ .data = "myts" },
    };
    try ts_commands.ts_get(&writer, &store, &get_args);

    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "$2\r\n13\r\n") != null or std.mem.indexOf(u8, output, "$4\r\n13.0\r\n") != null);
}

test "TS.ALTER changes retention" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create with retention 1000
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
        .{ .data = "RETENTION" },
        .{ .data = "1000" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    // Alter retention to 5000
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create with BLOCK policy
    const create_args = [_]Value{
        .{ .data = "TS.CREATE" },
        .{ .data = "myts" },
        .{ .data = "DUPLICATE_POLICY" },
        .{ .data = "BLOCK" },
    };
    try ts_commands.ts_create(&writer, &store, &create_args);

    // Alter to LAST policy
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), samples.items.len);
    try testing.expectEqual(@as(i64, 1000), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 10.0), samples.items[0].value);
    try testing.expectEqual(@as(i64, 2000), samples.items[1].timestamp);
    try testing.expectEqual(@as(f64, 20.0), samples.items[1].value);
    try testing.expectEqual(@as(i64, 3000), samples.items[2].timestamp);
    try testing.expectEqual(@as(f64, 30.0), samples.items[2].value);
}

test "TS.RANGE can read from active unsealed chunk (hybrid approach)" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 5), samples.items.len);
    try testing.expectEqual(@as(i64, 1000), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 0.0), samples.items[0].value);
    try testing.expectEqual(@as(i64, 1400), samples.items[4].timestamp);
    try testing.expectEqual(@as(f64, 4.0), samples.items[4].value);
}

test "TS.RANGE with COUNT zero returns empty" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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

    // COUNT 0 is not valid, but let's test the edge case
    var samples = try ts.range("-", "+", 0, null);
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), samples.items.len);
}

test "TS.RANGE with COUNT larger than available samples returns all" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), samples.items.len);
}

test "TS.RANGE with COUNT across multiple chunks" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 7), samples.items.len);
    try testing.expectEqual(@as(i64, 1000), samples.items[0].timestamp);
    try testing.expectEqual(@as(i64, 1600), samples.items[6].timestamp);
}

test "TS.RANGE command with COUNT parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

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
        buffer = std.mem.zeroes([4096]u8);
        writer = std.Io.Writer.fixed(&buffer);
        const timestamp_str = try std.fmt.allocPrint(allocator, "{d}", .{1000 + i * 100});
        const value_str = try std.fmt.allocPrint(allocator, "{d}.0", .{i * 10});
        const add_args = [_]Value{
            .{ .data = "TS.ADD" },
            .{ .data = "myts" },
            .{ .data = timestamp_str },
            .{ .data = value_str },
        };
        try ts_commands.ts_add(&writer, &store, &add_args);
    }

    // Range with COUNT 3
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
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
    try testing.expect(std.mem.startsWith(u8, output, "*3\r\n"));
}

test "TS.RANGE with 5000 random samples using compressed encoding" {
    const allocator = testing.allocator;

    // Create a PRNG with fixed seed for reproducibility
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    // Create time series with compressed encoding and reasonable chunk size
    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

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
    const start_str = try std.fmt.allocPrint(allocator, "{d}", .{start_ts});
    defer allocator.free(start_str);
    const end_str = try std.fmt.allocPrint(allocator, "{d}", .{end_ts});
    defer allocator.free(end_str);

    var range_samples = try ts.range(start_str, end_str, null, null);
    defer range_samples.deinit(allocator);

    // Should get samples from 1000 to 2000 inclusive (1001 samples)
    try testing.expectEqual(@as(usize, 1001), range_samples.items.len);
    try testing.expectEqual(start_ts, range_samples.items[0].timestamp);
    try testing.expectEqual(end_ts, range_samples.items[range_samples.items.len - 1].timestamp);

    // Test range query with COUNT parameter
    var limited_samples = try ts.range("-", "+", 500, null);
    defer limited_samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 500), limited_samples.items.len);
    try testing.expectEqual(@as(i64, 1000000), limited_samples.items[0].timestamp);
}

test "TS.RANGE with 5000 random samples using uncompressed encoding" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(67890);
    const random = prng.random();

    // Create time series with uncompressed encoding
    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, num_samples), samples.items.len);

    // Verify data integrity
    for (samples.items, 0..) |sample, idx| {
        const expected_ts = 2000000 + @as(i64, @intCast(idx)) * 500;
        try testing.expectEqual(expected_ts, sample.timestamp);
        try testing.expect(sample.value >= 15.0 and sample.value <= 35.0);
    }
}

// Aggregation tests
const AggregationType = @import("../time_series.zig").AggregationType;
const Aggregation = @import("../time_series.zig").Aggregation;

test "TS.RANGE with AVG aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

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
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(i64, 0), samples.items[0].timestamp);
    try testing.expectEqual(@as(f64, 15.0), samples.items[0].value);
    try testing.expectEqual(@as(i64, 100), samples.items[1].timestamp);
    try testing.expectEqual(@as(f64, 50.0), samples.items[1].value);
}

test "TS.RANGE with MIN aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 50.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 150.0), samples.items[1].value);
}

test "TS.RANGE with MAX aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 100.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 200.0), samples.items[1].value);
}

test "TS.RANGE with COUNT aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), samples.items.len);
    try testing.expectEqual(@as(f64, 3.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 2.0), samples.items[1].value);
    try testing.expectEqual(@as(f64, 1.0), samples.items[2].value);
}

test "TS.RANGE with FIRST aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 10.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 30.0), samples.items[1].value);
}

test "TS.RANGE with LAST aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 20.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 40.0), samples.items[1].value);
}

test "TS.RANGE with RANGE aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 40.0), samples.items[0].value);
    try testing.expectEqual(@as(f64, 100.0), samples.items[1].value);
}

test "TS.RANGE with STD.P (population standard deviation) aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: sqrt(((10-20)^2 + (20-20)^2 + (30-20)^2)/3) = sqrt((100 + 0 + 100)/3) = sqrt(66.666...) ≈ 8.165
    const expected_std = @sqrt(200.0 / 3.0);
    try testing.expectApproxEqAbs(expected_std, samples.items[0].value, 0.001);
}

test "TS.RANGE with STD.S (sample standard deviation) aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: sqrt(((10-20)^2 + (20-20)^2 + (30-20)^2)/2) = sqrt((100 + 0 + 100)/2) = sqrt(100) = 10
    try testing.expectEqual(@as(f64, 10.0), samples.items[0].value);
}

test "TS.RANGE with VAR.P (population variance) aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: ((10-20)^2 + (20-20)^2 + (30-20)^2)/3 = 200/3 ≈ 66.666...
    const expected_var = 200.0 / 3.0;
    try testing.expectApproxEqAbs(expected_var, samples.items[0].value, 0.001);
}

test "TS.RANGE with VAR.S (sample variance) aggregation" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), samples.items.len);

    // Expected: ((10-20)^2 + (20-20)^2 + (30-20)^2)/2 = 200/2 = 100
    try testing.expectEqual(@as(f64, 100.0), samples.items[0].value);
}

test "TS.RANGE aggregation with COUNT limit" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 5), samples.items.len);
    try testing.expectEqual(@as(i64, 0), samples.items[0].timestamp);
    try testing.expectEqual(@as(i64, 4000), samples.items[4].timestamp);
}

test "TS.RANGE aggregation across multiple chunks" {
    const allocator = testing.allocator;

    var ts = try TimeSeries.init(
        allocator,
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
    defer samples.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), samples.items.len);
    try testing.expectEqual(@as(f64, 100.0), samples.items[0].value); // 10+20+30+40
    try testing.expectEqual(@as(f64, 260.0), samples.items[1].value); // 50+60+70+80
}

test "TS.RANGE command with aggregation parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

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
        buffer = std.mem.zeroes([4096]u8);
        writer = std.Io.Writer.fixed(&buffer);
        const add_args = [_]Value{
            .{ .data = "TS.ADD" },
            .{ .data = "myts" },
            .{ .data = ts_str },
            .{ .data = val_str },
        };
        try ts_commands.ts_add(&writer, &store, &add_args);
    }

    // Range with AVG aggregation, bucket size 1000
    buffer = std.mem.zeroes([4096]u8);
    writer = std.Io.Writer.fixed(&buffer);
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
    try testing.expect(std.mem.startsWith(u8, output, "*3\r\n"));
}
