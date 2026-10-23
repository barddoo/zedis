const std = @import("std");
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const Server = @import("../app/server.zig");
const resp = @import("../protocol/resp.zig");
const ClientHandle = @import("../util/types.zig").ClientHandle;
const testing = std.testing;
const free_message_list = @import("../util/client_mailbox.zig").free_message_list;

/// Pub/sub operations the command handlers need. A vtable keeps them testable
/// without a real `Server` (tests inject an in-memory mock).
pub const PubSubContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        subscribe: *const fn (ptr: *anyopaque, channel: []const u8, handle: ClientHandle) anyerror!bool,
        unsubscribe: *const fn (ptr: *anyopaque, channel: []const u8, handle: ClientHandle) anyerror!bool,
        unsubscribe_all: *const fn (ptr: *anyopaque, handle: ClientHandle, allocator: std.mem.Allocator) anyerror![][]u8,
        publish: *const fn (ptr: *anyopaque, channel: []const u8, payload: []const u8) anyerror!usize,
    };

    pub fn init(server: *Server) PubSubContext {
        return .{
            .ptr = server,
            .vtable = &.{
                .subscribe = server_subscribe,
                .unsubscribe = server_unsubscribe,
                .unsubscribe_all = server_unsubscribe_all,
                .publish = server_publish,
            },
        };
    }

    pub fn subscribe(self: PubSubContext, channel_name: []const u8, handle: ClientHandle) !bool {
        return self.vtable.subscribe(self.ptr, channel_name, handle);
    }

    pub fn unsubscribe(self: PubSubContext, channel_name: []const u8, handle: ClientHandle) !bool {
        return self.vtable.unsubscribe(self.ptr, channel_name, handle);
    }

    pub fn unsubscribeAll(self: PubSubContext, handle: ClientHandle, allocator: std.mem.Allocator) ![][]u8 {
        return self.vtable.unsubscribe_all(self.ptr, handle, allocator);
    }

    pub fn publish(self: PubSubContext, channel_name: []const u8, payload: []const u8) !usize {
        return self.vtable.publish(self.ptr, channel_name, payload);
    }
};

fn server_subscribe(ptr: *anyopaque, channel_name: []const u8, handle: ClientHandle) anyerror!bool {
    const server: *Server = @ptrCast(@alignCast(ptr));
    return server.subscribe_to_channel(channel_name, handle);
}

fn server_unsubscribe(ptr: *anyopaque, channel_name: []const u8, handle: ClientHandle) anyerror!bool {
    const server: *Server = @ptrCast(@alignCast(ptr));
    return server.unsubscribe_from_channel(channel_name, handle);
}

fn server_unsubscribe_all(ptr: *anyopaque, handle: ClientHandle, allocator: std.mem.Allocator) anyerror![][]u8 {
    const server: *Server = @ptrCast(@alignCast(ptr));
    return server.unsubscribe_all(handle, allocator);
}

fn server_publish(ptr: *anyopaque, channel_name: []const u8, payload: []const u8) anyerror!usize {
    const server: *Server = @ptrCast(@alignCast(ptr));
    return server.publish_to_channel(channel_name, payload);
}

pub fn subscribe(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    // Enter pubsub mode on first subscription
    if (!client.is_in_pubsub_mode) {
        client.enter_pub_sub_mode();
    }
    // Pushes messages even while this coroutine is blocked reading the socket.
    client.start_mailbox_delivery();

    for (args[1..]) |item| {
        const channel_name = item.as_slice();
        // Subscribe client to channel
        const newly_subscribed = client.pubsub_context.subscribe(channel_name, client.slot_handle) catch |err| switch (err) {
            error.ChannelLimitReached => {
                try resp.write_error(writer, "ERR maximum number of channels reached");
                continue;
            },
            error.ChannelFull => {
                try resp.write_error(writer, "ERR maximum subscribers per channel reached");
                continue;
            },
            else => {
                try resp.write_error(writer, "ERR failed to subscribe to channel");
                continue;
            },
        };
        if (newly_subscribed) client.subscription_count += 1;
        const subscription_count: i64 = @intCast(client.subscription_count);

        const response_tuple = .{
            "subscribe",
            channel_name,
            subscription_count,
        };

        // Use a generic writer to send the tuple as a RESP array.
        try resp.write_tuple_as_array(writer, response_tuple);
    }
}

pub fn unsubscribe(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    if (args.len == 1) {
        const names = try client.pubsub_context.unsubscribeAll(client.slot_handle, client.allocator);
        defer {
            for (names) |name| client.allocator.free(name);
            client.allocator.free(names);
        }

        if (names.len == 0) {
            try writer.writeAll("*3\r\n$11\r\nunsubscribe\r\n$-1\r\n:0\r\n");
        } else {
            for (names) |name| {
                if (client.subscription_count > 0) client.subscription_count -= 1;
                const count: i64 = @intCast(client.subscription_count);
                try resp.write_tuple_as_array(writer, .{ "unsubscribe", name, count });
            }
        }
    } else {
        for (args[1..]) |item| {
            const channel_name = item.as_slice();
            const removed = try client.pubsub_context.unsubscribe(channel_name, client.slot_handle);
            if (removed and client.subscription_count > 0) client.subscription_count -= 1;
            const count: i64 = @intCast(client.subscription_count);
            try resp.write_tuple_as_array(writer, .{ "unsubscribe", channel_name, count });
        }
    }

    if (client.subscription_count == 0) client.is_in_pubsub_mode = false;
}

pub fn publish(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const channel_name = args[1].as_slice();
    const message = args[2].as_slice();
    const payload = try serialize_pub_sub_message(client.allocator, channel_name, message);
    defer client.allocator.free(payload);

    const messages_sent = try client.pubsub_context.publish(channel_name, payload);
    try resp.write_int(writer, @as(i64, @intCast(messages_sent)));
}

fn serialize_pub_sub_message(allocator: std.mem.Allocator, channel_name: []const u8, message: []const u8) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();

    resp.write_tuple_as_array(&buffer.writer, .{ "message", channel_name, message }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    return try buffer.toOwnedSlice();
}

const MockPubSub = struct {
    allocator: std.mem.Allocator,
    subscriptions: std.ArrayList(Subscription) = .empty,
    published: std.ArrayList(Published) = .empty,
    /// When set, the next subscribe/publish call fails with this error, so the
    /// handler's error mapping can be tested without a real store or server.
    next_error: ?anyerror = null,
    publish_return: usize = 0,

    const Subscription = struct { channel: []u8, handle: ClientHandle };
    const Published = struct { channel: []u8, payload: []u8 };

    fn init(allocator: std.mem.Allocator) MockPubSub {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MockPubSub) void {
        for (self.subscriptions.items) |sub| self.allocator.free(sub.channel);
        self.subscriptions.deinit(self.allocator);
        for (self.published.items) |message| {
            self.allocator.free(message.channel);
            self.allocator.free(message.payload);
        }
        self.published.deinit(self.allocator);
    }

    fn context(self: *MockPubSub) PubSubContext {
        return .{
            .ptr = self,
            .vtable = &.{
                .subscribe = mock_subscribe,
                .unsubscribe = mock_unsubscribe,
                .unsubscribe_all = mock_unsubscribe_all,
                .publish = mock_publish,
            },
        };
    }

    fn find(self: *MockPubSub, channel: []const u8, handle: ClientHandle) ?usize {
        for (self.subscriptions.items, 0..) |sub, i| {
            if (ClientHandle.eql(sub.handle, handle) and std.mem.eql(u8, sub.channel, channel)) return i;
        }
        return null;
    }
};

fn mock_subscribe(ptr: *anyopaque, channel: []const u8, handle: ClientHandle) anyerror!bool {
    const self: *MockPubSub = @ptrCast(@alignCast(ptr));
    if (self.next_error) |err| {
        self.next_error = null;
        return err;
    }
    if (self.find(channel, handle) != null) return false;

    const owned = try self.allocator.dupe(u8, channel);
    errdefer self.allocator.free(owned);
    try self.subscriptions.append(self.allocator, .{ .channel = owned, .handle = handle });
    return true;
}

fn mock_unsubscribe(ptr: *anyopaque, channel: []const u8, handle: ClientHandle) anyerror!bool {
    const self: *MockPubSub = @ptrCast(@alignCast(ptr));
    const index = self.find(channel, handle) orelse return false;
    self.allocator.free(self.subscriptions.items[index].channel);
    _ = self.subscriptions.swapRemove(index);
    return true;
}

fn mock_unsubscribe_all(ptr: *anyopaque, handle: ClientHandle, allocator: std.mem.Allocator) anyerror![][]u8 {
    const self: *MockPubSub = @ptrCast(@alignCast(ptr));

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var i: usize = 0;
    while (i < self.subscriptions.items.len) {
        const sub = self.subscriptions.items[i];
        if (!ClientHandle.eql(sub.handle, handle)) {
            i += 1;
            continue;
        }

        const copy = try allocator.dupe(u8, sub.channel);
        errdefer allocator.free(copy);
        try names.append(allocator, copy);
        self.allocator.free(sub.channel);
        _ = self.subscriptions.swapRemove(i);
    }

    return try names.toOwnedSlice(allocator);
}

fn mock_publish(ptr: *anyopaque, channel: []const u8, payload: []const u8) anyerror!usize {
    const self: *MockPubSub = @ptrCast(@alignCast(ptr));
    if (self.next_error) |err| {
        self.next_error = null;
        return err;
    }

    const owned_channel = try self.allocator.dupe(u8, channel);
    errdefer self.allocator.free(owned_channel);
    const owned_payload = try self.allocator.dupe(u8, payload);
    errdefer self.allocator.free(owned_payload);

    try self.published.append(self.allocator, .{ .channel = owned_channel, .payload = owned_payload });
    return self.publish_return;
}

const TestContext = struct {
    allocator: std.mem.Allocator,
    mock: MockPubSub,
    context: PubSubContext,

    fn init(self: *TestContext, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.mock = MockPubSub.init(allocator);
        self.context = self.mock.context();
    }

    fn deinit(self: *TestContext) void {
        self.mock.deinit();
    }

    /// A handler-only client. `delivery_started` is pre-set so tests don't
    /// spawn the zio delivery task (it needs a zio runtime).
    fn makeClient(self: *TestContext, slot_index: u32) Client {
        var client: Client = undefined;
        client.allocator = self.allocator;
        client.pubsub_context = &self.context;
        client.slot_handle = .{ .slot_index = slot_index, .generation = 0 };
        client.is_in_pubsub_mode = false;
        client.subscription_count = 0;
        client.delivery_started = true;
        return client;
    }
};

test "subscribe writes one tuple per channel with a cumulative count" {
    var ctx: TestContext = undefined;
    try ctx.init(testing.allocator);
    defer ctx.deinit();

    var client = ctx.makeClient(0);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SUBSCRIBE" },
        .{ .data = "news" },
        .{ .data = "sports" },
    };
    try subscribe(&client, &args, &writer);

    try testing.expectEqualStrings(
        "*3\r\n$9\r\nsubscribe\r\n$4\r\nnews\r\n:1\r\n" ++
            "*3\r\n$9\r\nsubscribe\r\n$6\r\nsports\r\n:2\r\n",
        writer.buffered(),
    );
    try testing.expect(client.is_in_pubsub_mode);
    try testing.expectEqual(@as(usize, 2), client.subscription_count);
    try testing.expectEqual(@as(usize, 2), ctx.mock.subscriptions.items.len);
}

test "duplicate subscribe still replies and keeps the cumulative count" {
    var ctx: TestContext = undefined;
    try ctx.init(testing.allocator);
    defer ctx.deinit();

    var client = ctx.makeClient(0);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const args = [_]Value{ .{ .data = "SUBSCRIBE" }, .{ .data = "news" } };
    try subscribe(&client, &args, &writer);

    writer = .fixed(&buffer);
    try subscribe(&client, &args, &writer);

    try testing.expectEqualStrings("*3\r\n$9\r\nsubscribe\r\n$4\r\nnews\r\n:1\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 1), client.subscription_count);
    try testing.expectEqual(@as(usize, 1), ctx.mock.subscriptions.items.len);
}

test "subscribe maps channel and subscriber limit errors" {
    var ctx: TestContext = undefined;
    try ctx.init(testing.allocator);
    defer ctx.deinit();

    var first = ctx.makeClient(0);
    var second = ctx.makeClient(1);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const only_args = [_]Value{ .{ .data = "SUBSCRIBE" }, .{ .data = "only" } };
    try subscribe(&first, &only_args, &writer);
    try testing.expectEqual(@as(usize, 1), first.subscription_count);

    ctx.mock.next_error = error.ChannelLimitReached;
    writer = .fixed(&buffer);
    const other_args = [_]Value{ .{ .data = "SUBSCRIBE" }, .{ .data = "other" } };
    try subscribe(&first, &other_args, &writer);
    try testing.expectEqualStrings("-ERR maximum number of channels reached\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 1), first.subscription_count);

    ctx.mock.next_error = error.ChannelFull;
    writer = .fixed(&buffer);
    try subscribe(&second, &only_args, &writer);
    try testing.expectEqualStrings("-ERR maximum subscribers per channel reached\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 0), second.subscription_count);
}

test "publish frames the message and returns the receiver count" {
    var ctx: TestContext = undefined;
    try ctx.init(testing.allocator);
    defer ctx.deinit();

    ctx.mock.publish_return = 1;

    var publisher = ctx.makeClient(3);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const args = [_]Value{
        .{ .data = "PUBLISH" },
        .{ .data = "news" },
        .{ .data = "he\r\nllo" },
    };
    try publish(&publisher, &args, &writer);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 1), ctx.mock.published.items.len);
    try testing.expectEqualStrings("news", ctx.mock.published.items[0].channel);
    try testing.expectEqualStrings(
        "*3\r\n$7\r\nmessage\r\n$4\r\nnews\r\n$7\r\nhe\r\nllo\r\n",
        ctx.mock.published.items[0].payload,
    );

    // No subscribers: the handler still frames and sends the message.
    ctx.mock.publish_return = 0;
    writer = .fixed(&buffer);
    const empty_args = [_]Value{
        .{ .data = "PUBLISH" },
        .{ .data = "empty" },
        .{ .data = "nobody" },
    };
    try publish(&publisher, &empty_args, &writer);
    try testing.expectEqualStrings(":0\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 2), ctx.mock.published.items.len);
}

test "unsubscribe reports the remaining count and leaves pubsub mode" {
    var ctx: TestContext = undefined;
    try ctx.init(testing.allocator);
    defer ctx.deinit();

    var client = ctx.makeClient(0);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const subscribe_args = [_]Value{
        .{ .data = "SUBSCRIBE" },
        .{ .data = "alpha" },
        .{ .data = "beta" },
    };
    try subscribe(&client, &subscribe_args, &writer);

    writer = .fixed(&buffer);
    const unsubscribe_alpha = [_]Value{ .{ .data = "UNSUBSCRIBE" }, .{ .data = "alpha" } };
    try unsubscribe(&client, &unsubscribe_alpha, &writer);
    try testing.expectEqualStrings("*3\r\n$11\r\nunsubscribe\r\n$5\r\nalpha\r\n:1\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 1), client.subscription_count);
    try testing.expectEqual(@as(usize, 1), ctx.mock.subscriptions.items.len);

    writer = .fixed(&buffer);
    const unsubscribe_beta = [_]Value{ .{ .data = "UNSUBSCRIBE" }, .{ .data = "beta" } };
    try unsubscribe(&client, &unsubscribe_beta, &writer);
    try testing.expectEqualStrings("*3\r\n$11\r\nunsubscribe\r\n$4\r\nbeta\r\n:0\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 0), client.subscription_count);
    try testing.expect(!client.is_in_pubsub_mode);
    try testing.expectEqual(@as(usize, 0), ctx.mock.subscriptions.items.len);
}

test "unsubscribe with no subscriptions replies with a nil channel" {
    var ctx: TestContext = undefined;
    try ctx.init(testing.allocator);
    defer ctx.deinit();

    var client = ctx.makeClient(0);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const args = [_]Value{.{ .data = "UNSUBSCRIBE" }};
    try unsubscribe(&client, &args, &writer);

    try testing.expectEqualStrings("*3\r\n$11\r\nunsubscribe\r\n$-1\r\n:0\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 0), client.subscription_count);
}

test "unsubscribe with no arguments removes every channel" {
    var ctx: TestContext = undefined;
    try ctx.init(testing.allocator);
    defer ctx.deinit();

    var client = ctx.makeClient(0);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const subscribe_args = [_]Value{
        .{ .data = "SUBSCRIBE" },
        .{ .data = "alpha" },
        .{ .data = "beta" },
    };
    try subscribe(&client, &subscribe_args, &writer);

    writer = .fixed(&buffer);
    const args = [_]Value{.{ .data = "UNSUBSCRIBE" }};
    try unsubscribe(&client, &args, &writer);

    try testing.expectEqualStrings(
        "*3\r\n$11\r\nunsubscribe\r\n$5\r\nalpha\r\n:1\r\n" ++
            "*3\r\n$11\r\nunsubscribe\r\n$4\r\nbeta\r\n:0\r\n",
        writer.buffered(),
    );
    try testing.expectEqual(@as(usize, 0), client.subscription_count);
    try testing.expectEqual(@as(usize, 0), ctx.mock.subscriptions.items.len);
}
