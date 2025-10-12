const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");
const ts_mod = @import("../time_series.zig");
const TimeSeries = ts_mod.TimeSeries;
const Duplicate_Policy = ts_mod.Duplicate_Policy;
const EncodingType = ts_mod.EncodingType;
const simd = @import("../simd.zig");

const eql = simd.simdStringEql;

pub fn ts_create(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    var retention_ms: u64 = undefined;
    var encoding: []const u8 = undefined;
    var chunk_size: u16 = undefined;
    var duplicate_policy: []const u8 = undefined;
    var ignore_max_time_diff: ?u64 = undefined;
    var ignore_max_val_diff: ?f64 = undefined;

    for (args, 0..) |value, i| {
        if (eql(value.asSlice(), "RETENTION")) {
            retention_ms = try args[i + 1].asU64();
        } else if (eql(value.asSlice(), "ENCODING")) {
            encoding = args[i + 1].asSlice();
        } else if (eql(value.asSlice(), "CHUNK_SIZE")) {
            chunk_size = try args[i + 1].asU16();
        } else if (eql(value.asSlice(), "DUPLICATE_POLICY")) {
            duplicate_policy = args[i + 1].asSlice();
        } else if (eql(value.asSlice(), "IGNORE")) {
            ignore_max_time_diff = try args[i + 1].asU64();
            ignore_max_val_diff = try args[i + 2].asF64();
        }
    }

    const ts = TimeSeries.init(
        store.base_allocator,
        retention_ms,
        Duplicate_Policy.fromString(duplicate_policy),
        if (chunk_size == 0) 4096 else chunk_size,
        EncodingType.fromString(encoding),
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
        if (time_series.last_sample) |s| {
            // Return [timestamp, value] array
            try resp.writeListLen(writer, 2);
            try resp.writeInt(writer, s.timestamp);
            try resp.writeDoubleBulkString(writer, s.value);
        } else {
            // Empty time series - return empty array
            try resp.writeListLen(writer, 0);
        }
    } else {
        // Key doesn't exist - return error per Redis spec
        return error.KeyNotFound;
    }
}
