//! Support for blocking list commands (BLPOP, BRPOP, BLMOVE).
//!
//! The command handlers themselves never block: they pop if a list has data
//! and reply nil otherwise, which is also exactly what MULTI/EXEC, Lua and AOF
//! replay need. Blocking happens in `Client.handle`, outside any handler: it
//! checks `is_ready`, parks on a `Waiter` until a push wakes it, then runs the
//! unmodified command. Nothing is logged to the AOF while parked, and on
//! replay the verbatim command pops the same element deterministically.
const std = @import("std");
const zio = @import("zio");
const Store = @import("../storage/store.zig").Store;
const Value = @import("../protocol/parser.zig").Value;

pub const Request = struct {
    /// Keys whose becoming non-empty can satisfy the command.
    keys: []const Value,
    /// Null blocks until data arrives.
    timeout_ns: ?u64,
};

/// Seconds as a decimal, like Redis. Zero means block forever.
pub fn parse_timeout(text: []const u8) error{ InvalidTimeout, NegativeTimeout }!?u64 {
    const seconds = std.fmt.parseFloat(f64, text) catch return error.InvalidTimeout;
    if (std.math.isNan(seconds) or std.math.isInf(seconds)) return error.InvalidTimeout;
    if (seconds < 0) return error.NegativeTimeout;
    if (seconds == 0) return null;
    const ns = seconds * std.time.ns_per_s;
    if (ns >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidTimeout;
    return @max(1, @as(u64, @intFromFloat(ns)));
}

/// Returns null for non-blocking commands and for malformed blocking ones, so
/// the regular handler can produce the right error.
pub fn parse(args: []const Value) ?Request {
    if (args.len < 3) return null;
    const name = args[0].as_slice();

    if (std.ascii.eqlIgnoreCase(name, "BRPOP") or std.ascii.eqlIgnoreCase(name, "BLPOP")) {
        const timeout = parse_timeout(args[args.len - 1].as_slice()) catch return null;
        return .{ .keys = args[1 .. args.len - 1], .timeout_ns = timeout };
    }
    if (std.ascii.eqlIgnoreCase(name, "BLMOVE")) {
        if (args.len != 6) return null;
        const timeout = parse_timeout(args[5].as_slice()) catch return null;
        return .{ .keys = args[1..2], .timeout_ns = timeout };
    }
    return null;
}

/// True when running the command now would not have to wait. A key of the wrong
/// type counts as ready so the handler reports WRONGTYPE instead of hanging.
pub fn is_ready(store: *Store, request: Request) bool {
    for (request.keys) |key| {
        const list = store.get_list(key.as_slice()) catch return true;
        if (list) |l| if (l.len() > 0) return true;
    }
    return false;
}

pub fn is_blmove(args: []const Value) bool {
    return std.ascii.eqlIgnoreCase(args[0].as_slice(), "BLMOVE");
}

pub const Waiter = struct {
    event: zio.Event = .init,
    /// Borrowed from the blocked command's arguments, which stay untouched
    /// while the client is parked.
    keys: []const Value,
    node: std.DoublyLinkedList.Node = .{},
};

/// Clients parked on empty lists. All access happens on the single executor
/// and never across a suspension point, so it needs no lock.
pub const Registry = struct {
    waiters: std.DoublyLinkedList = .{},

    pub fn add(self: *Registry, waiter: *Waiter) void {
        self.waiters.append(&waiter.node);
    }

    pub fn remove(self: *Registry, waiter: *Waiter) void {
        self.waiters.remove(&waiter.node);
    }

    pub fn any(self: *const Registry) bool {
        return self.waiters.first != null;
    }

    pub fn notify_key(self: *Registry, key: []const u8) void {
        var current = self.waiters.first;
        while (current) |node| : (current = node.next) {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            for (waiter.keys) |k| {
                if (std.mem.eql(u8, k.as_slice(), key)) {
                    waiter.event.set();
                    break;
                }
            }
        }
    }
};

const testing = std.testing;

test "timeout parsing accepts decimals, treats zero as forever and rejects junk" {
    try testing.expectEqual(@as(?u64, null), try parse_timeout("0"));
    try testing.expectEqual(@as(?u64, 1_500_000_000), try parse_timeout("1.5"));
    try testing.expectError(error.NegativeTimeout, parse_timeout("-1"));
    try testing.expectError(error.InvalidTimeout, parse_timeout("soon"));
    try testing.expectError(error.InvalidTimeout, parse_timeout("nan"));
}

test "only well-formed blocking commands produce a request" {
    const brpop = [_]Value{ .{ .data = "brpop" }, .{ .data = "a" }, .{ .data = "b" }, .{ .data = "2" } };
    const request = parse(&brpop).?;
    try testing.expectEqual(@as(usize, 2), request.keys.len);
    try testing.expectEqual(@as(?u64, 2_000_000_000), request.timeout_ns);

    const blmove = [_]Value{ .{ .data = "BLMOVE" }, .{ .data = "s" }, .{ .data = "d" }, .{ .data = "LEFT" }, .{ .data = "RIGHT" }, .{ .data = "0" } };
    try testing.expectEqual(@as(usize, 1), parse(&blmove).?.keys.len);

    const bad_timeout = [_]Value{ .{ .data = "BRPOP" }, .{ .data = "a" }, .{ .data = "x" } };
    try testing.expect(parse(&bad_timeout) == null);
    const lpop = [_]Value{ .{ .data = "LPOP" }, .{ .data = "a" }, .{ .data = "1" } };
    try testing.expect(parse(&lpop) == null);
}

test "notify_key wakes only waiters watching that key" {
    var registry: Registry = .{};
    const watching = [_]Value{.{ .data = "queue" }};
    const other = [_]Value{.{ .data = "other" }};
    var a: Waiter = .{ .keys = &watching };
    var b: Waiter = .{ .keys = &other };
    registry.add(&a);
    registry.add(&b);

    registry.notify_key("queue");
    try testing.expect(a.event.isSet());
    try testing.expect(!b.event.isSet());

    registry.remove(&a);
    registry.remove(&b);
    try testing.expect(!registry.any());
}
