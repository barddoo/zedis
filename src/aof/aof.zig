const std = @import("std");
const Parser = @import("../parser.zig");
const Command = @import("../parser.zig").Command;
const Registry = @import("../commands/registry.zig").CommandRegistry;
const Client = @import("../client.zig").Client;
const Store = @import("../store.zig").Store;
const resp = @import("../commands/resp.zig");
const Value = @import("../parser.zig").Value;
const Io = std.Io;
const Dir = Io.Dir;
const Clock = @import("../clock.zig");
const Allocator = std.mem.Allocator;

pub const Writer = struct {
    enabled: bool,
    file_writer: ?Io.File.Writer,
    write_buffer: ?[]u8,
    io: Io,
    filename: []const u8,
    allocator: Allocator,
    fsync_policy: FsyncPolicy,
    last_fsync_ms: i64 = 0,

    pub const FsyncPolicy = enum { always, everysec, no };

    pub fn init(alloc: Allocator, io: Io, enabled: bool, filename: []const u8, work_dir: []const u8, buffer_size: usize, fsync_policy: FsyncPolicy) !Writer {
        var file_writer: ?Io.File.Writer = null;
        var write_buffer: ?[]u8 = null;
        if (enabled) {
            Dir.cwd().createDir(io, work_dir, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            const dir = try Dir.cwd().openDir(io, work_dir, .{});

            const file = dir.openFile(io, filename, .{ .mode = .write_only }) catch
                try dir.createFile(io, filename, .{});
            const buf = try alloc.alloc(u8, buffer_size);
            errdefer alloc.free(buf);
            var fw = file.writer(io, buf);
            const length = try file.length(io);
            try fw.seekTo(length);
            file_writer = fw;
            write_buffer = buf;
        }
        return .{
            .enabled = enabled,
            .file_writer = file_writer,
            .write_buffer = write_buffer,
            .io = io,
            .filename = filename,
            .allocator = alloc,
            .fsync_policy = fsync_policy,
        };
    }

    pub fn deinit(self: *Writer) void {
        if (self.write_buffer) |buf| {
            self.allocator.free(buf);
        }
        if (self.file_writer) |fw| {
            fw.file.close(self.io);
        }
    }

    /// Encode command args as RESP and write to the AOF file.
    /// Called outside the store_mutex critical section — zio makes file I/O async,
    /// suspending the coroutine instead of blocking the OS thread.
    pub fn writeCommand(self: *Writer, args: []const Value) void {
        if (!self.enabled) return;
        resp.writeListLen(self.writer(), args.len) catch return;
        for (args) |arg| {
            resp.writeBulkString(self.writer(), arg.asSlice()) catch return;
        }

        switch (self.fsync_policy) {
            .always => {
                _ = self.file_writer.?.interface.flush() catch {};
                self.file_writer.?.file.sync(self.io) catch {};
            },
            .everysec => {
                const now_ms = Io.Timestamp.now(self.io, .awake).toMilliseconds();
                if (now_ms - self.last_fsync_ms >= 1000) {
                    _ = self.file_writer.?.interface.flush() catch {};
                    self.file_writer.?.file.sync(self.io) catch {};
                    self.last_fsync_ms = now_ms;
                }
            },
            .no => {},
        }
    }

    pub fn writer(self: *Writer) *Io.Writer {
        return &self.file_writer.?.interface;
    }
};

pub const Reader = struct {
    file_reader: Io.File.Reader,
    allocator: Allocator,
    store: *Store,
    registry: *Registry,
    reader_buffer: [8192]u8 = undefined,
    io: Io,

    pub fn init(allocator: Allocator, store: *Store, registry: *Registry, io: Io, work_dir: []const u8, filename: []const u8) !Reader {
        const dir = try Dir.cwd().openDir(io, work_dir, .{});
        const file = try dir.openFile(io, filename, .{ .mode = .read_only });
        var result = Reader{
            .file_reader = undefined,
            .allocator = allocator,
            .store = store,
            .registry = registry,
            .io = io,
        };
        result.file_reader = file.reader(io, &result.reader_buffer);
        return result;
    }

    pub fn read(self: *Reader) !void {
        var parser = Parser.init(self.allocator);
        var commands = try std.ArrayList(Command).initCapacity(self.allocator, 128);
        defer commands.deinit(self.allocator);

        while (parser.parse(&self.file_reader.interface)) |command| {
            try commands.append(self.allocator, command);
        } else |_| {}

        for (commands.items) |command| {
            try self.registry.executeCommandAof(self.store, command.getArgs());
        }

        for (commands.items) |*command| {
            command.deinit();
        }

        self.file_reader.file.close(self.io);
    }
};

const testing = std.testing;
test "aof reading test" {
    const reg_init = @import("../commands/init.zig");

    // Read a command and test that the value is stored as expected
    const test_file_data = "*3\r\n$3\r\nset\r\n$1\r\nt\r\n$4\r\ntest\r\n";
    const cwd = Dir.cwd();
    const test_file = try cwd.createFile(testing.io, "aof_reading_test.aof", .{ .read = true });
    defer cwd.deleteFile(testing.io, "aof_reading_test.aof") catch {};
    var test_file_writer = test_file.writer(testing.io, &.{});
    try test_file_writer.interface.writeAll(test_file_data);

    var registry = try reg_init.initRegistry(std.testing.allocator);
    defer registry.deinit();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var reader_buffer: [8192]u8 = undefined;
    var aof_reader: Reader = undefined;
    aof_reader.allocator = testing.allocator;
    aof_reader.file_reader = test_file.reader(testing.io, &reader_buffer);
    aof_reader.store = &store;
    aof_reader.registry = &registry;
    aof_reader.io = testing.io;

    try aof_reader.read();

    try testing.expect(std.mem.eql(u8, store.get("t").?.value.short_string.asSlice(), "test"));
}
test "aof writing test" {
    const reg_init = @import("../commands/init.zig");

    // Execute a command and test that it writes it correctly
    const test_file_name = "aof_writing_test.aof";
    const cwd = Dir.cwd();
    const test_file = try cwd.createFile(testing.io, test_file_name, .{ .read = true });
    defer cwd.deleteFile(testing.io, "aof_writing_test.aof") catch {};

    const test_file_data = "*3\r\n$3\r\nSET\r\n$1\r\nt\r\n$4\r\ntest\r\n";

    var registry = try reg_init.initRegistry(std.testing.allocator);
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    var parser = Parser.init(testing.allocator);
    defer registry.deinit();
    defer store.deinit();

    var reader = Io.Reader.fixed(test_file_data);
    var cmd = try parser.parse(&reader);
    defer cmd.deinit();

    var discarding = Io.Writer.Discarding.init(&.{});

    var dummy_client: Client = undefined;
    dummy_client.authenticated = true;

    // Execute command (mutates store, no AOF write)
    try registry.executeCommand(&discarding.writer, &dummy_client, &store, cmd.getArgs());
    try testing.expect(std.mem.eql(u8, store.get("t").?.value.short_string.asSlice(), "test"));

    // Write AOF separately (simulating what server.writeAof does)
    var aof_writer: Writer = undefined;
    aof_writer.enabled = true;
    aof_writer.file_writer = test_file.writer(testing.io, &.{});
    aof_writer.io = testing.io;
    aof_writer.filename = &.{};
    aof_writer.allocator = testing.allocator;
    aof_writer.write_buffer = null;
    aof_writer.writeCommand(cmd.getArgs());

    _ = aof_writer.file_writer.?.interface.flush() catch {};

    var file_reader_buffer: [8192]u8 = undefined;
    var file_reader = test_file.reader(testing.io, &file_reader_buffer);

    const buf = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(buf);
    file_reader.interface.readSliceAll(buf) catch |e| {
        if (e != error.EndOfStream) {
            return e;
        }
    };
    try testing.expect(std.mem.eql(u8, buf[0..test_file_data.len], test_file_data));
}
