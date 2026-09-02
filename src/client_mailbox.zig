const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const MessageNode = struct {
    bytes: []u8,
    next: ?*MessageNode = null,
};

pub const ClientMailbox = struct {
    atomic_mutex: std.atomic.Mutex = .unlocked,
    closed: std.atomic.Value(bool) = .init(false),
    head: ?*MessageNode = null,
    tail: ?*MessageNode = null,
    pending_count: usize = 0,
    capacity: usize,
    node_pool: [4]?*MessageNode = .{null} ** 4,

    pub fn init(capacity: usize) ClientMailbox {
        return .{
            .capacity = capacity,
        };
    }

    pub fn acquire_node(self: *ClientMailbox, allocator: Allocator, bytes: []u8) !*MessageNode {
        for (&self.node_pool) |*slot| {
            if (slot.*) |node| {
                slot.* = null;
                node.* = .{ .bytes = bytes, .next = null };
                return node;
            }
        }
        const node = try allocator.create(MessageNode);
        node.* = .{ .bytes = bytes, .next = null };
        return node;
    }

    pub fn release_node(self: *ClientMailbox, allocator: Allocator, node: *MessageNode) void {
        allocator.free(node.bytes);
        for (&self.node_pool) |*slot| {
            if (slot.* == null) {
                slot.* = node;
                return;
            }
        }
        allocator.destroy(node);
    }

    pub fn free_nodes(self: *ClientMailbox, allocator: Allocator, head: ?*MessageNode) void {
        var current = head;
        while (current) |node| {
            const next = node.next;
            self.release_node(allocator, node);
            current = next;
        }
    }

    pub fn open(self: *ClientMailbox) void {
        self.closed.store(false, .release);
    }

    pub fn close(self: *ClientMailbox) void {
        self.closed.store(true, .release);
    }

    pub fn enqueue(
        self: *ClientMailbox,
        allocator: Allocator,
        bytes: []const u8,
        is_active: bool,
    ) !void {
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);

        const node = try allocator.create(MessageNode);
        errdefer allocator.destroy(node);

        node.* = .{
            .bytes = owned,
            .next = null,
        };

        self.lock_atomic();
        defer self.unlock_atomic();

        if (!is_active or self.closed.load(.acquire)) return error.OutboxClosed;
        if (self.pending_count >= self.capacity) return error.OutboxFull;

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        self.pending_count += 1;
    }

    pub fn take_all(self: *ClientMailbox) ?*MessageNode {
        self.lock_atomic();
        defer self.unlock_atomic();

        const head = self.head;
        self.head = null;
        self.tail = null;
        self.pending_count = 0;
        return head;
    }

    pub fn lock_atomic(self: *ClientMailbox) void {
        while (!self.atomic_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock_atomic(self: *ClientMailbox) void {
        self.atomic_mutex.unlock();
    }

    pub fn deinit(self: *ClientMailbox, allocator: Allocator) void {
        self.close();
        free_message_list(allocator, self.take_all());
        for (&self.node_pool) |*slot| {
            if (slot.*) |node| {
                allocator.destroy(node);
                slot.* = null;
            }
        }
    }
};

pub fn free_message_list(allocator: Allocator, head: ?*MessageNode) void {
    var current = head;
    while (current) |node| {
        const next = node.next;
        allocator.free(node.bytes);
        allocator.destroy(node);
        current = next;
    }
}

const testing = std.testing;

test "ClientMailbox enqueues and drains messages" {
    var mailbox = ClientMailbox.init(2);
    defer mailbox.deinit(testing.allocator);

    try mailbox.enqueue(testing.allocator, "one", true);
    try mailbox.enqueue(testing.allocator, "two", true);

    const head = mailbox.take_all();
    defer free_message_list(testing.allocator, head);

    try testing.expect(head != null);
    try testing.expectEqualStrings("one", head.?.bytes);
    try testing.expect(head.?.next != null);
    try testing.expectEqualStrings("two", head.?.next.?.bytes);
    try testing.expect(mailbox.take_all() == null);
}

test "ClientMailbox rejects closed or full queues" {
    var mailbox = ClientMailbox.init(1);
    defer mailbox.deinit(testing.allocator);

    try mailbox.enqueue(testing.allocator, "one", true);
    try testing.expectError(error.OutboxFull, mailbox.enqueue(testing.allocator, "two", true));

    const head = mailbox.take_all();
    defer free_message_list(testing.allocator, head);
    mailbox.close();
    try testing.expectError(error.OutboxClosed, mailbox.enqueue(testing.allocator, "three", true));
}
