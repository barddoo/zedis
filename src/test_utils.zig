// const std = @import("std");
// const Store = @import("store.zig").Store;
// const Value = @import("parser.zig").Value;
// const PrimitiveValue = @import("store.zig").PrimitiveValue;

// pub const MockClient = struct {
//     client_id: u64,
//     allocator: std.mem.Allocator,
//     store: *Store,
//     pubsub_context: *MockPubSubContext,
//     output: std.ArrayList(u8),

//     pub fn init(allocator: std.mem.Allocator, store: *Store, pubsub_context: *MockPubSubContext) MockClient {
//         return MockClient{
//             .client_id = 1,
//             .allocator = allocator,
//             .store = store,
//             .pubsub_context = pubsub_context,
//             .output = std.ArrayList(u8).initCapacity(allocator, 10),
//         };
//     }

//     // Legacy init for existing tests (without pubsub functionality)
//     pub fn initLegacy(allocator: std.mem.Allocator, store: *Store) MockClient {
//         // Create a dummy pubsub context for legacy tests
//         var dummy_server = MockServer{
//             .allocator = allocator,
//             .channels = [_]?[]const u8{null} ** 8,
//             .subscribers = [_][16]u64{[_]u64{0} ** 16} ** 8,
//             .subscriber_counts = [_]u32{0} ** 8,
//             .clients = std.ArrayList(*MockClient).initCapacity(allocator, 10),
//             .channel_count = 0,
//         };

//         var dummy_context = MockPubSubContext.init(&dummy_server);

//         return MockClient{
//             .client_id = 1,
//             .allocator = allocator,
//             .store = store,
//             .pubsub_context = &dummy_context,
//             .output = std.ArrayList(u8).initCapacity(allocator, 10),
//         };
//     }

//     pub fn initWithId(client_id: u64, allocator: std.mem.Allocator, store: *Store, pubsub_context: *MockPubSubContext) MockClient {
//         return MockClient{
//             .client_id = client_id,
//             .allocator = allocator,
//             .store = store,
//             .pubsub_context = pubsub_context,
//             .output = std.ArrayList(u8).initCapacity(allocator, 10),
//         };
//     }

//     pub fn deinit(self: *MockClient) void {
//         self.output.deinit();
//     }

//     pub fn writeBulkString(self: *MockClient, str: []const u8) !void {
//         try self.output.writer().print("${d}\r\n{s}\r\n", .{ str.len, str });
//     }

//     pub fn writeNull(self: *MockClient) !void {
//         try self.output.appendSlice(self.allocator, "$-1\r\n");
//     }

//     pub fn writeError(self: *MockClient, comptime fmt: []const u8, args: anytype) !void {
//         try self.output.appendSlice(self.allocator, "-");
//         try self.output.writer().print(fmt, args);
//         try self.output.appendSlice(self.allocator, "\r\n");
//     }

//     pub fn writeInt(self: *MockClient, num: anytype) !void {
//         try self.output.writer().print(":{d}\r\n", .{num});
//     }

//     pub fn writePrimitiveValue(self: *MockClient, value: PrimitiveValue) !void {
//         switch (value) {
//             .string => |s| try self.writeBulkString(s),
//             .int => |i| try self.writeIntAsString(i),
//         }
//     }

//     pub fn getOutput(self: *MockClient) []const u8 {
//         return self.output.items;
//     }

//     pub fn testDecrby(self: *MockClient, args: []const Value) !void {
//         const key = args[1].asSlice();
//         const decrement = args[2].asInt() catch {
//             try self.writeError("ERR value is not an integer or out of range", .{});
//             return;
//         };

//         const current_value = self.store.get(key);
//         var new_value: i64 = -decrement;

//         if (current_value) |v| {
//             switch (v.value) {
//                 .string => |s| {
//                     const int_val = std.fmt.parseInt(i64, s, 10) catch {
//                         try self.writeError("ERR value is not an integer or out of range", .{});
//                         return;
//                     };
//                     new_value = std.math.sub(i64, int_val, decrement) catch {
//                         try self.writeError("ERR value is not an integer or out of range", .{});
//                         return;
//                     };
//                 },
//                 .short_string => |ss| {
//                     const int_val = std.fmt.parseInt(i64, ss.asSlice(), 10) catch {
//                         try self.writeError("ERR value is not an integer or out of range", .{});
//                         return;
//                     };
//                     new_value = std.math.sub(i64, int_val, decrement) catch {
//                         try self.writeError("ERR value is not an integer or out of range", .{});
//                         return;
//                     };
//                 },
//                 .int => |i| {
//                     new_value = std.math.sub(i64, i, decrement) catch {
//                         try self.writeError("ERR value is not an integer or out of range", .{});
//                         return;
//                     };
//                 },
//                 .list => {
//                     try self.writeError("WRONGTYPE Operation against a key holding the wrong kind of value", .{});
//                     return;
//                 },
//             }
//         }

//         try self.store.setInt(key, new_value);
//         const result_str = try std.fmt.allocPrint(self.allocator, "{d}", .{new_value});
//         defer self.allocator.free(result_str);
//         try self.writeBulkString(result_str);
//     }

//     // List command test methods
//     pub fn writeListLen(self: *MockClient, count: usize) !void {
//         try self.output.writer().print("*{d}\r\n", .{count});
//     }

//     pub fn writeIntAsString(self: *MockClient, i: i64) !void {
//         var buf: [21]u8 = undefined; // Enough for i64
//         const int_str = try std.fmt.bufPrint(&buf, "{}", .{i});
//         try self.writeBulkString(int_str);
//     }

//     pub fn writeTupleAsArray(self: *MockClient, items: anytype) !void {
//         const fields = std.meta.fields(@TypeOf(items));
//         try self.output.writer().print("*{d}\r\n", .{fields.len});

//         inline for (fields) |field| {
//             const value = @field(items, field.name);
//             switch (@TypeOf(value)) {
//                 []const u8 => try self.writeBulkString(value),
//                 i64, u64, u32, i32 => try self.output.writer().print(":{d}\r\n", .{value}),
//                 else => {
//                     // Handle string literals like *const [N:0]u8
//                     const TypeInfo = @typeInfo(@TypeOf(value));
//                     switch (TypeInfo) {
//                         .pointer => |ptr_info| {
//                             // Handle both *const [N:0]u8 and []const u8 types
//                             const child_info = @typeInfo(ptr_info.child);
//                             if (ptr_info.child == u8 or (child_info == .array and child_info.array.child == u8)) {
//                                 try self.writeBulkString(value);
//                             } else {
//                                 @compileError("Unsupported tuple field type: " ++ @typeName(@TypeOf(value)));
//                             }
//                         },
//                         else => @compileError("Unsupported tuple field type: " ++ @typeName(@TypeOf(value))),
//                     }
//                 },
//             }
//         }
//     }
// };

// // MockServer for testing PubSub functionality
// pub const MockServer = struct {
//     allocator: std.mem.Allocator,
//     channels: [8]?[]const u8, // Channel names (reduced for tests)
//     subscribers: [8][16]u64, // Subscriber lists per channel (reduced for tests)
//     subscriber_counts: [8]u32, // Number of subscribers per channel
//     clients: std.ArrayList(*MockClient), // List of connected clients
//     channel_count: u32,

//     pub fn init(allocator: std.mem.Allocator) MockServer {
//         return MockServer{
//             .allocator = allocator,
//             .channels = [_]?[]const u8{null} ** 8,
//             .subscribers = [_][16]u64{[_]u64{0} ** 16} ** 8,
//             .subscriber_counts = [_]u32{0} ** 8,
//             .clients = .initCapacity(allocator, 10),
//             .channel_count = 0,
//         };
//     }

//     pub fn deinit(self: *MockServer) void {
//         // Free allocated channel names
//         for (self.channels) |channel| {
//             if (channel) |name| {
//                 self.allocator.free(name);
//             }
//         }
//         self.clients.deinit(self.allocator);
//     }

//     pub fn addClient(self: *MockServer, client: *MockClient) !void {
//         try self.clients.append(self.allocator, client);
//     }

//     pub fn findOrCreateChannel(self: *MockServer, channel_name: []const u8) ?u32 {
//         // Check if channel already exists
//         for (self.channels[0..self.channel_count], 0..) |existing_name, i| {
//             if (existing_name) |name| {
//                 if (std.mem.eql(u8, name, channel_name)) {
//                     return @intCast(i);
//                 }
//             }
//         }

//         // Create new channel if we have space
//         if (self.channel_count >= self.channels.len) {
//             return null; // Maximum channels reached
//         }

//         const owned_name = self.allocator.dupe(u8, channel_name) catch return null;
//         self.channels[self.channel_count] = owned_name;
//         const channel_id = self.channel_count;
//         self.channel_count += 1;
//         return channel_id;
//     }

//     pub fn subscribeToChannel(self: *MockServer, channel_id: u32, client_id: u64) !void {
//         if (channel_id >= self.channel_count) return error.InvalidChannel;

//         const current_count = self.subscriber_counts[channel_id];
//         if (current_count >= self.subscribers[channel_id].len) {
//             return error.ChannelFull;
//         }

//         // Check if already subscribed
//         for (self.subscribers[channel_id][0..current_count]) |existing_id| {
//             if (existing_id == client_id) return; // Already subscribed
//         }

//         self.subscribers[channel_id][current_count] = client_id;
//         self.subscriber_counts[channel_id] += 1;
//     }

//     pub fn unsubscribeFromChannel(self: *MockServer, channel_id: u32, client_id: u64) void {
//         if (channel_id >= self.channel_count) return;

//         const current_count = self.subscriber_counts[channel_id];
//         var i: u32 = 0;
//         while (i < current_count) : (i += 1) {
//             if (self.subscribers[channel_id][i] == client_id) {
//                 // Move last subscriber to this position
//                 if (i < current_count - 1) {
//                     self.subscribers[channel_id][i] = self.subscribers[channel_id][current_count - 1];
//                 }
//                 self.subscriber_counts[channel_id] -= 1;
//                 return;
//             }
//         }
//     }

//     pub fn getChannelSubscribers(self: *MockServer, channel_id: u32) []const u64 {
//         if (channel_id >= self.channel_count) return &[_]u64{};
//         return self.subscribers[channel_id][0..self.subscriber_counts[channel_id]];
//     }

//     pub fn getChannelNames(self: *MockServer) []const ?[]const u8 {
//         return &self.channels;
//     }

//     pub fn getChannelCount(self: *MockServer) u32 {
//         return self.channel_count;
//     }

//     pub fn findClientById(self: *MockServer, client_id: u64) ?*MockClient {
//         for (self.clients.items) |client| {
//             if (client.client_id == client_id) {
//                 return client;
//             }
//         }
//         return null;
//     }
// };

// // MockPubSubContext that wraps MockServer
// pub const MockPubSubContext = struct {
//     server: *MockServer,

//     pub fn init(server: *MockServer) MockPubSubContext {
//         return MockPubSubContext{ .server = server };
//     }

//     pub fn findOrCreateChannel(self: *MockPubSubContext, channel_name: []const u8) ?u32 {
//         return self.server.findOrCreateChannel(channel_name);
//     }

//     pub fn subscribeToChannel(self: *MockPubSubContext, channel_id: u32, client_id: u64) !void {
//         return self.server.subscribeToChannel(channel_id, client_id);
//     }

//     pub fn unsubscribeFromChannel(self: *MockPubSubContext, channel_id: u32, client_id: u64) void {
//         self.server.unsubscribeFromChannel(channel_id, client_id);
//     }

//     pub fn getChannelSubscribers(self: *MockPubSubContext, channel_id: u32) []const u64 {
//         return self.server.getChannelSubscribers(channel_id);
//     }

//     pub fn getChannelNames(self: *MockPubSubContext) []const ?[]const u8 {
//         return self.server.getChannelNames();
//     }

//     pub fn getChannelCount(self: *MockPubSubContext) u32 {
//         return self.server.getChannelCount();
//     }

//     pub fn findClientById(self: *MockPubSubContext, client_id: u64) ?*MockClient {
//         return self.server.findClientById(client_id);
//     }
// };
