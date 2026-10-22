const std = @import("std");
const banner = @import("banner.zig");
const Server = @import("server.zig");
const Client = @import("client.zig").Client;
const ClientMailbox = @import("client_mailbox.zig").ClientMailbox;
const StackWriter = @import("stack_writer.zig").StackWriter;
const Config = @import("config.zig");
const Parser = @import("parser.zig").Value;

const io = std.Io;

/// Round-trip a single command through the real dispatch path
/// (parse-free: pre-built RESP values -> registry.execute_command ->
/// response writer) exactly as a client coroutine does after parsing, but
/// without any socket I/O. This isolates the cost of inline command execution
/// under the store lock — the path that used to bounce through a dedicated
/// store thread (~3.6us/op measured previously).
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const server_io = init.io;

    var cfg = Config{};
    cfg.port = 0; // ephemeral, never accepted on
    cfg.clock_update_ms = 0; // no background clock task; keep bench deterministic
    cfg.dir = "./zig-cache/bench-inline";
    cfg.appendfilename = "bench-inline.aof";
    cfg.max_clients = 64; // keep the fixed client-slot pool small in this process

    const server = try Server.init_with_config(allocator, "127.0.0.1", cfg.port, cfg, server_io);
    defer {
        server.deinit();
        allocator.destroy(server);
    }

    // The client's socket is never used by the commands we benchmark; a dummy
    // stream is enough to satisfy the Client type.
    const dummy_connection: io.net.Stream = .{ .socket = .{ .handle = -1, .address = undefined } };
    var mb = ClientMailbox.init(16);
    var disconnect = std.atomic.Value(bool).init(false);

    var client = Client.init(
        allocator,
        dummy_connection,
        &server.pubsub_context,
        &server.registry,
        server,
        &server.store,
        .{ .slot_index = 0, .generation = 0 },
        &mb,
        &disconnect,
        server_io,
    );

    const ping_args = [_]Parser{.{ .data = "PING" }};
    const get_args = [_]Parser{ .{ .data = "GET" }, .{ .data = "bench:key" } };
    const set_args = [_]Parser{ .{ .data = "SET" }, .{ .data = "bench:key" }, .{ .data = "bench:value:0123456789abcdef" } };

    // Prime the key for GET.
    {
        var sw = StackWriter.init(allocator);
        defer sw.deinit();
        const w = sw.writer();
        server.execute_command(&client, &set_args, w);
    }

    std.debug.print("\n", .{});
    std.debug.print("{s}\n", .{&banner.repeat("=", 72)});
    std.debug.print("          INLINE COMMAND EXECUTION (no store thread)\n", .{});
    std.debug.print("{s}\n\n", .{&banner.repeat("=", 72)});

    run(server_io, &client, "PING   ", &ping_args, 5_000_000);
    run(server_io, &client, "GET    ", &get_args, 3_000_000);
    run(server_io, &client, "SET    ", &set_args, 2_000_000);
}

fn run(server_io: io, client: *Client, label: []const u8, args: []const Parser, iterations: usize) void {
    // Warmup.
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var sw = StackWriter.init(std.heap.smp_allocator);
        defer sw.deinit();
        const w = sw.writer();
        client.server.execute_command(client, args, w);
    }

    const start = std.Io.Clock.Timestamp.now(server_io, .awake);
    i = 0;
    while (i < iterations) : (i += 1) {
        var sw = StackWriter.init(std.heap.smp_allocator);
        defer sw.deinit();
        const w = sw.writer();
        client.server.execute_command(client, args, w);
    }

    const end = std.Io.Clock.Timestamp.now(server_io, .awake);
    const elapsed_ns: u64 = @intCast(start.raw.durationTo(end.raw).nanoseconds);
    const ns_per_op = elapsed_ns / iterations;
    const kops_per_sec = @as(f64, @floatFromInt(1_000_000 * iterations)) / @as(f64, @floatFromInt(elapsed_ns));

    std.debug.print("{s}  {d:>10} ns/op   {d:>12.1} K ops/s\n", .{
        label,
        ns_per_op,
        kops_per_sec,
    });
}
