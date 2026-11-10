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
const snapshot = @import("aof_snapshot.zig");

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
    /// The thread rebuilding the AOF, if one has run. Touched only by the executor.
    rewrite_thread: ?std.Thread = null,

    /// Retry delay after a rewrite fails, and after one that cannot work until
    /// keys are deleted (an unsupported value type).
    const rewrite_retry_seconds: i64 = 60;
    const rewrite_unsupported_retry_seconds: i64 = 600;
    const rewrite_buffer_bytes = 256 * 1024;
    const copy_buffer_bytes = 64 * 1024;
    /// The rewrite thread stops copying the live log once this little is left,
    /// which the writer thread then splices on while it is paused, and gives up
    /// chasing a log that grows faster than it can copy after this many rounds.
    const catch_up_slack_bytes = 1024 * 1024;
    const catch_up_max_rounds = 16;

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
        /// File size when the writer started or last rewrote, for INFO's `aof_base_size`.
        base_size: std.atomic.Value(u64),
        /// Where the file lives, to put a rewritten one in its place.
        dir_path: []u8,
        file_name: []u8,
        /// Logical stream offset minus file offset (wrapping). Offsets clients
        /// wait on (`wait_durable`) only ever grow, but a rewrite replaces the
        /// file with a snapshot of a different size. Only the writer thread
        /// changes it, when it switches files.
        delta: std.atomic.Value(u64) = .init(0),
        /// A rewritten file the rewrite thread has handed over and the writer
        /// thread has not switched to yet.
        pending_switch: ?Switch = null,
        /// Rewrite state. `rewrite_active` is set by `start_rewrite` and cleared
        /// by whichever thread ends the rewrite: the rewrite thread if it fails,
        /// the writer thread once it has switched (or failed to switch) files.
        rewrite_active: std.atomic.Value(bool) = .init(false),
        abort_rewrite: std.atomic.Value(bool) = .init(false),
        rewrites: std.atomic.Value(u64) = .init(0),
        last_rewrite_ok: std.atomic.Value(bool) = .init(true),
        last_rewrite_seconds: std.atomic.Value(i64) = .init(0),
        /// Earliest wall-clock second an automatic rewrite may start, so a
        /// failing one doesn't retry on every write.
        next_auto_rewrite_s: std.atomic.Value(i64) = .init(0),
        /// Last successful fsync: wall-clock seconds, duration in microseconds,
        /// and a running count. Read by INFO/METRICS without taking the mutex.
        last_fsync_seconds: std.atomic.Value(i64) = .init(0),
        last_fsync_us: std.atomic.Value(u64) = .init(0),
        fsync_count: std.atomic.Value(u64) = .init(0),
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

    /// A rewritten file to take over from the current one: a snapshot of the
    /// dataset as of an earlier point in the log, followed by a raw copy of the
    /// log up to `copied_logical`. The writer thread appends whatever it has
    /// written since.
    const Switch = struct {
        file: Io.File,
        temp_name: []u8,
        /// Log offset the new file is complete up to, and its length there.
        copied_logical: u64,
        file_len: u64,
    };

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

        const dir_path = try alloc.dupe(u8, work_dir);
        errdefer alloc.free(dir_path);
        const file_name = try alloc.dupe(u8, filename);
        errdefer alloc.free(file_name);

        const shared = try alloc.create(Shared);
        errdefer alloc.destroy(shared);
        shared.* = .{
            .allocator = alloc,
            .file = file,
            .fsync_policy = fsync_policy,
            .threaded = .init(alloc, .{}),
            .queued_end = start,
            .durable_end = .init(start),
            .base_size = .init(start),
            .dir_path = dir_path,
            .file_name = file_name,
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

        shared.abort_rewrite.store(true, .release);
        if (self.rewrite_thread) |worker| {
            worker.join();
            self.rewrite_thread = null;
        }

        lock_spin(&shared.mutex);
        shared.stopping = true;
        shared.mutex.unlock();
        _ = shared.wake_seq.fetchAdd(1, .release);
        zio.Futex.wake(&shared.wake_seq.raw, 1);
        shared.thread.join();

        shared.file.close(shared.threaded.io());
        if (shared.pending_switch) |pending| discard_switch(shared, shared.threaded.io(), pending);
        shared.allocator.free(shared.dir_path);
        shared.allocator.free(shared.file_name);
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

    /// Bytes appended to the AOF file, including those still queued.
    pub fn currentSize(self: *const Writer) u64 {
        if (!self.enabled) return 0;
        const shared = self.shared.?;
        return shared.queued_end -% shared.delta.load(.acquire);
    }

    /// Bytes accepted but not yet written to the file.
    pub fn pendingBytes(self: *const Writer) u64 {
        if (!self.enabled) return 0;
        const shared = self.shared.?;
        return shared.queued_end -| shared.durable_end.load(.acquire);
    }

    pub fn baseSize(self: *const Writer) u64 {
        if (!self.enabled) return 0;
        return self.shared.?.base_size.load(.acquire);
    }

    pub fn lastFsyncInfo(self: *const Writer) struct { seconds: i64, duration_us: u64, count: u64 } {
        if (!self.enabled) return .{ .seconds = 0, .duration_us = 0, .count = 0 };
        const shared = self.shared.?;
        return .{
            .seconds = shared.last_fsync_seconds.load(.acquire),
            .duration_us = shared.last_fsync_us.load(.acquire),
            .count = shared.fsync_count.load(.acquire),
        };
    }

    pub fn fsyncFailed(self: *const Writer) bool {
        return if (self.failure()) |aof_failure| aof_failure.fsync else false;
    }

    pub const RewriteInfo = struct { active: bool, count: u64, last_ok: bool, last_seconds: i64 };

    pub fn rewriteInfo(self: *const Writer) RewriteInfo {
        if (!self.enabled) return .{ .active = false, .count = 0, .last_ok = true, .last_seconds = 0 };
        const shared = self.shared.?;
        return .{
            .active = shared.rewrite_active.load(.acquire),
            .count = shared.rewrites.load(.acquire),
            .last_ok = shared.last_rewrite_ok.load(.acquire),
            .last_seconds = shared.last_rewrite_seconds.load(.acquire),
        };
    }

    /// Whether the AOF has grown enough to rewrite: at least `min_size` bytes
    /// and `growth_percent` larger than after the last rewrite (or the load).
    /// A percentage of 0 disables automatic rewrites, as in Redis.
    pub fn rewrite_due(self: *const Writer, min_size: u64, growth_percent: u32, now_s: i64) bool {
        if (!self.enabled or growth_percent == 0) return false;
        const shared = self.shared.?;
        if (shared.rewrite_active.load(.acquire) or now_s < shared.next_auto_rewrite_s.load(.acquire)) return false;
        const size = self.currentSize();
        if (size < min_size or self.failure() != null) return false;
        const base: u128 = @max(self.baseSize(), 1);
        return @as(u128, size) * 100 >= base * (100 + growth_percent);
    }

    /// Starts rebuilding the AOF as a snapshot of the dataset, on a background
    /// thread, so the executor keeps serving commands. The store has no locks,
    /// so the thread never touches it: it replays the existing log, up to the
    /// offset recorded here, into a private store and snapshots that, which
    /// yields exactly what a restart would load. It then copies the log written
    /// meanwhile and hands the file to the writer thread, which splices on the
    /// last few bytes, fsyncs, and renames it over the AOF.
    ///
    /// The cost is a second copy of the dataset in memory while it runs, outside
    /// `maxmemory`. A failed rewrite leaves the existing AOF untouched.
    pub fn start_rewrite(self: *Writer, registry: *Registry) !void {
        if (!self.enabled) return error.AofDisabled;
        // After a failed fsync the kernel may have dropped dirty pages, so the
        // log can no longer be trusted as a source.
        if (self.failure() != null) return error.AofFailing;
        const shared = self.shared.?;
        if (shared.rewrite_active.swap(true, .acq_rel)) return error.RewriteInProgress;
        errdefer shared.rewrite_active.store(false, .release);

        // The flag was clear, so any previous thread is done or about to exit.
        if (self.rewrite_thread) |finished| {
            finished.join();
            self.rewrite_thread = null;
        }

        lock_spin(&shared.mutex);
        const snapshot_end = shared.queued_end;
        shared.mutex.unlock();
        self.rewrite_thread = try std.Thread.spawn(.{}, rewrite_worker, .{ shared, registry, snapshot_end });
    }

    fn end_rewrite(shared: *Shared, io: Io, err: ?anyerror) void {
        if (err) |failure_err| {
            shared.last_rewrite_ok.store(false, .release);
            const retry = if (failure_err == error.UnsupportedType) rewrite_unsupported_retry_seconds else rewrite_retry_seconds;
            shared.next_auto_rewrite_s.store(wall_seconds(io) + retry, .release);
        } else {
            _ = shared.rewrites.fetchAdd(1, .acq_rel);
            shared.last_rewrite_ok.store(true, .release);
            shared.last_rewrite_seconds.store(wall_seconds(io), .release);
        }
        shared.rewrite_active.store(false, .release);
    }

    fn wall_seconds(io: Io) i64 {
        return @divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000);
    }

    fn rewrite_worker(shared: *Shared, registry: *Registry, snapshot_end: u64) void {
        var threaded: Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        build_rewrite(shared, io, registry, snapshot_end) catch |err| {
            if (err == error.Aborted) {
                shared.rewrite_active.store(false, .release);
            } else {
                log.warn("AOF rewrite failed: {s}; keeping the current AOF", .{@errorName(err)});
                end_rewrite(shared, io, err);
            }
        };
    }

    /// Builds the new file and hands it to the writer thread, which ends the
    /// rewrite once it has switched to it.
    fn build_rewrite(shared: *Shared, io: Io, registry: *Registry, snapshot_end: u64) !void {
        const alloc = shared.allocator;
        // Only a rewrite changes it, and only one runs at a time.
        const delta = shared.delta.load(.acquire);
        try wait_until_written(shared, io, snapshot_end);

        const dir = try Dir.cwd().openDir(io, shared.dir_path, .{});
        defer dir.close(io);
        const temp_name = try std.fmt.allocPrint(alloc, "{s}.rewrite.tmp", .{shared.file_name});
        errdefer alloc.free(temp_name);
        const temp = try dir.createFile(io, temp_name, .{ .truncate = true });
        errdefer {
            temp.close(io);
            dir.deleteFile(io, temp_name) catch {};
        }

        var snapshot_len: u64 = undefined;
        {
            // Scoped so the private copy of the dataset is freed before the catch-up.
            var clock = Clock.init(io, 0);
            var store = try Store.init(alloc, io, &clock, .{ .initial_capacity = 4096 });
            defer store.deinit();
            try replay_log(shared, io, registry, &store, snapshot_end -% delta);

            const buffer = try alloc.alloc(u8, rewrite_buffer_bytes);
            defer alloc.free(buffer);
            var file_writer = temp.writer(io, buffer);
            try snapshot.write(&store, Io.Timestamp.now(io, .real).toMilliseconds(), &file_writer.interface);
            try file_writer.interface.flush();
            snapshot_len = file_writer.logicalPos();
        }

        // Copy the log written since the snapshot point, chasing it until little
        // is left for the writer thread to splice on.
        const old = try dir.openFile(io, shared.file_name, .{ .mode = .read_only });
        defer old.close(io);
        var copied_file = snapshot_end -% delta;
        var file_len = snapshot_len;
        for (0..catch_up_max_rounds) |_| {
            if (shared.abort_rewrite.load(.acquire)) return error.Aborted;
            const written_file = shared.durable_end.load(.acquire) -% delta;
            if (written_file -| copied_file <= catch_up_slack_bytes) break;
            try copy_range(io, alloc, old, copied_file, temp, file_len, written_file - copied_file);
            file_len += written_file - copied_file;
            copied_file = written_file;
        }
        try temp.sync(io);

        lock_spin(&shared.mutex);
        shared.pending_switch = .{
            .file = temp,
            .temp_name = temp_name,
            .copied_logical = copied_file +% delta,
            .file_len = file_len,
        };
        shared.mutex.unlock();
        _ = shared.wake_seq.fetchAdd(1, .release);
        zio.Futex.wake(&shared.wake_seq.raw, 1);
    }

    /// Waits for the writer thread to have written the log up to `logical`.
    fn wait_until_written(shared: *Shared, io: Io, logical: u64) !void {
        while (shared.durable_end.load(.acquire) < logical) {
            if (shared.abort_rewrite.load(.acquire)) return error.Aborted;
            if (shared.failure_kind.load(.acquire) != .none) return error.AofFailing;
            Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        }
    }

    /// Replays the first `limit` bytes of the log into `store`, as a restart would.
    fn replay_log(shared: *Shared, io: Io, registry: *Registry, store: *Store, limit: u64) !void {
        const alloc = shared.allocator;
        const dir = try Dir.cwd().openDir(io, shared.dir_path, .{});
        defer dir.close(io);
        const file = try dir.openFile(io, shared.file_name, .{ .mode = .read_only });
        defer file.close(io);
        const buffer = try alloc.alloc(u8, copy_buffer_bytes);
        defer alloc.free(buffer);

        var file_reader = file.reader(io, buffer);
        var parser = Parser.init(alloc);
        while (file_reader.logicalPos() < limit) {
            if (shared.abort_rewrite.load(.acquire)) return error.Aborted;
            var command = try parser.parse(&file_reader.interface);
            defer command.deinit();
            try registry.execute_command_aof(store, command.get_args());
        }
    }

    fn copy_range(io: Io, alloc: Allocator, src: Io.File, src_offset: u64, dst: Io.File, dst_offset: u64, len: u64) !void {
        const buffer = try alloc.alloc(u8, copy_buffer_bytes);
        defer alloc.free(buffer);
        var copied: u64 = 0;
        while (copied < len) {
            const want: usize = @intCast(@min(buffer.len, len - copied));
            const n = try src.readPositionalAll(io, buffer[0..want], src_offset + copied);
            if (n == 0) return error.EndOfStream;
            try dst.writePositionalAll(io, buffer[0..n], dst_offset + copied);
            copied += n;
        }
    }

    fn discard_switch(shared: *Shared, io: Io, next: Switch) void {
        next.file.close(io);
        if (Dir.cwd().openDir(io, shared.dir_path, .{})) |dir| {
            defer dir.close(io);
            dir.deleteFile(io, next.temp_name) catch {};
        } else |_| {}
        shared.allocator.free(next.temp_name);
    }

    /// Writer thread: switches to the rewritten file. `written` is how far the
    /// log has been written, so the bytes between what the rewrite thread copied
    /// and that point are appended here; everything after them is written to the
    /// new file in the normal course. Returns whether the switch happened; on
    /// failure the current AOF stays in place.
    fn apply_switch(shared: *Shared, io: Io, next: Switch, written: u64, delta: *u64) bool {
        finish_switch(shared, io, next, written, delta) catch |err| {
            log.warn("AOF rewrite failed while switching files: {s}; keeping the current AOF", .{@errorName(err)});
            discard_switch(shared, io, next);
            end_rewrite(shared, io, err);
            return false;
        };
        shared.allocator.free(next.temp_name);
        log.info("Rewrote the AOF; it is now {d} bytes", .{shared.base_size.load(.acquire)});
        end_rewrite(shared, io, null);
        return true;
    }

    fn finish_switch(shared: *Shared, io: Io, next: Switch, written: u64, delta: *u64) !void {
        const copied_file = next.copied_logical -% delta.*;
        const written_file = written -% delta.*;
        var new_len = next.file_len;

        const dir = try Dir.cwd().openDir(io, shared.dir_path, .{});
        defer dir.close(io);
        if (written_file > copied_file) {
            const old = try dir.openFile(io, shared.file_name, .{ .mode = .read_only });
            defer old.close(io);
            try copy_range(io, shared.allocator, old, copied_file, next.file, new_len, written_file - copied_file);
            new_len += written_file - copied_file;
        }
        try next.file.sync(io);

        // TODO: fsync the directory so the rename itself survives a crash;
        // std.Io has no directory sync. Until then a crash right after a rewrite
        // can bring back the previous (complete, but older) AOF.
        try dir.rename(next.temp_name, dir, shared.file_name, io);

        lock_spin(&shared.mutex);
        const retired = shared.file;
        shared.file = next.file;
        shared.mutex.unlock();
        retired.close(io);

        // The log offset the new file is complete up to now maps to its length there.
        delta.* = next.copied_logical -% next.file_len;
        shared.delta.store(delta.*, .release);
        shared.base_size.store(new_len, .release);
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
        var delta: u64 = 0;
        var unsynced = false;
        var fsync_failed = false;
        var last_sync_ms = Io.Timestamp.now(io, .awake).toMilliseconds();

        while (true) {
            const seq = shared.wake_seq.load(.acquire);

            lock_spin(&shared.mutex);
            const incoming = shared.pending_switch;
            shared.pending_switch = null;
            shared.mutex.unlock();
            if (incoming) |next| {
                // A switch also leaves the new file synced up to `offset`.
                if (apply_switch(shared, io, next, offset, &delta)) unsynced = false;
            }

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
                if (file.writePositionalAll(io, batch.items, offset -% delta)) {
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
                // Monotonic clock of the writer's own I/O backend: the server's
                // cached wall clock belongs to the executor thread and is not
                // safe here. Wall time is read separately below for display.
                const fsync_start_ns = Io.Timestamp.now(io, .awake).toNanoseconds();
                if (file.sync(io)) {
                    unsynced = false;
                    const elapsed_ns = Io.Timestamp.now(io, .awake).toNanoseconds() - fsync_start_ns;
                    shared.last_fsync_us.store(@intCast(@max(elapsed_ns, 0) / 1000), .release);
                    shared.last_fsync_seconds.store(@divTrunc(Io.Timestamp.now(io, .real).toMilliseconds(), 1000), .release);
                    _ = shared.fsync_count.fetchAdd(1, .monotonic);
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

/// What the reader does with a damaged end of file.
pub const LoadOptions = struct {
    /// `aof-load-truncated`: accept a final command cut off mid-write by a crash.
    load_truncated: bool = true,
    /// `aof-load-broken`: also accept a corrupt tail of at most `broken_max_size` bytes.
    load_broken: bool = false,
    broken_max_size: u64 = 4096,
    /// Cut an accepted bad tail off the file. The writer appends at the end of
    /// the file, so a partial command left behind would corrupt every command
    /// logged after it.
    repair: bool = false,
};

pub const LoadError = error{
    AofTruncated,
    AofCorrupt,
    AofUnknownCommand,
    AofReadFailed,
    AofRepairFailed,
};

pub const Reader = struct {
    file: Io.File,
    allocator: Allocator,
    store: *Store,
    registry: *Registry,
    options: LoadOptions,
    reader_buffer: [8192]u8 = undefined,
    io: Io,

    const Damage = enum { truncated, broken };
    const Next = union(enum) { command: Command, damage: Damage };

    pub fn init(
        allocator: Allocator,
        store: *Store,
        registry: *Registry,
        io: Io,
        work_dir: []const u8,
        filename: []const u8,
        options: LoadOptions,
    ) !Reader {
        const dir = try Dir.cwd().openDir(io, work_dir, .{});
        defer dir.close(io);
        const file = try dir.openFile(io, filename, .{ .mode = if (options.repair) .read_write else .read_only });
        return .{
            .file = file,
            .allocator = allocator,
            .store = store,
            .registry = registry,
            .options = options,
            .io = io,
        };
    }

    /// Replays the AOF into the store, one command at a time, then closes the
    /// file. Fails, leaving the file untouched, on anything it cannot replay
    /// faithfully: serving a partial dataset and appending to a damaged log
    /// would silently lose data.
    pub fn read(self: *Reader) !void {
        defer self.file.close(self.io);

        // Built here rather than in init: the reader points at `reader_buffer`,
        // so it must not outlive (or be copied away from) `self`.
        var file_reader = self.file.reader(self.io, &self.reader_buffer);
        var parser = Parser.init(self.allocator);

        const file_len = try self.file.length(self.io);
        var valid_offset: u64 = 0;
        var replayed: usize = 0;
        while (valid_offset < file_len) {
            switch (try read_next(&parser, &file_reader)) {
                .damage => |damage| {
                    try self.accept_damage(damage, valid_offset, file_len, replayed);
                    break;
                },
                .command => |parsed| {
                    var command = parsed;
                    defer command.deinit();
                    const args = command.get_args();
                    if (args.len == 0) {
                        try self.accept_damage(.broken, valid_offset, file_len, replayed);
                        break;
                    }
                    if (!self.registry.knows_command(args[0].data)) {
                        log.warn("AOF holds unknown command '{s}' after {d} commands; refusing to drop it silently", .{ args[0].data, replayed });
                        return error.AofUnknownCommand;
                    }
                    try self.registry.execute_command_aof(self.store, args);
                    replayed += 1;
                    valid_offset = file_reader.logicalPos();
                },
            }
        }
        log.info("Replayed {d} commands from the AOF", .{replayed});
    }

    /// The AOF only ever holds RESP arrays, so any other lead byte is damage
    /// rather than an inline command.
    fn read_next(parser: *Parser, file_reader: *Io.File.Reader) !Next {
        const interface = &file_reader.interface;
        const lead = interface.peekByte() catch |err| return .{ .damage = try damage_of(file_reader, err) };
        if (lead != '*') return .{ .damage = .broken };
        const command = parser.parse(interface) catch |err| return .{ .damage = try damage_of(file_reader, err) };
        return .{ .command = command };
    }

    /// The parser reports a failed read as end of stream. Telling the two apart
    /// matters: a real I/O error mistaken for a short file would get its tail
    /// truncated away.
    fn damage_of(file_reader: *const Io.File.Reader, err: anyerror) !Damage {
        if (file_reader.err != null) return error.AofReadFailed;
        return switch (err) {
            error.EndOfStream => .truncated,
            error.InvalidProtocol, error.StreamTooLong => .broken,
            error.OutOfMemory => error.OutOfMemory,
            else => error.AofReadFailed,
        };
    }

    fn accept_damage(self: *Reader, damage: Damage, valid_offset: u64, file_len: u64, replayed: usize) !void {
        const tail = file_len - valid_offset;
        switch (damage) {
            .truncated => if (!self.options.load_truncated) {
                log.warn("AOF ends with an incomplete command ({d} bytes after {d} commands); set aof-load-truncated yes to cut it off", .{ tail, replayed });
                return error.AofTruncated;
            },
            .broken => if (!self.options.load_broken or tail > self.options.broken_max_size) {
                log.warn("AOF is corrupt {d} bytes from its end, after {d} commands; repair or move the file aside", .{ tail, replayed });
                return error.AofCorrupt;
            },
        }
        log.warn("Ignoring {d} unreadable bytes at the end of the AOF after {d} commands", .{ tail, replayed });
        if (self.options.repair) {
            self.file.setLength(self.io, valid_offset) catch |err| {
                log.err("Could not remove the bad tail of the AOF: {s}", .{@errorName(err)});
                return error.AofRepairFailed;
            };
        }
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

    var aof_reader = try Reader.init(testing.allocator, &store, &registry, testing.io, dir_name, "test.aof", .{});
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

const set_a = "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n";

fn write_test_aof(dir_name: []const u8, bytes: []const u8) !void {
    Dir.cwd().createDir(testing.io, dir_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const dir = try Dir.cwd().openDir(testing.io, dir_name, .{});
    defer dir.close(testing.io);
    const file = try dir.createFile(testing.io, "test.aof", .{ .truncate = true });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, bytes, 0);
}

fn test_aof_length(dir_name: []const u8) !u64 {
    var buf: [512]u8 = undefined;
    return (try read_test_aof(dir_name, "test.aof", &buf)).len;
}

/// Loads `contents` as the AOF with `options`; returns the load result and
/// whether key "a" was replayed.
fn load_aof_bytes(dir_name: []const u8, contents: []const u8, options: LoadOptions) !struct { result: anyerror!void, has_a: bool } {
    const reg_init = @import("../commands/init_registry.zig");
    try write_test_aof(dir_name, contents);

    var registry = try reg_init.init_registry(testing.allocator);
    defer registry.deinit();
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var reader = try Reader.init(testing.allocator, &store, &registry, testing.io, dir_name, "test.aof", options);
    const result = reader.read();
    return .{ .result = result, .has_a = store.exists("a") };
}

test "aof reader cuts off a command truncated by a crash and keeps what precedes it" {
    const dir_name = "aof_truncated_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    const partial = "*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1\r\n";
    const loaded = try load_aof_bytes(dir_name, set_a ++ partial, .{ .repair = true });

    try loaded.result;
    try testing.expect(loaded.has_a);
    try testing.expectEqual(@as(u64, set_a.len), try test_aof_length(dir_name));
}

test "aof reader leaves the file alone when not asked to repair it" {
    const dir_name = "aof_norepair_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    const partial = "*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1\r\n";
    const loaded = try load_aof_bytes(dir_name, set_a ++ partial, .{});

    try loaded.result;
    try testing.expect(loaded.has_a);
    try testing.expectEqual(@as(u64, set_a.len + partial.len), try test_aof_length(dir_name));
}

test "aof reader refuses a truncated tail unless aof-load-truncated is set" {
    const dir_name = "aof_strict_truncated_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    const partial = "*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1\r\n";
    const loaded = try load_aof_bytes(dir_name, set_a ++ partial, .{ .load_truncated = false, .repair = true });

    try testing.expectError(error.AofTruncated, loaded.result);
    try testing.expectEqual(@as(u64, set_a.len + partial.len), try test_aof_length(dir_name));
}

test "aof reader treats damage as fatal unless aof-load-broken allows a small tail" {
    const dir_name = "aof_broken_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    const garbage = "garbage\r\n";
    const cases = [_]struct { options: LoadOptions, expect_error: bool }{
        .{ .options = .{ .repair = true }, .expect_error = true },
        .{ .options = .{ .load_broken = true, .broken_max_size = garbage.len - 1, .repair = true }, .expect_error = true },
        .{ .options = .{ .load_broken = true, .broken_max_size = garbage.len, .repair = true }, .expect_error = false },
    };
    for (cases) |case| {
        const loaded = try load_aof_bytes(dir_name, set_a ++ garbage, case.options);
        if (case.expect_error) {
            try testing.expectError(error.AofCorrupt, loaded.result);
            try testing.expectEqual(@as(u64, set_a.len + garbage.len), try test_aof_length(dir_name));
        } else {
            try loaded.result;
            try testing.expect(loaded.has_a);
            try testing.expectEqual(@as(u64, set_a.len), try test_aof_length(dir_name));
        }
    }
}

test "aof reader refuses a command this build does not know" {
    const dir_name = "aof_unknown_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    const loaded = try load_aof_bytes(dir_name, set_a ++ "*1\r\n$5\r\nNOPE!\r\n", .{ .load_broken = true, .repair = true });

    try testing.expectError(error.AofUnknownCommand, loaded.result);
}

test "aof reader accepts a complete file and an empty one" {
    const dir_name = "aof_clean_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    const full = try load_aof_bytes(dir_name, set_a, .{});
    try full.result;
    try testing.expect(full.has_a);

    const empty = try load_aof_bytes(dir_name, "", .{});
    try empty.result;
    try testing.expect(!empty.has_a);
}

const ping_frame = "*1\r\n$4\r\nPING\r\n";

const ZedisValue = @import("../storage/store.zig").ZedisValue;
const ZedisListNode = @import("../storage/list.zig").ZedisListNode;
const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;

fn wait_for_rewrite(aof_writer: *const Writer) !void {
    for (0..2000) |_| {
        if (!aof_writer.rewriteInfo().active) return;
        try Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

/// Logs a command to the AOF and applies it to `reference`, so replaying the
/// AOF must reproduce `reference`.
fn log_and_apply(aof_writer: *Writer, registry: *Registry, reference: *Store, argv: []const []const u8) !u64 {
    var args: [4]Value = undefined;
    for (argv, 0..) |arg, i| args[i] = .{ .data = arg };
    try registry.execute_command_aof(reference, args[0..argv.len]);
    return aof_writer.write_command(args[0..argv.len]);
}

fn log_workload_step(aof_writer: *Writer, registry: *Registry, reference: *Store, i: usize) !u64 {
    var key_buf: [16]u8 = undefined;
    var value_buf: [24]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i % 23});
    const value = try std.fmt.bufPrint(&value_buf, "value-{d}", .{i});
    return switch (i % 5) {
        0, 1 => log_and_apply(aof_writer, registry, reference, &.{ "SET", key, value }),
        2 => log_and_apply(aof_writer, registry, reference, &.{ "INCR", "counter" }),
        3 => log_and_apply(aof_writer, registry, reference, &.{ "RPUSH", "queue", value }),
        else => log_and_apply(aof_writer, registry, reference, &.{ "DEL", key }),
    };
}

fn primitive_text(buf: *[24]u8, value: *const PrimitiveValue) []const u8 {
    return switch (value.*) {
        .string => |s| s,
        .short_string => |*ss| ss.as_slice(),
        .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
    };
}

fn scalar_text(buf: *[24]u8, value: *const ZedisValue) []const u8 {
    return switch (value.*) {
        .string => |s| s,
        .short_string => |*ss| ss.as_slice(),
        .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
        else => unreachable,
    };
}

/// Compares strings, ints and lists by value; other types by kind only.
fn expect_same_dataset(expected: *Store, actual: *Store) !void {
    try testing.expectEqual(expected.size(), actual.size());
    var it = expected.iterator();
    while (it.next()) |entry| {
        const other = actual.get(entry.key) orelse return error.MissingKey;
        switch (entry.object.value) {
            .list => |list| {
                try testing.expectEqual(list.len(), other.value.list.len());
                var a = list.list.first;
                var b = other.value.list.list.first;
                while (a != null and b != null) : ({
                    a = a.?.next;
                    b = b.?.next;
                }) {
                    const node_a: *ZedisListNode = @fieldParentPtr("node", a.?);
                    const node_b: *ZedisListNode = @fieldParentPtr("node", b.?);
                    var buf_a: [24]u8 = undefined;
                    var buf_b: [24]u8 = undefined;
                    try testing.expectEqualStrings(primitive_text(&buf_a, &node_a.data), primitive_text(&buf_b, &node_b.data));
                }
            },
            .bloom_filter => try testing.expect(other.value == .bloom_filter),
            else => {
                var buf_a: [24]u8 = undefined;
                var buf_b: [24]u8 = undefined;
                try testing.expectEqualStrings(scalar_text(&buf_a, &entry.object.value), scalar_text(&buf_b, &other.value));
            },
        }
    }
}

fn aof_file_len(dir_name: []const u8) !u64 {
    const dir = try Dir.cwd().openDir(testing.io, dir_name, .{});
    defer dir.close(testing.io);
    const file = try dir.openFile(testing.io, "test.aof", .{});
    defer file.close(testing.io);
    return file.length(testing.io);
}

/// Replays the AOF in `dir_name` and checks it rebuilds `reference`.
fn expect_aof_replays_to(dir_name: []const u8, registry: *Registry, reference: *Store) !void {
    var clock = Clock.init(testing.io, 0);
    var replayed = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer replayed.deinit();
    var reader = try Reader.init(testing.allocator, &replayed, registry, testing.io, dir_name, "test.aof", .{});
    try reader.read();
    try expect_same_dataset(reference, &replayed);
}

test "aof rewrite runs in the background and keeps everything logged while it ran" {
    const reg_init = @import("../commands/init_registry.zig");
    const dir_name = "aof_bg_rewrite_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var registry = try reg_init.init_registry(testing.allocator);
    defer registry.deinit();
    var clock = Clock.init(testing.io, 0);
    var reference = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer reference.deinit();

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
    var logged_end: u64 = 0;
    for (0..2400) |i| {
        if (i == 800) try aof_writer.start_rewrite(&registry);
        // Spreads the middle of the workload over the rewrite so commands land
        // before, during and after the catch-up and the file switch.
        if (i > 800 and i < 1600 and i % 100 == 0) try Io.sleep(testing.io, .fromMilliseconds(2), .awake);
        if (i == 1600) try wait_for_rewrite(&aof_writer);
        logged_end = try log_workload_step(&aof_writer, &registry, &reference, i);
    }
    try wait_for_rewrite(&aof_writer);

    const info = aof_writer.rewriteInfo();
    try testing.expectEqual(@as(u64, 1), info.count);
    try testing.expect(info.last_ok);
    aof_writer.deinit();

    try testing.expect(try aof_file_len(dir_name) < logged_end);
    try expect_aof_replays_to(dir_name, &registry, &reference);
}

test "aof rewrite keeps durable offsets valid across the file switch" {
    const reg_init = @import("../commands/init_registry.zig");
    const dir_name = "aof_bg_rewrite_durable_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var registry = try reg_init.init_registry(testing.allocator);
    defer registry.deinit();
    var clock = Clock.init(testing.io, 0);
    var reference = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer reference.deinit();

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .always);
    var before_switch: u64 = 0;
    for (0..200) |i| before_switch = try log_workload_step(&aof_writer, &registry, &reference, i);
    try aof_writer.start_rewrite(&registry);
    var during: u64 = 0;
    for (200..400) |i| during = try log_workload_step(&aof_writer, &registry, &reference, i);

    try wait_for_rewrite(&aof_writer);
    try testing.expect(aof_writer.wait_durable(before_switch));
    try testing.expect(aof_writer.wait_durable(during));
    const after = try log_workload_step(&aof_writer, &registry, &reference, 400);
    try testing.expect(after > during);
    try testing.expect(aof_writer.wait_durable(after));
    try testing.expectEqual(@as(u64, 1), aof_writer.rewriteInfo().count);
    aof_writer.deinit();

    try expect_aof_replays_to(dir_name, &registry, &reference);
}

test "aof rewrite that cannot be done leaves the AOF untouched and the writer working" {
    const reg_init = @import("../commands/init_registry.zig");
    const dir_name = "aof_bg_rewrite_refused_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var registry = try reg_init.init_registry(testing.allocator);
    defer registry.deinit();
    var clock = Clock.init(testing.io, 0);
    var reference = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer reference.deinit();

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
    _ = try log_and_apply(&aof_writer, &registry, &reference, &.{ "SET", "plain", "x" });
    _ = try log_and_apply(&aof_writer, &registry, &reference, &.{ "BF.RESERVE", "filter", "0.01", "100" });
    try aof_writer.start_rewrite(&registry);
    try wait_for_rewrite(&aof_writer);

    const info = aof_writer.rewriteInfo();
    try testing.expect(!info.last_ok);
    try testing.expectEqual(@as(u64, 0), info.count);
    try testing.expect(aof_writer.shared.?.next_auto_rewrite_s.load(.acquire) > 0);

    const dir = try Dir.cwd().openDir(testing.io, dir_name, .{});
    defer dir.close(testing.io);
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "test.aof.rewrite.tmp", .{}));

    _ = try log_and_apply(&aof_writer, &registry, &reference, &.{ "SET", "later", "y" });
    aof_writer.deinit();
    try expect_aof_replays_to(dir_name, &registry, &reference);
}

test "aof rewrite is due once the file is big enough and has grown enough" {
    const dir_name = "aof_rewrite_due_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
    defer aof_writer.deinit();
    const shared = aof_writer.shared.?;
    shared.base_size.store(100, .release);

    const cases = [_]struct { size: u64, min_size: u64, percent: u32, due: bool }{
        .{ .size = 200, .min_size = 0, .percent = 100, .due = true },
        .{ .size = 199, .min_size = 0, .percent = 100, .due = false },
        .{ .size = 200, .min_size = 201, .percent = 100, .due = false },
        .{ .size = 200, .min_size = 0, .percent = 0, .due = false },
    };
    for (cases) |case| {
        shared.queued_end = case.size;
        try testing.expectEqual(case.due, aof_writer.rewrite_due(case.min_size, case.percent, 0));
    }

    shared.queued_end = 200;
    shared.next_auto_rewrite_s.store(60, .release);
    try testing.expect(!aof_writer.rewrite_due(0, 100, 59));
    try testing.expect(aof_writer.rewrite_due(0, 100, 60));

    shared.rewrite_active.store(true, .release);
    try testing.expect(!aof_writer.rewrite_due(0, 100, 60));
    shared.rewrite_active.store(false, .release);
}

test "aof rewrite refuses to start while disabled or already running" {
    const reg_init = @import("../commands/init_registry.zig");
    const dir_name = "aof_rewrite_guard_test_dir";
    defer Dir.cwd().deleteTree(testing.io, dir_name) catch {};

    var registry = try reg_init.init_registry(testing.allocator);
    defer registry.deinit();

    var disabled = try Writer.init(testing.allocator, testing.io, false, "unused.aof", "unused", .no);
    defer disabled.deinit();
    try testing.expectError(error.AofDisabled, disabled.start_rewrite(&registry));

    var aof_writer = try Writer.init(testing.allocator, testing.io, true, "test.aof", dir_name, .no);
    defer aof_writer.deinit();
    aof_writer.shared.?.rewrite_active.store(true, .release);
    try testing.expectError(error.RewriteInProgress, aof_writer.start_rewrite(&registry));
    aof_writer.shared.?.rewrite_active.store(false, .release);
}
