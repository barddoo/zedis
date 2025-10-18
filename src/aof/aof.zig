const std = @import("std");
const Server = @import("../server.zig");
const Parser = @import("../parser.zig").Parser;
const Command = @import("../parser.zig").Command;
const Registry = @import("../commands/registry.zig").CommandRegistry;
const Client = @import("../client.zig").Client;
const Store = @import("../store.zig").Store;

const DEFAULT_NAME = "test.aof";

// TODO: AOF Rewrite
// Get the state of the store at the time of rewrite, and create
// the necessary commands to replicate it.

pub const Writer = struct {
    enabled: bool,
    file_writer: ?std.fs.File.Writer,

    // take path when ready to
    pub fn init(enabled: bool) !Writer {
        var fw: std.fs.File.Writer = undefined;
        if (enabled) {
            const file = std.fs.cwd().openFile(DEFAULT_NAME, .{ .mode = .write_only }) catch
                try std.fs.cwd().createFile(DEFAULT_NAME, .{});
            fw = file.writer(&.{});
            try fw.seekTo(try file.getEndPos());
        }
        return .{
            .enabled = enabled,
            .file_writer = if (enabled) fw else null,
        };
    }

    pub fn deinit(self: *Writer) void {
        if (self.file_writer) |fw| {
            fw.file.close();
        }
    }

    // only to be called if enabled
    pub fn writer(self: *Writer) *std.Io.Writer {
        return &self.file_writer.?.interface;
    }
};

pub const Reader = struct {
    file_reader: std.fs.File.Reader,
    allocator: std.mem.Allocator,
    store: *Store,
    registry: *Registry,

    // take path when ready to
    pub fn init(allocator: std.mem.Allocator, store: *Store, registry: *Registry) !Reader {
        const file = try std.fs.cwd().openFile(DEFAULT_NAME, .{ .mode = .read_only });
        const reader = file.reader(&.{});
        return .{
            .file_reader = reader,
            .allocator = allocator,
            .store = store,
            .registry = registry,
        };
    }

    pub fn read(self: *Reader) !void {
        var parser = Parser.init(self.allocator);
        var commands = try std.ArrayList(Command).initCapacity(self.allocator, 128);
        defer commands.deinit(self.allocator);

        while (parser.parse(&self.file_reader.interface)) |command| {
            try commands.append(self.allocator, command);
        } else |_| {}

        for (commands.items) |command| {
            try self.registry.executeCommandAof(self.store, command.args.items);
        }

        for (commands.items) |*command| {
            command.deinit();
        }

        self.file_reader.file.close();
    }
};

test "aof reading test" {
    const testing = std.testing;
    const reg_init = @import("../commands/init.zig");

    // Read a command and test that the value is stored as expected
    const test_file_data = "*3\r\n$3\r\nset\r\n$1\r\nt\r\n$4\r\ntest\r\n";
    const test_file = try std.fs.cwd().createFile("aof_reading_test.aof", .{ .read = true });
    defer std.fs.cwd().deleteFile("aof_reading_test.aof") catch {};
    try test_file.writeAll(test_file_data);

    var registry = try reg_init.initRegistry(std.testing.allocator);
    defer registry.deinit();
    var store: Store = .init(testing.allocator, 4096);
    defer store.deinit();

    var aof_reader: Reader = undefined;
    aof_reader.allocator = testing.allocator;
    aof_reader.file_reader = test_file.reader(&.{});
    aof_reader.store = &store;
    aof_reader.registry = &registry;

    try aof_reader.read();

    try testing.expect(std.mem.eql(u8, store.get("t").?.value.short_string.asSlice(), "test"));
}
test "aof writing test" {
    const testing = std.testing;
    const reg_init = @import("../commands/init.zig");

    // Execute a command and test that it writes it correctly
    const test_file_name = "aof_writing_test.aof";
    const test_file = try std.fs.cwd().createFile(test_file_name, .{ .read = true });
    defer std.fs.cwd().deleteFile("aof_writing_test.aof") catch {};

    const test_file_data = "*3\r\n$3\r\nSET\r\n$1\r\nt\r\n$4\r\ntest\r\n";

    var registry = try reg_init.initRegistry(std.testing.allocator);
    var store: Store = .init(testing.allocator, 4096);
    var parser = Parser.init(testing.allocator);
    defer registry.deinit();
    defer store.deinit();

    var reader = std.Io.Reader.fixed(test_file_data);
    var cmd = try parser.parse(&reader);
    defer cmd.deinit();

    const discarding = std.Io.Writer.Discarding.init(&.{});
    var writer = discarding.writer;

    var dummy_client: Client = undefined;
    dummy_client.authenticated = true;

    var aof_writer: Writer = undefined;
    aof_writer.file_writer = test_file.writer(&.{});
    aof_writer.enabled = true;

    try registry.executeCommand(&writer, &dummy_client, &store, &aof_writer, cmd.args.items);

    var file_reader = test_file.reader(&.{});

    try testing.expect(std.mem.eql(u8, store.get("t").?.value.short_string.asSlice(), "test"));
    const buf = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(buf);
    file_reader.interface.readSliceAll(buf) catch |e| {
        if (e != error.EndOfStream) {
            return e;
        }
    };
    try testing.expect(std.mem.eql(u8, buf[0..test_file_data.len], test_file_data));
}
