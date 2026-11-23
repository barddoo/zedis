const std = @import("std");
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const PrimitiveValue = @import("../storage/store.zig").PrimitiveValue;
const ZedisListNode = @import("../storage/list.zig").ZedisListNode;
const ZedisList = @import("../storage/list.zig").ZedisList;
const Store = @import("../storage/store.zig").Store;
const resp = @import("../protocol/resp.zig");
const Io = std.Io;
const testing = std.testing;
const Writer = Io.Writer;
const Clock = @import("../app/clock.zig");
const KeyValueAllocator = @import("../storage/kv_allocator.zig");
const blocking = @import("../app/blocking.zig");

/// Helper function to normalize a list index (handles negative indices).
/// Returns null if the index is out of bounds.
inline fn normalize_list_index(index: i64, list_len: usize) ?usize {
    return ZedisList.normalize_index(index, list_len);
}

/// Helper function to normalize a range index with clamping behavior.
/// Used by LRANGE which clamps out-of-bounds indices instead of returning errors.
/// Returns null only when the start index is beyond the list length (should return empty list).
inline fn normalize_range_index(index: i64, list_len: usize, comptime is_start: bool) ?usize {
    if (index < 0) {
        const neg_offset = @as(usize, @intCast(-index));
        if (neg_offset > list_len) {
            return 0; // Clamp to start
        }
        return list_len - neg_offset;
    } else {
        const pos_index = @as(usize, @intCast(index));
        if (is_start) {
            // For start index: if beyond list, signal empty range
            if (pos_index >= list_len) return null;
        } else {
            // For stop index: clamp to last element
            if (pos_index >= list_len) return list_len - 1;
        }
        return pos_index;
    }
}

/// Stages every value in a detached node chain before touching the store, then
/// splices the chain into the list. A push either applies all values or none:
/// like Redis, an OOM must not leave a partial list behind.
fn push_staged(store: *Store, key: []const u8, args: []const Value, comptime prepend: bool) !*ZedisList {
    var staged: std.DoublyLinkedList = .{};
    errdefer {
        while (staged.popFirst()) |node| {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            list_node.data.deinit(store.allocator);
            store.allocator.destroy(list_node);
        }
    }

    for (args) |arg| {
        const pv = try PrimitiveValue.from_slice(arg.as_slice(), store.allocator);
        errdefer pv.deinit(store.allocator);

        const list_node = try store.allocator.create(ZedisListNode);
        list_node.* = .{ .data = pv };
        staged.append(&list_node.node);
    }

    // The list is looked up only after every allocation succeeded: eviction or
    // a failed allocation can no longer invalidate a pointer we hold.
    const list = try store.get_set_list(key);

    while (staged.popFirst()) |node| {
        if (prepend) list.prepend_node(node) else list.append_node(node);
    }

    return list;
}

pub fn lpush(writer: *Writer, store: *Store, args: []const Value) !void {
    const list = try push_staged(store, args[1].as_slice(), args[2..], true);
    try resp.write_int(writer, list.len());
}

pub fn rpush(writer: *Writer, store: *Store, args: []const Value) !void {
    const list = try push_staged(store, args[1].as_slice(), args[2..], false);
    try resp.write_int(writer, list.len());
}

/// Pops up to `count` elements and writes each reply. Popped values own heap
/// memory when longer than the inline string size, so they are freed after
/// being written. Redis removes a key whose list becomes empty.
fn pop_elements(writer: *Writer, store: *Store, args: []const Value, comptime from_head: bool) !void {
    const key = args[1].as_slice();
    const list = try store.get_list(key) orelse {
        try resp.write_null(writer);
        return;
    };

    var count: usize = 1;
    if (args.len == 3) {
        count = try args[2].as_usize();
    }

    const actual_count = @min(count, list.len());
    if (actual_count == 0) {
        try resp.write_null(writer);
        return;
    }

    if (actual_count > 1) try resp.write_list_len(writer, actual_count);
    for (0..actual_count) |_| {
        const item = (if (from_head) list.pop_first() else list.pop()).?;
        defer item.deinit(store.allocator);
        try resp.write_primitive_value(writer, item);
    }

    if (list.len() == 0) _ = store.delete(key);
}

pub fn lpop(writer: *Writer, store: *Store, args: []const Value) !void {
    try pop_elements(writer, store, args, true);
}

pub fn rpop(writer: *Writer, store: *Store, args: []const Value) !void {
    try pop_elements(writer, store, args, false);
}

/// Atomically moves one element between lists. The destination is created and
/// its type checked before the source is popped, and the node is relinked
/// rather than reallocated, so a failure can never drop the element.
/// Returns the moved node (now owned by the destination) or null when the
/// source is empty or missing.
pub fn move_element(store: *Store, src: []const u8, dst: []const u8, from_head: bool, to_head: bool) !?*ZedisListNode {
    const src_list = try store.get_list(src) orelse return null;
    if (src_list.len() == 0) return null;

    _ = try store.get_set_list(dst);

    // Creating the destination may have moved entries; look the source up again.
    const src_now = (try store.get_list(src)).?;
    const node = (if (from_head) src_now.pop_first_node() else src_now.pop_node()).?;
    const dst_list = (try store.get_list(dst)).?;
    if (to_head) dst_list.prepend_node(node) else dst_list.append_node(node);

    if (src_now.len() == 0) _ = store.delete(src);
    return @fieldParentPtr("node", node);
}

fn parse_side(arg: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(arg, "LEFT")) return true;
    if (std.ascii.eqlIgnoreCase(arg, "RIGHT")) return false;
    return error.SyntaxError;
}

fn write_moved(writer: *Writer, node: ?*ZedisListNode) !void {
    if (node) |n| try resp.write_primitive_value(writer, n.data) else try resp.write_null(writer);
}

pub fn lmove(writer: *Writer, store: *Store, args: []const Value) !void {
    const from_head = try parse_side(args[3].as_slice());
    const to_head = try parse_side(args[4].as_slice());
    const node = try move_element(store, args[1].as_slice(), args[2].as_slice(), from_head, to_head);
    try write_moved(writer, node);
}

pub fn rpoplpush(writer: *Writer, store: *Store, args: []const Value) !void {
    const node = try move_element(store, args[1].as_slice(), args[2].as_slice(), false, true);
    try write_moved(writer, node);
}

fn write_null_array(writer: *Writer) !void {
    try writer.writeAll(if (resp.version >= 3) "_\r\n" else "*-1\r\n");
}

/// Non-blocking half of BLPOP/BRPOP: pops from the first non-empty key and
/// replies [key, value], or a nil array when every key is empty. Waiting for
/// data is done by `Client.handle` before the handler runs.
fn pop_first_available(writer: *Writer, store: *Store, args: []const Value, comptime from_head: bool) !void {
    _ = blocking.parse_timeout(args[args.len - 1].as_slice()) catch |err| return switch (err) {
        error.NegativeTimeout => error.NegativeTimeout,
        error.InvalidTimeout => error.InvalidTimeout,
    };

    for (args[1 .. args.len - 1]) |key_arg| {
        const key = key_arg.as_slice();
        const list = try store.get_list(key) orelse continue;
        if (list.len() == 0) continue;

        const item = (if (from_head) list.pop_first() else list.pop()).?;
        defer item.deinit(store.allocator);
        try resp.write_list_len(writer, 2);
        try resp.write_bulk_string(writer, key);
        try resp.write_primitive_value(writer, item);
        if (list.len() == 0) _ = store.delete(key);
        return;
    }
    try write_null_array(writer);
}

pub fn blpop(writer: *Writer, store: *Store, args: []const Value) !void {
    try pop_first_available(writer, store, args, true);
}

pub fn brpop(writer: *Writer, store: *Store, args: []const Value) !void {
    try pop_first_available(writer, store, args, false);
}

/// BLMOVE source destination LEFT|RIGHT LEFT|RIGHT timeout
pub fn blmove(writer: *Writer, store: *Store, args: []const Value) !void {
    _ = try blocking.parse_timeout(args[5].as_slice());
    const from_head = try parse_side(args[3].as_slice());
    const to_head = try parse_side(args[4].as_slice());
    const node = try move_element(store, args[1].as_slice(), args[2].as_slice(), from_head, to_head);
    try write_moved(writer, node);
}

pub fn llen(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const list = try store.get_list(key);

    if (list) |l| {
        try resp.write_int(writer, l.len());
    } else {
        try resp.write_int(writer, 0);
    }
}

pub fn lindex(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const index = try args[2].as_int();
    const list = try store.get_list(key) orelse {
        try resp.write_null(writer);
        return;
    };

    const actual_index = normalize_list_index(index, list.len()) orelse {
        try resp.write_null(writer);
        return;
    };

    const item = list.get_by_index(actual_index) orelse {
        try resp.write_null(writer);
        return;
    };

    try resp.write_primitive_value(writer, item);
}

pub fn lset(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const index = try args[2].as_int();
    const value = args[3].as_slice();

    const list = try store.get_list(key) orelse {
        return error.NoSuchKey;
    };

    const actual_index = normalize_list_index(index, list.len()) orelse {
        return error.KeyNotFound;
    };

    const pv = try PrimitiveValue.from_slice(value, store.allocator);
    try list.set_by_index(actual_index, pv);

    try resp.write_ok(writer);
}

pub fn lrange(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const start = try args[2].as_int();
    const stop = try args[3].as_int();

    const list = try store.get_list(key) orelse {
        try resp.write_list_len(writer, 0);
        return;
    };

    const list_len = list.len();
    if (list_len == 0) {
        try resp.write_list_len(writer, 0);
        return;
    }

    const actual_start = normalize_range_index(start, list_len, true) orelse {
        try resp.write_list_len(writer, 0);
        return;
    };

    const actual_stop = normalize_range_index(stop, list_len, false) orelse {
        try resp.write_list_len(writer, 0);
        return;
    };

    if (actual_start > actual_stop) {
        try resp.write_list_len(writer, 0);
        return;
    }

    const count = actual_stop - actual_start + 1;

    // Preflight the deadline before writing any RESP bytes: aborting after the
    // array length is emitted would leave a partial reply on the wire.
    var probe = list.list.first;
    var probe_index: usize = 0;
    while (probe) |node| : (probe_index += 1) {
        if (probe_index % 1024 == 0 and store.commandExpired()) return error.CommandTimeout;
        if (probe_index >= actual_stop) break;
        probe = node.next;
    }

    try resp.write_list_len(writer, count);

    // Stream items directly without intermediate allocation
    var current = list.list.first;
    var i: usize = 0;
    while (current) |node| : (i += 1) {
        if (i >= actual_start and i <= actual_stop) {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            try resp.write_primitive_value(writer, list_node.data);
        }
        if (i > actual_stop) break;
        current = node.next;
    }
}

pub fn lrem(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const count = args[2].as_int() catch return error.ValueNotInteger;
    const element = args[3].as_slice();

    const list = try store.get_list(key) orelse {
        try resp.write_int(writer, 0);
        return;
    };

    const removed = list.remove(count, element);

    if (list.len() == 0) {
        _ = store.delete(key);
    }

    try resp.write_int(writer, removed);
}

pub fn ltrim(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const start = args[2].as_int() catch return error.ValueNotInteger;
    const stop = args[3].as_int() catch return error.ValueNotInteger;

    const list = try store.get_list(key) orelse {
        try resp.write_ok(writer);
        return;
    };

    list.trim(start, stop);

    if (list.len() == 0) {
        _ = store.delete(key);
    }

    try resp.write_ok(writer);
}

pub fn linsert(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const where_str = args[2].as_slice();
    const pivot = args[3].as_slice();
    const element = args[4].as_slice();

    var buf: [6]u8 = undefined;
    const where_up = std.ascii.upperString(buf[0..@min(where_str.len, buf.len)], where_str);
    const before = std.mem.eql(u8, where_up, "BEFORE");
    if (!before and !std.mem.eql(u8, where_up, "AFTER")) {
        return error.InvalidArgument;
    }

    const list = try store.get_list(key) orelse {
        try resp.write_int(writer, 0);
        return;
    };

    const pv = try PrimitiveValue.from_slice(element, store.allocator);
    errdefer pv.deinit(store.allocator);

    const new_len = if (before)
        try list.insert_before(pivot, pv)
    else
        try list.insert_after(pivot, pv);

    if (new_len) |n| {
        try resp.write_int(writer, n);
    } else {
        pv.deinit(store.allocator);
        try resp.write_int(writer, -1);
    }
}

test "LPUSH single element to new list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "world" },
    };

    try lpush(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const list = try store.get_list("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "LPUSH multiple elements to new list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "three" },
        .{ .data = "two" },
        .{ .data = "one" },
    };

    try lpush(&writer, &store, &args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    const list = try store.get_list("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 3), list.?.len());
}

test "LPUSH to existing list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args1 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "initial" },
    };
    try lpush(&writer, &store, &args1);
    writer = Writer.fixed(&buffer);

    const args2 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "second" },
        .{ .data = "first" },
    };
    try lpush(&writer, &store, &args2);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    const list = try store.get_list("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 3), list.?.len());
}

test "RPUSH single element to new list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };

    try rpush(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const list = try store.get_list("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "RPUSH multiple elements to new list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };

    try rpush(&writer, &store, &args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    const list = try store.get_list("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 3), list.?.len());
}

test "LPOP from list with single element" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
    };
    try lpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());

    // List should be empty now
    const list = try store.get_list("mylist");
    try testing.expect(list == null or list.?.len() == 0);
}

test "LPOP from non-existing list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "nonexistent" },
    };

    try lpop(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "LPOP with count from list with multiple elements" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "three" },
        .{ .data = "two" },
        .{ .data = "one" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
        .{ .data = "2" },
    };
    try lpop(&writer, &store, &pop_args);

    // Should return an array with 2 elements
    try testing.expectEqualStrings("*2\r\n$3\r\none\r\n$3\r\ntwo\r\n", writer.buffered());

    // List should have 1 element left
    const list = try store.get_list("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "LPOP with count of 0" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
        .{ .data = "0" },
    };
    try lpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "RPOP from list with single element" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const pop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
    };
    try rpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());
}

test "RPOP with count from list with multiple elements" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const pop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
        .{ .data = "2" },
    };
    try rpop(&writer, &store, &pop_args);

    // Should return an array with 2 elements (in reverse order from LPOP)
    try testing.expectEqualStrings("*2\r\n$5\r\nthree\r\n$3\r\ntwo\r\n", writer.buffered());

    // List should have 1 element left
    const list = try store.get_list("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "LLEN on existing list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try llen(&writer, &store, &llen_args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());
}

test "LLEN on non-existing list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "nonexistent" },
    };

    try llen(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "Mixed LPUSH and RPUSH operations" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const lpush_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "middle" },
    };
    try lpush(&writer, &store, &lpush_args);
    writer = Writer.fixed(&buffer);

    const lpush_args2 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "left" },
    };
    try lpush(&writer, &store, &lpush_args2);
    writer = Writer.fixed(&buffer);

    const rpush_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "right" },
    };
    try rpush(&writer, &store, &rpush_args);
    writer = Writer.fixed(&buffer);

    // Should have 3 elements in order: left, middle, right
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try llen(&writer, &store, &llen_args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());
}

test "LPOP and RPOP from the same list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // LPOP should get "one"
    const lpop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
    };
    try lpop(&writer, &store, &lpop_args);
    try testing.expectEqualStrings("$3\r\none\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    // RPOP should get "three"
    const rpop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
    };
    try rpop(&writer, &store, &rpop_args);
    try testing.expectEqualStrings("$5\r\nthree\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    // Should have 1 element left ("two")
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try llen(&writer, &store, &llen_args);
    try testing.expectEqualStrings(":1\r\n", writer.buffered());
}

test "LINDEX get first element" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "0" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$3\r\none\r\n", writer.buffered());
}

test "LINDEX get last element with negative index" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$5\r\nthree\r\n", writer.buffered());
}

test "LINDEX with out of range index" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "10" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "LINDEX on non-existing list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
    };

    try lindex(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "LSET update element at index" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "1" },
        .{ .data = "TWO" },
    };
    try lset(&writer, &store, &lset_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "1" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$3\r\nTWO\r\n", writer.buffered());
}

test "LSET with negative index" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
        .{ .data = "THREE" },
    };
    try lset(&writer, &store, &lset_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    // Verify the last element was updated
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$5\r\nTHREE\r\n", writer.buffered());
}

test "LSET on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
        .{ .data = "value" },
    };

    const result = lset(&writer, &store, &args);
    try testing.expectError(error.NoSuchKey, result);
}

test "LSET with out of range index" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "10" },
        .{ .data = "value" },
    };

    const result = lset(&writer, &store, &lset_args);
    try testing.expectError(error.KeyNotFound, result);
}

test "LRANGE get all elements" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "0" },
        .{ .data = "-1" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*3\r\n$3\r\none\r\n$3\r\ntwo\r\n$5\r\nthree\r\n", writer.buffered());
}

test "LRANGE get subset of elements" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
        .{ .data = "four" },
        .{ .data = "five" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "1" },
        .{ .data = "3" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*3\r\n$3\r\ntwo\r\n$5\r\nthree\r\n$4\r\nfour\r\n", writer.buffered());
}

test "LRANGE with negative indices" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
        .{ .data = "four" },
        .{ .data = "five" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "-2" },
        .{ .data = "-1" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*2\r\n$4\r\nfour\r\n$4\r\nfive\r\n", writer.buffered());
}

test "LRANGE on non-existing list" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
        .{ .data = "-1" },
    };

    try lrange(&writer, &store, &args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "LRANGE with out of range indices" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "10" },
        .{ .data = "20" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "LRANGE with reversed range" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "2" },
        .{ .data = "1" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "LPUSH applies every value or none when allocation fails" {
    var kv = try KeyValueAllocator.init(testing.allocator, 4096, .noeviction);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 16,
        .eviction_policy = .noeviction,
    });
    defer store.deinit();
    kv.attach_store(&store);

    var value: [1500]u8 = undefined;
    @memset(&value, 'v');

    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = value[0..] },
        .{ .data = value[0..] },
        .{ .data = value[0..] },
    };

    var buffer: [128]u8 = undefined;
    var writer: Writer = .fixed(&buffer);

    try testing.expectError(error.OutOfMemory, lpush(&writer, &store, &push_args));
    try testing.expect(!store.exists("mylist"));
    try testing.expectEqual(@as(u32, 0), store.size());
}

test "repeated LPUSH under allkeys-lru never evicts the list mid-command" {
    const budget = 8192;

    var kv = try KeyValueAllocator.init(testing.allocator, budget, .allkeys_lru);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 16,
        .eviction_policy = .allkeys_lru,
        .maxmemory_samples = 5,
    });
    defer store.deinit();
    kv.attach_store(&store);

    var value: [1024]u8 = undefined;
    @memset(&value, 'L');

    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "list" },
        .{ .data = value[0..] },
    };

    var buffer: [64]u8 = undefined;
    for (0..200) |_| {
        // Same order as Server.execute_locked: evict at the command boundary,
        // then run the command with the budget soft. Eviction inside the push
        // would free the list the handler is writing to.
        _ = kv.enforce_budget();
        kv.begin_command();
        var writer: Writer = .fixed(&buffer);
        const result = lpush(&writer, &store, &push_args);
        kv.end_command();
        try result;

        try testing.expect(store.exists("list"));
        try testing.expect(kv.get_memory_usage() <= budget + value.len + 512);
    }

    try testing.expect(store.size() == 1);
}

test "popping the last element frees long values and removes the key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const long_value = "a value longer than the inline short string capacity";
    var buffer: [256]u8 = undefined;
    inline for (.{ .{ "LPOP", lpop }, .{ "RPOP", rpop } }) |case| {
        var writer = Writer.fixed(&buffer);
        _ = try rpush(&writer, &store, &[_]Value{ .{ .data = "RPUSH" }, .{ .data = "k" }, .{ .data = long_value } });

        writer = Writer.fixed(&buffer);
        try case[1](&writer, &store, &[_]Value{ .{ .data = case[0] }, .{ .data = "k" } });

        try testing.expect(std.mem.indexOf(u8, writer.buffered(), long_value) != null);
        try testing.expect(try store.get_list("k") == null);
    }
}

test "LMOVE relinks the element between lists and removes the drained source" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const long_value = "a value longer than the inline short string capacity";
    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try rpush(&writer, &store, &[_]Value{ .{ .data = "RPUSH" }, .{ .data = "src" }, .{ .data = long_value }, .{ .data = "b" } });

    writer = Writer.fixed(&buffer);
    try lmove(&writer, &store, &[_]Value{ .{ .data = "LMOVE" }, .{ .data = "src" }, .{ .data = "dst" }, .{ .data = "left" }, .{ .data = "RIGHT" } });
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), long_value) != null);

    writer = Writer.fixed(&buffer);
    try rpoplpush(&writer, &store, &[_]Value{ .{ .data = "RPOPLPUSH" }, .{ .data = "src" }, .{ .data = "dst" } });
    try testing.expectEqualStrings("$1\r\nb\r\n", writer.buffered());

    try testing.expect(try store.get_list("src") == null);
    try testing.expectEqual(@as(usize, 2), (try store.get_list("dst")).?.len());
}

test "LMOVE with the same key rotates the list" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try rpush(&writer, &store, &[_]Value{ .{ .data = "RPUSH" }, .{ .data = "k" }, .{ .data = "a" }, .{ .data = "b" }, .{ .data = "c" } });

    writer = Writer.fixed(&buffer);
    try lmove(&writer, &store, &[_]Value{ .{ .data = "LMOVE" }, .{ .data = "k" }, .{ .data = "k" }, .{ .data = "RIGHT" }, .{ .data = "LEFT" } });
    try testing.expectEqualStrings("$1\r\nc\r\n", writer.buffered());

    const list = (try store.get_list("k")).?;
    try testing.expectEqual(@as(usize, 3), list.len());
    var first = list.get_by_index(0).?;
    try testing.expectEqualStrings("c", first.short_string.as_slice());
}

test "LMOVE leaves the source intact when the destination has the wrong type" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try rpush(&writer, &store, &[_]Value{ .{ .data = "RPUSH" }, .{ .data = "src" }, .{ .data = "a" } });
    try store.set("dst", "text");

    writer = Writer.fixed(&buffer);
    try testing.expectError(error.WrongType, lmove(&writer, &store, &[_]Value{ .{ .data = "LMOVE" }, .{ .data = "src" }, .{ .data = "dst" }, .{ .data = "LEFT" }, .{ .data = "LEFT" } }));
    try testing.expectEqual(@as(usize, 1), (try store.get_list("src")).?.len());
}

test "BRPOP pops the first non-empty key and replies key then value" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    _ = try rpush(&writer, &store, &[_]Value{ .{ .data = "RPUSH" }, .{ .data = "b" }, .{ .data = "x" }, .{ .data = "y" } });

    writer = Writer.fixed(&buffer);
    try brpop(&writer, &store, &[_]Value{ .{ .data = "BRPOP" }, .{ .data = "a" }, .{ .data = "b" }, .{ .data = "1" } });
    try testing.expectEqualStrings("*2\r\n$1\r\nb\r\n$1\r\ny\r\n", writer.buffered());

    writer = Writer.fixed(&buffer);
    try blpop(&writer, &store, &[_]Value{ .{ .data = "BLPOP" }, .{ .data = "b" }, .{ .data = "0" } });
    try testing.expectEqualStrings("*2\r\n$1\r\nb\r\n$1\r\nx\r\n", writer.buffered());
    try testing.expect(try store.get_list("b") == null);
}

test "BRPOP on empty keys replies nil instead of waiting" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [64]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try brpop(&writer, &store, &[_]Value{ .{ .data = "BRPOP" }, .{ .data = "a" }, .{ .data = "0" } });
    try testing.expectEqualStrings("*-1\r\n", writer.buffered());
}

test "BRPOP rejects a negative or non-numeric timeout" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [64]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try testing.expectError(error.NegativeTimeout, brpop(&writer, &store, &[_]Value{ .{ .data = "BRPOP" }, .{ .data = "a" }, .{ .data = "-1" } }));
    try testing.expectError(error.InvalidTimeout, brpop(&writer, &store, &[_]Value{ .{ .data = "BRPOP" }, .{ .data = "a" }, .{ .data = "x" } }));
}

test "BLMOVE moves like LMOVE when the source has data" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [64]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    _ = try rpush(&writer, &store, &[_]Value{ .{ .data = "RPUSH" }, .{ .data = "s" }, .{ .data = "a" } });

    writer = Writer.fixed(&buffer);
    try blmove(&writer, &store, &[_]Value{ .{ .data = "BLMOVE" }, .{ .data = "s" }, .{ .data = "d" }, .{ .data = "LEFT" }, .{ .data = "LEFT" }, .{ .data = "1" } });
    try testing.expectEqualStrings("$1\r\na\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 1), (try store.get_list("d")).?.len());
}
