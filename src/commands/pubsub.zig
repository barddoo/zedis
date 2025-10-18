const std = @import("std");
const Client = @import("../client.zig").Client;
const store = @import("../store.zig");
const ZedisValue = store.ZedisValue;
const Value = @import("../parser.zig").Value;
const Server = @import("../server.zig");
const resp = @import("../commands/resp.zig");

pub const PubSubContext = struct {
    server: *Server,

    pub fn init(server: *Server) PubSubContext {
        return PubSubContext{ .server = server };
    }

    pub fn ensureChannelExists(self: *PubSubContext, channel_name: []const u8) !void {
        return self.server.ensureChannelExists(channel_name);
    }

    pub fn subscribeToChannel(self: *PubSubContext, channel_name: []const u8, client_id: u64) !void {
        return self.server.subscribeToChannel(channel_name, client_id);
    }

    pub fn unsubscribeFromChannel(self: *PubSubContext, channel_name: []const u8, client_id: u64) !void {
        return self.server.unsubscribeFromChannel(channel_name, client_id);
    }

    pub fn getChannelSubscribers(self: *PubSubContext, channel_name: []const u8) []const u64 {
        return self.server.getChannelSubscribers(channel_name);
    }

    pub fn getChannelNames(self: *PubSubContext) std.StringHashMap([]u64).KeyIterator {
        return self.server.getChannelNames();
    }

    pub fn getChannelCount(self: *PubSubContext) u32 {
        return self.server.getChannelCount();
    }

    pub fn findClientById(self: *PubSubContext, client_id: u64) ?*Client {
        return self.server.findClientById(client_id);
    }
};

pub fn subscribe(client: *Client, args: []const Value) !void {
    var pubsub_context = client.pubsub_context;
    var sw = client.connection.stream.writer(&.{});
    const writer = &sw.interface;

    // Enter pubsub mode on first subscription
    if (!client.is_in_pubsub_mode) {
        client.enterPubSubMode();
    }

    var i: i64 = 0;
    for (args[1..]) |item| {
        const channel_name = item.asSlice();
        // Ensure channel exists
        pubsub_context.ensureChannelExists(channel_name) catch {
            try resp.writeError(writer, "ERR failed to create channel");
            continue;
        };

        // Subscribe client to channel
        pubsub_context.subscribeToChannel(channel_name, client.client_id) catch |err| switch (err) {
            error.ChannelFull => {
                try resp.writeError(writer, "ERR maximum subscribers per channel reached");
                continue;
            },
            else => {
                try resp.writeError(writer, "ERR failed to subscribe to channel");
                continue;
            },
        };

        const subscription_count = i + 1;

        const response_tuple = .{
            "subscribe",
            channel_name,
            subscription_count,
        };

        // Use a generic writer to send the tuple as a RESP array.
        try resp.writeTupleAsArray(writer, response_tuple);
        i += 1;
    }
}

pub fn publish(client: *Client, args: []const Value) !void {
    var pubsub_context = client.pubsub_context;
    const channel_name = args[1].asSlice();
    const message = args[2].asSlice();
    var messages_sent: i64 = 0;
    var sw = client.connection.stream.writer(&.{});
    const writer = &sw.interface;

    // Get subscribers for this channel
    const subscribers = pubsub_context.getChannelSubscribers(channel_name);

    if (subscribers.len > 0) {
        for (subscribers) |subscriber_id| {
            // Find the subscriber client and deliver the message
            if (pubsub_context.findClientById(subscriber_id)) |subscriber_client| {
                const message_tuple = .{
                    "message",
                    channel_name,
                    message,
                };

                var sc_sw = subscriber_client.connection.stream.writer(&.{});
                const sc_writer = &sc_sw.interface;
                // Try to deliver the message, but don't fail the entire publish if one delivery fails
                resp.writeTupleAsArray(sc_writer, message_tuple) catch |err| {
                    std.log.warn("Failed to deliver message to client {}: {s}", .{ subscriber_id, @errorName(err) });
                    continue;
                };

                messages_sent += 1;
            }
        }
    }

    try resp.writeInt(writer, messages_sent);
}

// Test imports
const testing = std.testing;
const MockClient = @import("../test_utils.zig").MockClient;
const MockServer = @import("../test_utils.zig").MockServer;
const MockPubSubContext = @import("../test_utils.zig").MockPubSubContext;
const Store = @import("../store.zig").Store;

// Test wrapper for publish command to work with MockClient
fn testPublish(client: *MockClient, args: []const Value) !void {
    const channel_name = args[1].data;
    const message = args[2].data;

    // Find channel
    const channels = client.pubsub_context.getChannelNames();
    var channel_id: ?u32 = null;
    for (channels[0..client.pubsub_context.getChannelCount()], 0..) |existing_name, i| {
        if (existing_name) |name| {
            if (std.mem.eql(u8, name, channel_name)) {
                channel_id = @intCast(i);
                break;
            }
        }
    }

    if (channel_id == null) {
        try client.writeInt(@as(u32, 0));
        return;
    }

    // Get subscribers
    const subscribers = client.pubsub_context.getChannelSubscribers(channel_id.?);

    // Send message to each subscriber
    for (subscribers) |subscriber_id| {
        const subscriber = client.pubsub_context.findClientById(subscriber_id);
        if (subscriber) |sub_client| {
            // Send the message as a 3-element array: ["message", channel, content]
            try sub_client.writeTupleAsArray(.{ "message", channel_name, message });
        }
    }

    // Return number of recipients
    try client.writeInt(@as(u32, @intCast(subscribers.len)));
}

// Test wrapper for subscribe command to work with MockClient
fn testSubscribe(client: *MockClient, args: []const Value) !void {
    // Handle multiple channels (args[1..])
    for (args[1..]) |channel_arg| {
        const channel_name = channel_arg.data;

        // Find or create channel
        const channel_id = client.pubsub_context.findOrCreateChannel(channel_name) orelse {
            try client.writeError("ERR maximum number of channels reached", .{});
            return;
        };

        // Subscribe client to channel
        client.pubsub_context.subscribeToChannel(channel_id, client.client_id) catch |err| switch (err) {
            error.ChannelFull => {
                try client.writeError("ERR maximum subscribers per channel reached", .{});
                return;
            },
            else => return err,
        };

        // Send subscription confirmation (channel name, total subscription count for client)
        // Redis returns the total number of channels this client is subscribed to
        var client_subscription_count: u64 = 0;
        for (0..client.pubsub_context.getChannelCount()) |i| {
            const subscribers = client.pubsub_context.getChannelSubscribers(@intCast(i));
            for (subscribers) |sub_id| {
                if (sub_id == client.client_id) {
                    client_subscription_count += 1;
                    break;
                }
            }
        }
        try client.writeTupleAsArray(.{ "subscribe", channel_name, client_subscription_count });
    }
}

test "PubSubContext - findOrCreateChannel creates new channels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    // Create first channel
    const channel_id_1 = context.findOrCreateChannel("news");
    try testing.expect(channel_id_1 != null);
    try testing.expectEqual(@as(u32, 0), channel_id_1.?);

    // Create second channel
    const channel_id_2 = context.findOrCreateChannel("sports");
    try testing.expect(channel_id_2 != null);
    try testing.expectEqual(@as(u32, 1), channel_id_2.?);

    // Find existing channel
    const channel_id_1_again = context.findOrCreateChannel("news");
    try testing.expect(channel_id_1_again != null);
    try testing.expectEqual(@as(u32, 0), channel_id_1_again.?);

    try testing.expectEqual(@as(u32, 2), context.getChannelCount());
}

test "PubSubContext - subscribe and unsubscribe clients" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    // Create channel
    const channel_id = context.findOrCreateChannel("test-channel").?;

    // Subscribe clients
    try context.subscribeToChannel(channel_id, 100);
    try context.subscribeToChannel(channel_id, 200);

    const subscribers = context.getChannelSubscribers(channel_id);
    try testing.expectEqual(@as(usize, 2), subscribers.len);
    try testing.expectEqual(@as(u64, 100), subscribers[0]);
    try testing.expectEqual(@as(u64, 200), subscribers[1]);

    // Unsubscribe one client
    context.unsubscribeFromChannel(channel_id, 100);
    const subscribers_after = context.getChannelSubscribers(channel_id);
    try testing.expectEqual(@as(usize, 1), subscribers_after.len);
    try testing.expectEqual(@as(u64, 200), subscribers_after[0]);
}

test "PubSubContext - duplicate subscription is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    const channel_id = context.findOrCreateChannel("test-channel").?;

    // Subscribe same client multiple times
    try context.subscribeToChannel(channel_id, 100);
    try context.subscribeToChannel(channel_id, 100);
    try context.subscribeToChannel(channel_id, 100);

    const subscribers = context.getChannelSubscribers(channel_id);
    try testing.expectEqual(@as(usize, 1), subscribers.len);
    try testing.expectEqual(@as(u64, 100), subscribers[0]);
}

test "PubSubContext - error conditions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    // Subscribe to invalid channel
    const result = context.subscribeToChannel(999, 100);
    try testing.expectError(error.InvalidChannel, result);

    // Test channel full condition by filling up a channel
    const channel_id = context.findOrCreateChannel("test-channel").?;
    var client_id: u64 = 1;
    while (client_id <= 16) : (client_id += 1) {
        try context.subscribeToChannel(channel_id, client_id);
    }

    // Next subscription should fail
    const full_result = context.subscribeToChannel(channel_id, 17);
    try testing.expectError(error.ChannelFull, full_result);
}

test "PubSubContext - find client by ID" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    // Create clients
    var client1 = MockClient.initWithId(100, allocator, &data_store, &context);
    defer client1.deinit();
    var client2 = MockClient.initWithId(200, allocator, &data_store, &context);
    defer client2.deinit();

    // Add clients to server
    try server.addClient(&client1);
    try server.addClient(&client2);

    // Find clients
    const found_client1 = context.findClientById(100);
    try testing.expect(found_client1 != null);
    try testing.expectEqual(@as(u64, 100), found_client1.?.client_id);

    const found_client2 = context.findClientById(200);
    try testing.expect(found_client2 != null);
    try testing.expectEqual(@as(u64, 200), found_client2.?.client_id);

    // Try to find non-existent client
    const not_found = context.findClientById(999);
    try testing.expect(not_found == null);
}

test "subscribe command - single channel subscription" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    var client = MockClient.initWithId(100, allocator, &data_store, &context);
    defer client.deinit();

    try server.addClient(&client);

    const args = [_]Value{
        Value{ .data = "SUBSCRIBE" },
        Value{ .data = "news" },
    };

    try testSubscribe(&client, &args);

    // Check response format: *3\r\n$9\r\nsubscribe\r\n$4\r\nnews\r\n:1\r\n
    const output = client.getOutput();
    try testing.expect(std.mem.indexOf(u8, output, "*3\r\n") != null); // Array of 3 elements
    try testing.expect(std.mem.indexOf(u8, output, "$9\r\nsubscribe\r\n") != null); // "subscribe"
    try testing.expect(std.mem.indexOf(u8, output, "$4\r\nnews\r\n") != null); // "news"
    try testing.expect(std.mem.indexOf(u8, output, ":1\r\n") != null); // subscription count

    // Verify client is subscribed
    const channel_id = context.findOrCreateChannel("news").?;
    const subscribers = context.getChannelSubscribers(channel_id);
    try testing.expectEqual(@as(usize, 1), subscribers.len);
    try testing.expectEqual(@as(u64, 100), subscribers[0]);
}

test "subscribe command - multiple channel subscriptions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    var client = MockClient.initWithId(100, allocator, &data_store, &context);
    defer client.deinit();

    try server.addClient(&client);

    const args = [_]Value{
        Value{ .data = "SUBSCRIBE" },
        Value{ .data = "news" },
        Value{ .data = "sports" },
        Value{ .data = "weather" },
    };

    try testSubscribe(&client, &args);

    const output = client.getOutput();

    // Should have responses for all three subscriptions
    // Each response should have subscription count increasing
    try testing.expect(std.mem.indexOf(u8, output, ":1\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, ":2\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, ":3\r\n") != null);

    // Verify all channels exist and client is subscribed
    const news_id = context.findOrCreateChannel("news").?;
    const sports_id = context.findOrCreateChannel("sports").?;
    const weather_id = context.findOrCreateChannel("weather").?;

    try testing.expectEqual(@as(usize, 1), context.getChannelSubscribers(news_id).len);
    try testing.expectEqual(@as(usize, 1), context.getChannelSubscribers(sports_id).len);
    try testing.expectEqual(@as(usize, 1), context.getChannelSubscribers(weather_id).len);
}

test "subscribe command - channel limit reached" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    var client = MockClient.initWithId(100, allocator, &data_store, &context);
    defer client.deinit();

    try server.addClient(&client);

    // Fill up all channels
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const channel_name = try std.fmt.allocPrint(allocator, "channel{d}", .{i});
        defer allocator.free(channel_name);
        _ = context.findOrCreateChannel(channel_name);
    }

    // Try to subscribe to one more channel
    const args = [_]Value{
        Value{ .data = "SUBSCRIBE" },
        Value{ .data = "overflow-channel" },
    };

    try testSubscribe(&client, &args);

    const output = client.getOutput();
    try testing.expect(std.mem.indexOf(u8, output, "ERR maximum number of channels reached") != null);
}

test "publish command - single subscriber" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    // Create publisher and subscriber clients
    var publisher = MockClient.initWithId(100, allocator, &data_store, &context);
    defer publisher.deinit();
    var subscriber = MockClient.initWithId(200, allocator, &data_store, &context);
    defer subscriber.deinit();

    try server.addClient(&publisher);
    try server.addClient(&subscriber);

    // Subscribe client to channel
    const channel_id = context.findOrCreateChannel("news").?;
    try context.subscribeToChannel(channel_id, 200);

    // Publish message
    const args = [_]Value{
        Value{ .data = "PUBLISH" },
        Value{ .data = "news" },
        Value{ .data = "Breaking news!" },
    };

    try testPublish(&publisher, &args);

    // Check publisher response (number of messages sent)
    const pub_output = publisher.getOutput();
    try testing.expect(std.mem.indexOf(u8, pub_output, ":1\r\n") != null);

    // Check subscriber received message
    const sub_output = subscriber.getOutput();
    try testing.expect(std.mem.indexOf(u8, sub_output, "*3\r\n") != null); // Array of 3 elements
    try testing.expect(std.mem.indexOf(u8, sub_output, "$7\r\nmessage\r\n") != null); // "message"
    try testing.expect(std.mem.indexOf(u8, sub_output, "$4\r\nnews\r\n") != null); // "news"
    try testing.expect(std.mem.indexOf(u8, sub_output, "$14\r\nBreaking news!\r\n") != null); // "Breaking news!" (14 chars)
}

test "publish command - multiple subscribers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    // Create publisher and multiple subscribers
    var publisher = MockClient.initWithId(100, allocator, &data_store, &context);
    defer publisher.deinit();
    var subscriber1 = MockClient.initWithId(200, allocator, &data_store, &context);
    defer subscriber1.deinit();
    var subscriber2 = MockClient.initWithId(300, allocator, &data_store, &context);
    defer subscriber2.deinit();
    var subscriber3 = MockClient.initWithId(400, allocator, &data_store, &context);
    defer subscriber3.deinit();

    try server.addClient(&publisher);
    try server.addClient(&subscriber1);
    try server.addClient(&subscriber2);
    try server.addClient(&subscriber3);

    // Subscribe all clients to the same channel
    const channel_id = context.findOrCreateChannel("broadcast").?;
    try context.subscribeToChannel(channel_id, 200);
    try context.subscribeToChannel(channel_id, 300);
    try context.subscribeToChannel(channel_id, 400);

    // Publish message
    const args = [_]Value{
        Value{ .data = "PUBLISH" },
        Value{ .data = "broadcast" },
        Value{ .data = "Hello everyone!" },
    };

    try testPublish(&publisher, &args);

    // Check publisher response (should be 3 messages sent)
    const pub_output = publisher.getOutput();
    try testing.expect(std.mem.indexOf(u8, pub_output, ":3\r\n") != null);

    // Check all subscribers received the message
    const sub1_output = subscriber1.getOutput();
    const sub2_output = subscriber2.getOutput();
    const sub3_output = subscriber3.getOutput();

    for ([_][]const u8{ sub1_output, sub2_output, sub3_output }) |output| {
        try testing.expect(std.mem.indexOf(u8, output, "*3\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, output, "$7\r\nmessage\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, output, "$9\r\nbroadcast\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, output, "$15\r\nHello everyone!\r\n") != null);
    }
}

test "publish command - non-existent channel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    var publisher = MockClient.initWithId(100, allocator, &data_store, &context);
    defer publisher.deinit();

    try server.addClient(&publisher);

    // Publish to non-existent channel
    const args = [_]Value{
        Value{ .data = "PUBLISH" },
        Value{ .data = "non-existent" },
        Value{ .data = "No one will see this" },
    };

    try testPublish(&publisher, &args);

    // Should return 0 messages sent
    const pub_output = publisher.getOutput();
    try testing.expect(std.mem.indexOf(u8, pub_output, ":0\r\n") != null);
}

test "publish command - empty channel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    var publisher = MockClient.initWithId(100, allocator, &data_store, &context);
    defer publisher.deinit();

    try server.addClient(&publisher);

    // Create channel but don't subscribe anyone
    _ = context.findOrCreateChannel("empty-channel");

    // Publish to empty channel
    const args = [_]Value{
        Value{ .data = "PUBLISH" },
        Value{ .data = "empty-channel" },
        Value{ .data = "No subscribers" },
    };

    try testPublish(&publisher, &args);

    // Should return 0 messages sent
    const pub_output = publisher.getOutput();
    try testing.expect(std.mem.indexOf(u8, pub_output, ":0\r\n") != null);
}

test "subscriber limit per channel error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data_store = Store.init(allocator, 4096);
    defer data_store.deinit();

    var server = MockServer.init(allocator);
    defer server.deinit();

    var context = MockPubSubContext.init(&server);

    // Fill channel to capacity
    const channel_id = context.findOrCreateChannel("full-channel").?;
    var client_id: u64 = 1;
    while (client_id <= 16) : (client_id += 1) {
        try context.subscribeToChannel(channel_id, client_id);
    }

    // Try to subscribe one more
    var client = MockClient.initWithId(17, allocator, &data_store, &context);
    defer client.deinit();

    const args = [_]Value{
        Value{ .data = "SUBSCRIBE" },
        Value{ .data = "full-channel" },
    };

    try testSubscribe(&client, &args);
    const output = client.getOutput();
    try testing.expect(std.mem.indexOf(u8, output, "ERR maximum subscribers per channel reached") != null);
}
