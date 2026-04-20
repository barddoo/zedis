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

    pub fn init(capacity: usize) ClientMailbox {
        return .{
            .capacity = capacity,
        };
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

        self.lockAtomic();
        defer self.unlockAtomic();

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

    pub fn takeAll(self: *ClientMailbox) ?*MessageNode {
        self.lockAtomic();
        defer self.unlockAtomic();

        const head = self.head;
        self.head = null;
        self.tail = null;
        self.pending_count = 0;
        return head;
    }

    pub fn lockAtomic(self: *ClientMailbox) void {
        while (!self.atomic_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockAtomic(self: *ClientMailbox) void {
        self.atomic_mutex.unlock();
    }

    pub fn deinit(self: *ClientMailbox, allocator: Allocator) void {
        self.close();
        freeMessageList(allocator, self.takeAll());
    }
};

pub fn freeMessageList(allocator: Allocator, head: ?*MessageNode) void {
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

    const head = mailbox.takeAll();
    defer freeMessageList(testing.allocator, head);

    try testing.expect(head != null);
    try testing.expectEqualStrings("one", head.?.bytes);
    try testing.expect(head.?.next != null);
    try testing.expectEqualStrings("two", head.?.next.?.bytes);
    try testing.expect(mailbox.takeAll() == null);
}

test "ClientMailbox rejects closed or full queues" {
    var mailbox = ClientMailbox.init(1);
    defer mailbox.deinit(testing.allocator);

    try mailbox.enqueue(testing.allocator, "one", true);
    try testing.expectError(error.OutboxFull, mailbox.enqueue(testing.allocator, "two", true));

    const head = mailbox.takeAll();
    defer freeMessageList(testing.allocator, head);
    mailbox.close();
    try testing.expectError(error.OutboxClosed, mailbox.enqueue(testing.allocator, "three", true));
}
