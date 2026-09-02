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
const Io = std.Io;

const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

/// Helper to write last sample in RESP format
fn write_last_sample(writer: *Io.Writer, time_series: *TimeSeries) !void {
    if (time_series.last_sample) |s| {
        // Return [timestamp, value] array
        try resp.write_list_len(writer, 2);
        try resp.write_int(writer, s.timestamp);
        try resp.write_double_bulk_string(writer, s.value);
    } else {
        // Empty time series - return empty array
        try resp.write_list_len(writer, 0);
    }
}

fn modify_and_add(writer: *Io.Writer, store: *Store, args: []const Value, operation: enum { increment, decrement }) !void {
    const key = args[1].as_slice();
    const timestamp = try args[2].as_int();
    const delta = try args[3].as_f64();

    const ts = try store.get_time_series(key);

    if (ts) |time_series| {
        const last_value = time_series.get_last_value();
        const new_value = switch (operation) {
            .increment => last_value + delta,
            .decrement => last_value - delta,
        };
        try time_series.add_sample(timestamp, new_value);
        try resp.write_int(writer, timestamp);
    } else {
        return error.KeyNotFound;
    }
}

pub fn ts_create(writer: *Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    var retention_ms: u64 = 0;
    var encoding: ?[]const u8 = null;
    var chunk_size: u16 = 100;
    var duplicate_policy: ?[]const u8 = null;
    var ignore_max_time_diff: ?u64 = null;
    var ignore_max_val_diff: ?f64 = null;

    for (args, 0..) |value, i| {
        if (eqlIgnoreCase(value.as_slice(), "RETENTION")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            retention_ms = try args[i + 1].as_u64();
        } else if (eqlIgnoreCase(value.as_slice(), "ENCODING")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            encoding = args[i + 1].as_slice();
        } else if (eqlIgnoreCase(value.as_slice(), "CHUNK_SIZE")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            chunk_size = try args[i + 1].as_u16();
        } else if (eqlIgnoreCase(value.as_slice(), "DUPLICATE_POLICY")) {
            if (i + 1 >= args.len) return error.SyntaxError;
            duplicate_policy = args[i + 1].as_slice();
        } else if (eqlIgnoreCase(value.as_slice(), "IGNORE")) {
            if (i + 1 >= args.len or i + 2 >= args.len) return error.SyntaxError;
            ignore_max_time_diff = try args[i + 1].as_u64();
            ignore_max_val_diff = try args[i + 2].as_f64();
        }
    }

    const ts = try TimeSeries.init(
        store.allocator,
        retention_ms,
        if (duplicate_policy) |dp| .from_string(dp) else null,
        chunk_size,
        if (encoding) |enc| .from_string(enc) else null,
        ignore_max_time_diff,
        ignore_max_val_diff,
    );

    try store.create_time_series(key, ts);

    try resp.write_ok(writer);
}

pub fn ts_add(writer: *Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const timestamp = try args[2].as_int();
    const value = try args[3].as_f64();

    const ts = try store.get_time_series(key);

    if (ts) |time_series| {
        try time_series.add_sample(timestamp, value);
        try resp.write_int(writer, timestamp);
    } else {
        return error.KeyNotFound;
    }
}

pub fn ts_get(writer: *Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    const ts = try store.get_time_series(key);

    if (ts) |time_series| {
        try write_last_sample(writer, time_series);
    } else {
        // Key doesn't exist - return error per Redis spec
        return error.KeyNotFound;
    }
}

pub fn ts_incrby(writer: *Io.Writer, store: *Store, args: []const Value) !void {
    try modify_and_add(writer, store, args, .increment);
}

pub fn ts_decrby(writer: *Io.Writer, store: *Store, args: []const Value) !void {
    try modify_and_add(writer, store, args, .decrement);
}

pub fn ts_alter(writer: *Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    const ts = try store.get_time_series(key);

    if (ts) |time_series| {
        var retention_ms: ?u64 = null;
        var chunk_size: ?u16 = null;
        var duplicate_policy: ?Duplicate_Policy = null;

        // Parse optional arguments
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i].as_slice();
            if (eqlIgnoreCase(arg, "RETENTION")) {
                if (i + 1 >= args.len) return error.SyntaxError;
                retention_ms = try args[i + 1].as_u64();
                i += 1;
            } else if (eqlIgnoreCase(arg, "CHUNK_SIZE")) {
                if (i + 1 >= args.len) return error.SyntaxError;
                chunk_size = try args[i + 1].as_u16();
                i += 1;
            } else if (eqlIgnoreCase(arg, "DUPLICATE_POLICY")) {
                if (i + 1 >= args.len) return error.SyntaxError;
                duplicate_policy = .from_string(args[i + 1].as_slice());
                i += 1;
            }
        }

        time_series.alter(retention_ms, duplicate_policy, chunk_size);
        try resp.write_ok(writer);
    } else {
        return error.KeyNotFound;
    }
}

pub fn ts_range(writer: *Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    const ts = try store.get_time_series(key);
    if (ts) |time_series| {
        const start = args[2].as_slice();
        const end = args[3].as_slice();

        // Parse optional parameters
        var count: ?usize = null;
        var aggregation: ?Aggregation = null;

        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            const arg_upper = args[i].as_slice();
            if (std.ascii.eqlIgnoreCase(arg_upper, "COUNT")) {
                if (i + 1 >= args.len) {
                    return error.SyntaxError;
                }
                i += 1;
                const count_val = try args[i].as_int();
                if (count_val <= 0) {
                    return error.InvalidCount;
                }
                count = @intCast(count_val);
            } else if (std.ascii.eqlIgnoreCase(arg_upper, "AGGREGATION")) {
                if (i + 2 >= args.len) {
                    return error.SyntaxError;
                }

                i += 1;
                const agg_type_str = args[i].as_slice();
                const aggregation_type = try AggregationType.from_string(agg_type_str);
                i += 1;
                const aggregation_time_bucket = try args[i].as_u64();

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

        try resp.write_list_len(writer, samples.items.len);
        for (samples.items) |sample| {
            try resp.write_list_len(writer, 2);
            try resp.write_int(writer, sample.timestamp);
            try resp.write_double_bulk_string(writer, sample.value);
        }
    } else {
        return error.KeyNotFound;
    }
}
