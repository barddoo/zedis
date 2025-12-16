const std = @import("std");
const Value = @import("../parser.zig").Value;
const resp = @import("../commands/resp.zig");
const Allocator = std.mem.Allocator;

/// Aggregate MGET results from multiple shards
/// Returns merged RESP array (first non-null value per key wins)
pub fn aggregateMGET(
    responses: [][]const u8,
    allocator: Allocator,
) ![]const u8 {
    // TODO: Parse RESP arrays from each shard and merge
    // For now, return first response
    if (responses.len > 0) {
        return try allocator.dupe(u8, responses[0]);
    }
    return try allocator.dupe(u8, "*0\r\n");
}

/// Aggregate MSET results from multiple shards
/// All shards return OK, just return single OK
pub fn aggregateMSET(
    responses: [][]const u8,
    allocator: Allocator,
) ![]const u8 {
    _ = responses;
    return try allocator.dupe(u8, "+OK\r\n");
}

/// Aggregate DEL results from multiple shards
/// Sum deletion counts from all shards
pub fn aggregateDEL(
    responses: [][]const u8,
    allocator: Allocator,
) ![]const u8 {
    var total: i64 = 0;

    // Parse each shard's integer response
    for (responses) |response| {
        // Simple RESP integer parsing: ":123\r\n"
        if (response.len > 1 and response[0] == ':') {
            const num_end = std.mem.indexOf(u8, response, "\r\n") orelse continue;
            const num_str = response[1..num_end];
            const num = std.fmt.parseInt(i64, num_str, 10) catch 0;
            total += num;
        }
    }

    // Format as RESP integer
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try resp.writeInt(&writer, total);
    const buffered = writer.buffered();
    return try allocator.dupe(u8, buffered);
}

/// Aggregate KEYS results from multiple shards
/// Merge all key arrays and remove duplicates
pub fn aggregateKEYS(
    responses: [][]const u8,
    allocator: Allocator,
) ![]const u8 {
    var keys_set = std.StringHashMap(void).init(allocator);
    defer keys_set.deinit();

    // Parse each shard's RESP array response
    for (responses) |response| {
        // TODO: Full RESP array parsing
        // For now, simple approach: extract bulk strings
        var i: usize = 0;
        while (i < response.len) {
            if (response[i] == '$') {
                // Find length
                i += 1;
                const len_end = std.mem.indexOfPos(u8, response, i, "\r\n") orelse break;
                const len_str = response[i..len_end];
                const len = std.fmt.parseInt(usize, len_str, 10) catch break;
                i = len_end + 2;

                // Extract key
                if (i + len <= response.len) {
                    const key = response[i..i+len];
                    try keys_set.put(try allocator.dupe(u8, key), {});
                    i += len + 2; // Skip key + \r\n
                } else {
                    break;
                }
            } else {
                i += 1;
            }
        }
    }

    // Build RESP array response using a fixed buffer
    var buf: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try resp.writeListLen(&writer, keys_set.count());

    var iter = keys_set.iterator();
    while (iter.next()) |entry| {
        try resp.writeBulkString(&writer, entry.key_ptr.*);
    }

    const buffered = writer.buffered();
    return try allocator.dupe(u8, buffered);
}

/// Aggregate RENAME results (affects two keys potentially on different shards)
pub fn aggregateRENAME(
    responses: [][]const u8,
    allocator: Allocator,
) ![]const u8 {
    // RENAME just needs one OK response
    _ = responses;
    return try allocator.dupe(u8, "+OK\r\n");
}
