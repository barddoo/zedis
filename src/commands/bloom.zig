const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");
const Io = std.Io;
const Writer = Io.Writer;

const ScalableBloomFilter = @import("../bloom/bloom.zig").BloomFilter;

pub fn bf_reserve(writer: *Writer, store: *Store, args: []const Value) !void {
    // BF.RESERVE key error_rate capacity [EXPANSION expansion] [NONSCALING]
    if (args.len < 4) return error.WrongNumberOfArguments;

    const key = args[1].asSlice();
    const error_rate_str = args[2].asSlice();
    const capacity_str = args[3].asSlice();

    // Parse error rate
    const error_rate = std.fmt.parseFloat(f64, error_rate_str) catch {
        return error.InvalidArgument;
    };
    if (error_rate <= 0.0 or error_rate >= 1.0) {
        return error.InvalidArgument;
    }

    // Parse capacity
    const capacity = std.fmt.parseInt(u64, capacity_str, 10) catch {
        return error.InvalidArgument;
    };
    if (capacity == 0) {
        return error.InvalidArgument;
    }

    // Parse optional parameters
    var expansion: f64 = 2.0;
    var non_scaling: bool = false;
    var i: usize = 4;
    while (i < args.len) {
        const param = args[i].asSlice();
        if (std.ascii.eqlIgnoreCase(param, "EXPANSION")) {
            if (i + 1 >= args.len) return error.WrongNumberOfArguments;
            const expansion_str = args[i + 1].asSlice();
            expansion = std.fmt.parseFloat(f64, expansion_str) catch {
                return error.InvalidArgument;
            };
            if (expansion <= 1.0) {
                return error.InvalidArgument;
            }
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(param, "NONSCALING")) {
            non_scaling = true;
            i += 1;
        } else {
            return error.InvalidArgument;
        }
    }

    // Check if key already exists
    if (store.exists(key)) {
        return error.AlreadyExists;
    }

    // Create the Bloom filter
    const bf = try ScalableBloomFilter.init(.{
        .initial_capacity = capacity,
        .error_rate = error_rate,
        .allocator = store.allocator,
        .growth_factor = expansion,
        .error_tightening_ratio = 0.5,
        .no_scaling = non_scaling,
    });

    // Store the Bloom filter
    try store.createBloomFilter(key, bf);

    try resp.writeOK(writer);
}

pub fn bf_add(writer: *Writer, store: *Store, args: []const Value) !void {
    // BF.ADD key item
    if (args.len != 3) return error.WrongNumberOfArguments;

    const key = args[1].asSlice();
    const item = args[2].asSlice();

    // Get the Bloom filter
    const bf_ptr = try store.getBloomFilter(key) orelse {
        return error.KeyNotFound;
    };

    // Add the item
    const added = try bf_ptr.add(item);

    // Return 1 if newly added, 0 if already exists (or false positive)
    try resp.writeInt(writer, if (added) 1 else 0);
}

pub fn bf_madd(writer: *Writer, store: *Store, args: []const Value) !void {
    // BF.MADD key item1 [item2 ...]
    if (args.len < 3) return error.WrongNumberOfArguments;

    const key = args[1].asSlice();

    // Get the Bloom filter
    const bf_ptr = try store.getBloomFilter(key) orelse {
        return error.KeyNotFound;
    };

    // Process each item
    const results = try store.allocator.alloc(bool, args.len - 2);
    defer store.allocator.free(results);

    for (args[2..], 0..) |arg, idx| {
        const item = arg.asSlice();
        const added = try bf_ptr.add(item);
        results[idx] = added;
    }

    // Return array of integers
    try resp.writeListLen(writer, results.len);
    for (results) |added| {
        try resp.writeInt(writer, if (added) 1 else 0);
    }
}

pub fn bf_exists(writer: *Writer, store: *Store, args: []const Value) !void {
    // BF.EXISTS key item
    if (args.len != 3) return error.WrongNumberOfArguments;

    const key = args[1].asSlice();
    const item = args[2].asSlice();

    // Get the Bloom filter
    const bf_ptr = try store.getBloomFilter(key) orelse {
        return error.KeyNotFound;
    };

    // Check if item exists
    const exists = bf_ptr.check(item);

    // Return 1 if may exist, 0 if definitely doesn't exist
    try resp.writeInt(writer, if (exists) 1 else 0);
}

pub fn bf_mexists(writer: *Writer, store: *Store, args: []const Value) !void {
    // BF.MEXISTS key item1 [item2 ...]
    if (args.len < 3) return error.WrongNumberOfArguments;

    const key = args[1].asSlice();

    // Get the Bloom filter
    const bf_ptr = try store.getBloomFilter(key) orelse {
        return error.KeyNotFound;
    };

    // Process each item
    const results = try store.allocator.alloc(bool, args.len - 2);
    defer store.allocator.free(results);

    for (args[2..], 0..) |arg, idx| {
        const item = arg.asSlice();
        const exists = bf_ptr.check(item);
        results[idx] = exists;
    }

    // Return array of integers
    try resp.writeListLen(writer, results.len);
    for (results) |exists| {
        try resp.writeInt(writer, if (exists) 1 else 0);
    }
}

pub fn bf_info(writer: *Writer, store: *Store, args: []const Value) !void {
    // BF.INFO key
    if (args.len != 2) return error.WrongNumberOfArguments;

    const key = args[1].asSlice();

    // Get the Bloom filter
    const bf_ptr = try store.getBloomFilter(key) orelse {
        return error.KeyNotFound;
    };

    // Get filter information
    const filter_count = bf_ptr.getFilterCount();
    const total_entries = bf_ptr.getTotalEntries();
    const memory_usage = bf_ptr.getMemoryUsage();

    // Return information as an array
    try resp.writeListLen(writer, 10); // 5 key-value pairs

    // Capacity
    try resp.writeBulkString(writer, "Capacity");
    // For scalable Bloom filter, we don't have a single capacity
    // Return the capacity of the first filter as an approximation
    if (filter_count > 0) {
        // We need to access the first filter's capacity
        // For now, return total entries as capacity estimate
        try resp.writeInt(writer, @as(i64, @intCast(total_entries)));
    } else {
        try resp.writeInt(writer, 0);
    }

    // Size
    try resp.writeBulkString(writer, "Size");
    try resp.writeInt(writer, @as(i64, @intCast(memory_usage)));

    // Number of filters
    try resp.writeBulkString(writer, "Number of filters");
    try resp.writeInt(writer, @as(i64, @intCast(filter_count)));

    // Number of items inserted
    try resp.writeBulkString(writer, "Number of items inserted");
    try resp.writeInt(writer, @as(i64, @intCast(total_entries)));

    // Expansion rate
    try resp.writeBulkString(writer, "Expansion rate");
    try resp.writeInt(writer, 2); // Default expansion rate

    try resp.writeBulkString(writer, "Size");
    try resp.writeInt(writer, @as(i64, @intCast(memory_usage)));
}

pub fn bf_insert(writer: *Writer, store: *Store, args: []const Value) !void {
    // BF.INSERT key [CAPACITY capacity] [ERROR error]
    //           [EXPANSION expansion] [NOCREATE]
    //           [NONSCALING] ITEMS item1 [item2 ...]
    if (args.len < 3) return error.WrongNumberOfArguments;

    const key = args[1].asSlice();

    var capacity: u64 = 100;
    var error_rate: f64 = 0.01;
    var expansion: f64 = 2.0;
    var no_create: bool = false;
    var non_scaling: bool = false;
    var items_start: usize = 0;

    // Parse optional parameters
    var i: usize = 2;
    while (i < args.len) {
        const param = args[i].asSlice();

        if (std.ascii.eqlIgnoreCase(param, "CAPACITY")) {
            if (i + 1 >= args.len) return error.WrongNumberOfArguments;
            const capacity_str = args[i + 1].asSlice();
            capacity = std.fmt.parseInt(u64, capacity_str, 10) catch {
                return error.InvalidArgument;
            };
            if (capacity == 0) return error.InvalidArgument;
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(param, "ERROR")) {
            if (i + 1 >= args.len) return error.WrongNumberOfArguments;
            const error_str = args[i + 1].asSlice();
            error_rate = std.fmt.parseFloat(f64, error_str) catch {
                return error.InvalidArgument;
            };
            if (error_rate <= 0.0 or error_rate >= 1.0) {
                return error.InvalidArgument;
            }
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(param, "EXPANSION")) {
            if (i + 1 >= args.len) return error.WrongNumberOfArguments;
            const expansion_str = args[i + 1].asSlice();
            expansion = std.fmt.parseFloat(f64, expansion_str) catch {
                return error.InvalidArgument;
            };
            if (expansion <= 1.0) return error.InvalidArgument;
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(param, "NOCREATE")) {
            no_create = true;
            i += 1;
        } else if (std.ascii.eqlIgnoreCase(param, "NONSCALING")) {
            non_scaling = true;
            i += 1;
        } else if (std.ascii.eqlIgnoreCase(param, "ITEMS")) {
            items_start = i + 1;
            break;
        } else {
            // Assume this is the start of items
            items_start = i;
            break;
        }
    }

    if (items_start == 0 or items_start >= args.len) {
        return error.WrongNumberOfArguments;
    }

    // Get or create the Bloom filter
    var bf_ptr: *ScalableBloomFilter = blk: {
        if (store.getBloomFilter(key)) |existing_bf| {
            if (no_create) {
                return error.KeyNotFound;
            }
            // Check if parameters match existing filter
            // For simplicity, we'll just use existing filter
            break :blk existing_bf;
        } else |_| {
            // Create new Bloom filter
            const bf = try ScalableBloomFilter.init(.{
                .initial_capacity = capacity,
                .error_rate = error_rate,
                .allocator = store.allocator,
                .growth_factor = expansion,
                .error_tightening_ratio = 0.5,
                .no_scaling = non_scaling,
            });
            try store.createBloomFilter(key, bf);
            break :blk (try store.getBloomFilter(key)).?;
        }
    };

    // Insert items
    const item_count = args.len - items_start;
    const results = try store.allocator.alloc(bool, item_count);
    defer store.allocator.free(results);

    for (args[items_start..], 0..) |arg, idx| {
        const item = arg.asSlice();
        const added = try bf_ptr.add(item);
        results[idx] = added;
    }

    // Return array of integers
    try resp.writeListLen(writer, results.len);
    for (results) |added| {
        try resp.writeInt(writer, if (added) 1 else 0);
    }
}
