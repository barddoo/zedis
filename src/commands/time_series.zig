const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");
const ts_mod = @import("../time_series.zig");
const TimeSeries = ts_mod.TimeSeries;
const Duplicate_Policy = ts_mod.Duplicate_Policy;
const EncodingType = ts_mod.EncodingType;
const Aggregation = ts_mod.Aggregation;
const AggregationType = ts_mod.AggregationType;

const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

/// Helper to write last sample in RESP format
fn writeLastSample(writer: *std.Io.Writer, time_series: *TimeSeries) !void {
    if (time_series.last_sample) |s| {
        // Return [timestamp, value] array
        try resp.writeListLen(writer, 2);
        try resp.writeInt(writer, s.timestamp);
        try resp.writeDoubleBulkString(writer, s.value);
    } else {
        // Empty time series - return empty array
        try resp.writeListLen(writer, 0);
    }
}

fn modifyAndAdd(writer: *std.Io.Writer, store: *Store, args: []const Value, operation: enum { increment, decrement }) !void {
    const key = args[1].asSlice();
    const timestamp = try args[2].asInt();
    const delta = try args[3].asF64();

    const ts = try store.getTimeSeries(key);

    if (ts) |time_series| {
        const last_value = time_series.getLastValue();
        const new_value = switch (operation) {
            .increment => last_value + delta,
            .decrement => last_value - delta,
        };
        try time_series.addSample(timestamp, new_value);
        try resp.writeInt(writer, timestamp);
    } else {
        return error.KeyNotFound;
    }
}

pub fn ts_create(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    var retention_ms: u64 = 0;
    var encoding: ?[]const u8 = null;
    var chunk_size: u16 = 100;
    var duplicate_policy: ?[]const u8 = null;
    var ignore_max_time_diff: ?u64 = null;
    var ignore_max_val_diff: ?f64 = null;

    for (args, 0..) |value, i| {
        if (eqlIgnoreCase(value.asSlice(), "RETENTION")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            retention_ms = try args[i + 1].asU64();
        } else if (eqlIgnoreCase(value.asSlice(), "ENCODING")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            encoding = args[i + 1].asSlice();
        } else if (eqlIgnoreCase(value.asSlice(), "CHUNK_SIZE")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            chunk_size = try args[i + 1].asU16();
        } else if (eqlIgnoreCase(value.asSlice(), "DUPLICATE_POLICY")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            duplicate_policy = args[i + 1].asSlice();
        } else if (eqlIgnoreCase(value.asSlice(), "IGNORE")) {
            if (i + 1 >= args.len or i + 2 >= args.len) return error.SyntaxError;
            ignore_max_time_diff = try args[i + 1].asU64();
            ignore_max_val_diff = try args[i + 2].asF64();
        }
    }

    const ts = try TimeSeries.init(
        store.base_allocator,
        retention_ms,
        if (duplicate_policy) |dp| .fromString(dp) else null,
        chunk_size,
        if (encoding) |enc| .fromString(enc) else null,
        ignore_max_time_diff,
        ignore_max_val_diff,
    );

    try store.createTimeSeries(key, ts);

    try resp.writeOK(writer);
}

pub fn ts_add(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const timestamp = try args[2].asInt();
    const value = try args[3].asF64();

    const ts = try store.getTimeSeries(key);

    if (ts) |time_series| {
        try time_series.addSample(timestamp, value);
        try resp.writeInt(writer, timestamp);
    } else {
        return error.KeyNotFound;
    }
}

pub fn ts_get(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const ts = try store.getTimeSeries(key);

    if (ts) |time_series| {
        try writeLastSample(writer, time_series);
    } else {
        // Key doesn't exist - return error per Redis spec
        return error.KeyNotFound;
    }
}

pub fn ts_incrby(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    try modifyAndAdd(writer, store, args, .increment);
}

pub fn ts_decrby(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    try modifyAndAdd(writer, store, args, .decrement);
}

pub fn ts_alter(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const ts = try store.getTimeSeries(key);

    if (ts) |time_series| {
        var retention_ms: ?u64 = null;
        var chunk_size: ?u16 = null;
        var duplicate_policy: ?Duplicate_Policy = null;

        // Parse optional arguments
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i].asSlice();
            if (eqlIgnoreCase(arg, "RETENTION")) {
                if (i + 1 >= args.len) return error.SyntaxError;
                retention_ms = try args[i + 1].asU64();
                i += 1;
            } else if (eqlIgnoreCase(arg, "CHUNK_SIZE")) {
                if (i + 1 >= args.len) return error.SyntaxError;
                chunk_size = try args[i + 1].asU16();
                i += 1;
            } else if (eqlIgnoreCase(arg, "DUPLICATE_POLICY")) {
                if (i + 1 >= args.len) return error.SyntaxError;
                duplicate_policy = .fromString(args[i + 1].asSlice());
                i += 1;
            }
        }

        time_series.alter(retention_ms, duplicate_policy, chunk_size);
        try resp.writeOK(writer);
    } else {
        return error.KeyNotFound;
    }
}

pub fn ts_range(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const ts = try store.getTimeSeries(key);
    if (ts) |time_series| {
        const start = args[2].asSlice();
        const end = args[3].asSlice();

        // Parse optional parameters
        var count: ?usize = null;
        var aggregation: ?Aggregation = null;

        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            const arg_upper = args[i].asSlice();
            if (std.ascii.eqlIgnoreCase(arg_upper, "COUNT")) {
                if (i + 1 >= args.len) {
                    return error.SyntaxError;
                }
                i += 1;
                const count_val = try args[i].asInt();
                if (count_val <= 0) {
                    return error.InvalidCount;
                }
                count = @intCast(count_val);
            } else if (std.ascii.eqlIgnoreCase(arg_upper, "AGGREGATION")) {
                if (i + 2 >= args.len) {
                    return error.SyntaxError;
                }

                i += 1;
                const agg_type_str = args[i].asSlice();
                const aggregation_type = try AggregationType.fromString(agg_type_str);
                i += 1;
                const aggregation_time_bucket = try args[i].asU64();

                aggregation = .{
                    .agg_type = aggregation_type,
                    .time_bucket = aggregation_time_bucket,
                };
            } else {
                // Unknown parameter
                return error.SyntaxError;
            }
        }

        var samples = try time_series.range(start, end, count, aggregation);
        defer samples.deinit(store.allocator);

        try resp.writeListLen(writer, samples.items.len);
        for (samples.items) |sample| {
            try resp.writeListLen(writer, 2);
            try resp.writeInt(writer, sample.timestamp);
            try resp.writeDoubleBulkString(writer, sample.value);
        }
    } else {
        return error.KeyNotFound;
    }
}
