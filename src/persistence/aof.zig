const std = @import("std");
const Parser = @import("../protocol/parser.zig");
const Command = @import("../protocol/parser.zig").Command;
const Registry = @import("../commands/registry.zig").CommandRegistry;
const Client = @import("../app/client.zig").Client;
const Store = @import("../storage/store.zig").Store;
const resp = @import("../protocol/resp.zig");
const Value = @import("../protocol/parser.zig").Value;
const Io = std.Io;
const Dir = Io.Dir;
const Clock = @import("../app/clock.zig");
const Allocator = std.mem.Allocator;
const zio = @import("zio");

const log = std.log.scoped(.aof);

fn lock_spin(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Append-only file writer. Commands are encoded into an in-memory queue while
/// they execute; a dedicated OS thread writes the queue to disk and fsyncs
/// according to `fsync_policy`, so file I/O never runs on the event loop or
/// during command execution.
///
/// With `always`, a client must call `wait_durable` with the offset returned by
/// `write_command` before replying. One fsync covers every command queued while
/// the previous one ran (group commit).
pub const Writer = struct {
    enabled: bool,
    fsync_policy: FsyncPolicy = .no,
    allocator: Allocator = undefined,
    /// State shared with the writer thread. Heap-allocated so its address stays
    /// fixed while the thread runs; null when disabled.
    shared: ?*Shared = null,

    pub const FsyncPolicy = enum { always, everysec, no };

    const Shared = struct {
        allocator: Allocator,
        file: Io.File,
        fsync_policy: FsyncPolicy,
        /// Blocking I/O for the writer thread, independent of the zio runtime.
        threaded: Io.Threaded,
        thread: std.Thread = undefined,

        /// Guards `queued`, `queued_end` and `stopping`. Held briefly: by command
        /// execution to append, by the writer thread to take the queue. A
        /// spinlock rather than `zio.Mutex`: command execution must not suspend,
        /// because the store has no lock and another client's command must not
        /// interleave with a half-executed one.
        mutex: std.atomic.Mutex = .unlocked,
        /// Encoded commands the writer thread has not taken yet.
        queued: std.ArrayList(u8) = .empty,
        /// File offset at the end of `queued`.
        queued_end: u64,
        stopping: bool = false,
        /// Futex word bumped on every append and on stop; the writer thread waits on it.
        wake_seq: std.atomic.Value(u32) = .init(0),

        /// File offset up to which data is written, and under `always` also fsynced.
        durable_end: std.atomic.Value(u64),
        /// Futex word bumped whenever `durable_end` advances or a failure is recorded.
        durable_seq: std.atomic.Value(u32) = .init(0),

        /// Set by the writer thread while the AOF is failing; write commands are
        /// rejected meanwhile (see `failure`). `failure_reason` points at a
        /// static error name and is published before `failure_kind`.
        failure_kind: std.atomic.Value(FailureKind) = .init(.none),
        failure_reason: std.atomic.Value(usize) = .init(0),

        fn set_failure(self: *Shared, kind: FailureKind, reason: [:0]const u8) void {
            self.failure_reason.store(@intFromPtr(reason.ptr), .release);
            self.failure_kind.store(kind, .release);
        }
    };

    const FailureKind = enum(u8) { none, write, fsync };

    /// Why the AOF can't accept writes, as reported to clients.
    pub const Failure = struct {
        /// An fsync failed. Unlike a failed write this does not clear on retry:
        /// after a failed fsync the kernel may drop the dirty pages and report a
        /// later fsync as successful, so durability can't be re-established.
        fsync: bool,
        reason: []const u8,

        /// Writes the client-facing error, like Redis' MISCONF.
        pub fn write_error(self: Failure, writer: *Io.Writer) Io.Writer.Error!void {
            const action = if (self.fsync) "fsyncing" else "writing to";
            try writer.print("-MISCONF Errors {s} the AOF file: {s}\r\n", .{ action, self.reason });
        }
    };

    pub fn init(alloc: Allocator, io: Io, enabled: bool, filename: []const u8, work_dir: []const u8, fsync_policy: FsyncPolicy) !Writer {
        if (!enabled) return .{ .enabled = false };

        Dir.cwd().createDir(io, work_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try Dir.cwd().openDir(io, work_dir, .{});
        defer dir.close(io);

        const file = dir.openFile(io, filename, .{ .mode = .write_only }) catch
            try dir.createFile(io, filename, .{});
        errdefer file.close(io);
        const start = try file.length(io);

        const shared = try alloc.create(Shared);
        errdefer alloc.destroy(shared);
        shared.* = .{
            .allocator = alloc,
            .file = file,
            .fsync_policy = fsync_policy,
            .threaded = .init(alloc, .{}),
            .queued_end = start,
            .durable_end = .init(start),
        };
        errdefer shared.threaded.deinit();
        shared.thread = try std.Thread.spawn(.{}, run, .{ shared, start });

        return .{
            .enabled = true,
            .fsync_policy = fsync_policy,
            .allocator = alloc,
            .shared = shared,
        };
    }

    /// Stops the writer thread after it has written (and, unless `no`, fsynced)
    /// everything queued, then closes the file.
    pub fn deinit(self: *Writer) void {
        const shared = self.shared orelse return;

        lock_spin(&shared.mutex);
        shared.stopping = true;
        shared.mutex.unlock();
        _ = shared.wake_seq.fetchAdd(1, .release);
        zio.Futex.wake(&shared.wake_seq.raw, 1);
        shared.thread.join();

        shared.file.close(shared.threaded.io());
        shared.queued.deinit(shared.allocator);
        shared.threaded.deinit();
        self.allocator.destroy(shared);
        self.shared = null;
    }

    /// Queue a command for the AOF. Returns the file offset at the end of the
    /// command, for `wait_durable`, or 0 when the AOF is disabled.
    pub fn write_command(self: *Writer, args: []const Value) u64 {
        if (!self.enabled) return 0;
        const shared = self.shared.?;

        lock_spin(&shared.mutex);
        const start_len = shared.queued.items.len;
        encode_command(&shared.queued, shared.allocator, args) catch {
            shared.queued.shrinkRetainingCapacity(start_len);
            const end = shared.queued_end;
            shared.mutex.unlock();
            log.err("out of memory queueing command for the AOF; command not logged", .{});
            return end;
        };
        shared.queued_end += shared.queued.items.len - start_len;
        const end = shared.queued_end;
        shared.mutex.unlock();

        _ = shared.wake_seq.fetchAdd(1, .release);
        zio.Futex.wake(&shared.wake_seq.raw, 1);
        return end;
    }

    /// Under `always`, parks the calling coroutine until the AOF is fsynced up
    /// to `end`. A no-op for other policies. Must not be called during command
    /// execution (it suspends).
    ///
    /// Returns false if the AOF failed (or the wait was canceled) before `end`
    /// became durable: the caller must not acknowledge those writes. They may
    /// still reach the disk if a failed write is later retried successfully.
    pub fn wait_durable(self: *Writer, end: u64) bool {
        if (!self.enabled or self.fsync_policy != .always) return true;
        const shared = self.shared.?;
        while (true) {
            const seq = shared.durable_seq.load(.acquire);
            if (shared.durable_end.load(.acquire) >= end) return true;
            if (self.failure() != null) return false;
            zio.Futex.wait(&shared.durable_seq.raw, seq) catch return false;
        }
    }

    /// Non-null while the AOF is failing. Callers reject write commands with
    /// `Failure.write_error` meanwhile, so nothing is acknowledged that can't be
    /// persisted. A write failure clears once a retry succeeds; an fsync failure
    /// lasts until restart.
    pub fn failure(self: *const Writer) ?Failure {
        if (!self.enabled) return null;
        const shared = self.shared.?;
        const kind = shared.failure_kind.load(.acquire);
        if (kind == .none) return null;
        const reason: [*:0]const u8 = @ptrFromInt(shared.failure_reason.load(.acquire));
        return .{ .fsync = kind == .fsync, .reason = std.mem.span(reason) };
    }

    fn encode_command(list: *std.ArrayList(u8), gpa: Allocator, args: []const Value) !void {
        try list.print(gpa, "*{d}\r\n", .{args.len});
        for (args) |arg| {
            try list.print(gpa, "${d}\r\n", .{arg.data.len});
            try list.appendSlice(gpa, arg.data);
            try list.appendSlice(gpa, "\r\n");
        }
    }

    /// Writer thread: drains `queued` to the file and fsyncs per policy.
    fn run(shared: *Shared, start: u64) void {
        const io = shared.threaded.io();
        // Bytes taken from `queued` but not yet written; kept across a failed
        // write so the retry rewrites them at the same offset.
        var batch: std.ArrayList(u8) = .empty;
        defer batch.deinit(shared.allocator);

        var offset = start;
        var unsynced = false;
        var fsync_failed = false;
        var last_sync_ms = Io.Timestamp.now(io, .awake).toMilliseconds();

        while (true) {
            const seq = shared.wake_seq.load(.acquire);

            lock_spin(&shared.mutex);
            const file = shared.file;
            if (batch.items.len == 0) {
                std.mem.swap(std.ArrayList(u8), &batch, &shared.queued);
            } else if (batch.appendSlice(shared.allocator, shared.queued.items)) {
                shared.queued.clearRetainingCapacity();
            } else |_| {
                // Out of memory: leave the new bytes queued for the next round.
            }
            const stopping = shared.stopping;
            shared.mutex.unlock();

            var notify_waiters = false;
            var write_failed = false;
            const had_data = batch.items.len > 0;
            if (had_data) {
                if (file.writePositionalAll(io, batch.items, offset)) {
                    offset += batch.items.len;
                    batch.clearRetainingCapacity();
                    unsynced = true;
                    if (shared.failure_kind.load(.monotonic) == .write) {
                        log.info("AOF writes recovered", .{});
                        shared.set_failure(.none, "");
                    }
                } else |err| {
                    write_failed = true;
                    if (shared.failure_kind.load(.monotonic) == .none) {
                        log.warn("AOF write failed: {s}; rejecting write commands until it succeeds", .{@errorName(err)});
                        shared.set_failure(.write, @errorName(err));
                        notify_waiters = true;
                    }
                }
            }

            const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
            const sync_now = unsynced and !fsync_failed and switch (shared.fsync_policy) {
                .always => true,
                .everysec => now_ms - last_sync_ms >= 1000,
                .no => false,
            };
            if (sync_now) {
                if (file.sync(io)) {
                    unsynced = false;
                } else |err| {
                    log.err("AOF fsync failed: {s}; rejecting write commands until restart", .{@errorName(err)});
                    fsync_failed = true;
                    shared.set_failure(.fsync, @errorName(err));
                    notify_waiters = true;
                }
                last_sync_ms = now_ms;
            }

            // Under `always` the durable offset only covers fsynced data.
            const durable = if (shared.fsync_policy == .always and (unsynced or fsync_failed))
                shared.durable_end.load(.monotonic)
            else
                offset;
            if (durable > shared.durable_end.load(.monotonic)) {
                shared.durable_end.store(durable, .release);
                notify_waiters = true;
            }
            if (notify_waiters) {
                _ = shared.durable_seq.fetchAdd(1, .release);
                zio.Futex.wake(&shared.durable_seq.raw, std.math.maxInt(u32));
            }

            if (write_failed) {
                if (stopping) {
                    log.err("AOF: dropping {d} unwritten bytes at shutdown", .{batch.items.len});
                    break;
                }
                // Retry the failed write in a second (sooner if woken).
                zio.Futex.waitTimeout(&shared.wake_seq.raw, seq, .{ .duration = .fromSeconds(1) }) catch {};
                continue;
            }
            if (had_data) continue;
            if (stopping) break;

            // Sleep until more commands arrive; under `everysec`, also wake for
            // the next due fsync.
            const timeout: zio.Timeout = if (unsynced and !fsync_failed and shared.fsync_policy == .everysec)
                .{ .duration = .fromMilliseconds(@intCast(@max(1, 1000 - (now_ms - last_sync_ms)))) }
            else
                .none;
            zio.Futex.waitTimeout(&shared.wake_seq.raw, seq, timeout) catch {};
        }

        if (unsynced and !fsync_failed and shared.fsync_policy != .no) {
            shared.file.sync(io) catch |err| log.err("AOF fsync failed: {s}", .{@errorName(err)});
        }
    }
};

pub const Reader = struct {
    file: Io.File,
    allocator: Allocator,
    store: *Store,
    registry: *Registry,
    reader_buffer: [8192]u8 = undefined,
    io: Io,

    pub fn init(allocator: Allocator, store: *Store, registry: *Registry, io: Io, work_dir: []const u8, filename: []const u8) !Reader {
        const dir = try Dir.cwd().openDir(io, work_dir, .{});
        defer dir.close(io);
        const file = try dir.openFile(io, filename, .{ .mode = .read_only });
        return .{
            .file = file,
            .allocator = allocator,
            .store = store,
            .registry = registry,
            .io = io,
        };
    }

    /// Replays the AOF into the store, one command at a time, then closes the file.
    pub fn read(self: *Reader) !void {
        defer self.file.close(self.io);

        // Built here rather than in init: the reader points at `reader_buffer`,
        // so it must not outlive (or be copied away from) `self`.
        var file_reader = self.file.reader(self.io, &self.reader_buffer);
        var parser = Parser.init(self.allocator);

        var replayed: usize = 0;
        while (true) {
            var command = parser.parse(&file_reader.interface) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    log.warn("AOF parse failed after {d} commands: {s}; ignoring the rest of the file", .{ replayed, @errorName(err) });
                    break;
                },
            };
            defer command.deinit();
            try self.registry.execute_command_aof(self.store, command.get_args());
            replayed += 1;
        }
        log.info("Replayed {d} commands from the AOF", .{replayed});
    }
};

const testing = std.testing;
test "aof reader replays values larger than its read buffer" {
    const reg_init = @import("../commands/init_registry.zig");
    const dir_name = "aof_reader_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    // A value larger than the 8 KB read buffer, followed by another command.
    const big_len = 20 * 1024;
    {
        var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
        defer aof_writer.deinit();
        const big = try testing.allocator.alloc(u8, big_len);
        defer testing.allocator.free(big);
        @memset(big, 'b');
        _ = aof_writer.write_command(&.{ .{ .data = "set" }, .{ .data = "big" }, .{ .data = big } });
        _ = aof_writer.write_command(&.{ .{ .data = "set" }, .{ .data = "t" }, .{ .data = "test" } });
    }

    var registry = try reg_init.init_registry(std.testing.allocator);
    defer registry.deinit();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var aof_reader = try Reader.init(testing.allocator, &store, &registry, testing.io, dir_name, "test.aof");
    try aof_reader.read();

    try testing.expectEqual(@as(usize, big_len), store.get("big").?.value.string.len);
    try testing.expectEqualStrings("test", store.get("t").?.value.short_string.as_slice());
}

fn read_test_aof(dir_name: []const u8, file_name: []const u8, buf: []u8) ![]const u8 {
    const dir = try Dir.cwd().openDir(testing.io, dir_name, .{});
    defer dir.close(testing.io);
    const file = try dir.openFile(testing.io, file_name, .{});
    defer file.close(testing.io);
    const n = try file.readPositionalAll(testing.io, buf, 0);
    return buf[0..n];
}

test "aof writer thread writes queued commands before deinit returns" {
    const dir_name = "aof_writer_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
    const set_args = [_]Value{ .{ .data = "SET" }, .{ .data = "t" }, .{ .data = "test" } };
    const end = aof_writer.write_command(&set_args);
    const incr_args = [_]Value{ .{ .data = "INCR" }, .{ .data = "n" } };
    _ = aof_writer.write_command(&incr_args);
    aof_writer.deinit();

    const expected = "*3\r\n$3\r\nSET\r\n$1\r\nt\r\n$4\r\ntest\r\n*2\r\n$4\r\nINCR\r\n$1\r\nn\r\n";
    try testing.expectEqual(@as(u64, 30), end);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, try read_test_aof(dir_name, "test.aof", &buf));
}

test "aof writer appends to an existing file and wait_durable waits for fsync" {
    const dir_name = "aof_writer_append_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    const ping = [_]Value{.{ .data = "PING" }};
    {
        var first = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
        _ = first.write_command(&ping);
        first.deinit();
    }

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .always);
    defer aof_writer.deinit();
    const end = aof_writer.write_command(&ping);
    try testing.expectEqual(@as(u64, 28), end);

    try testing.expect(aof_writer.wait_durable(end));
    try testing.expect(aof_writer.shared.?.durable_end.load(.acquire) >= end);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nPING\r\n", try read_test_aof(dir_name, "test.aof", &buf));
}

test "disabled aof writer ignores commands" {
    var aof_writer = try Writer.init(testing.allocator, testing.io, false, "unused.aof", "unused", .always);
    defer aof_writer.deinit();
    const ping = [_]Value{.{ .data = "PING" }};
    try testing.expectEqual(@as(u64, 0), aof_writer.write_command(&ping));
    try testing.expect(aof_writer.wait_durable(0));
}

/// Swaps the writer thread's file handle (for tests that simulate failures).
fn swap_test_file(aof_writer: *Writer, file: Io.File) Io.File {
    const shared = aof_writer.shared.?;
    lock_spin(&shared.mutex);
    defer shared.mutex.unlock();
    const previous = shared.file;
    shared.file = file;
    return previous;
}

/// Polls `aof_writer.failure()` until it is (or stops being) set, up to ~5s.
fn wait_for_failure_state(aof_writer: *Writer, want_failed: bool) !void {
    for (0..500) |_| {
        if ((aof_writer.failure() != null) == want_failed) return;
        try Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.Timeout;
}

test "aof write failure is reported until a retry succeeds" {
    const dir_name = "aof_failure_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
    defer aof_writer.deinit();

    // Point the writer thread at a read-only handle so its next write fails.
    const dir = try Dir.cwd().openDir(testing.io, dir_name, .{});
    defer dir.close(testing.io);
    const read_only = try dir.openFile(testing.io, "test.aof", .{ .mode = .read_only });
    const writable = swap_test_file(&aof_writer, read_only);

    const ping = [_]Value{.{ .data = "PING" }};
    _ = aof_writer.write_command(&ping);
    try wait_for_failure_state(&aof_writer, true);
    const failure = aof_writer.failure().?;
    try testing.expect(!failure.fsync);

    var buf: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try failure.write_error(&writer);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "-MISCONF Errors writing to the AOF file: "));

    // Restore the writable handle: the retry writes the kept bytes and clears the failure.
    read_only.close(testing.io);
    _ = swap_test_file(&aof_writer, writable);
    try wait_for_failure_state(&aof_writer, false);

    var contents: [64]u8 = undefined;
    try testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n", try read_test_aof(dir_name, "test.aof", &contents));
}

test "aof wait_durable reports failure under appendfsync always" {
    const dir_name = "aof_always_failure_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .always);
    defer aof_writer.deinit();

    const dir = try Dir.cwd().openDir(testing.io, dir_name, .{});
    defer dir.close(testing.io);
    const read_only = try dir.openFile(testing.io, "test.aof", .{ .mode = .read_only });
    const writable = swap_test_file(&aof_writer, read_only);

    const ping = [_]Value{.{ .data = "PING" }};
    const end = aof_writer.write_command(&ping);
    try testing.expect(!aof_writer.wait_durable(end));
    try testing.expect(aof_writer.failure() != null);

    read_only.close(testing.io);
    _ = swap_test_file(&aof_writer, writable);
    try wait_for_failure_state(&aof_writer, false);
    try testing.expect(aof_writer.wait_durable(end));
}
