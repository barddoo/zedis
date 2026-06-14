const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const default_capacity = 16384;

pub const StackWriter = struct {
    buf: [default_capacity]u8 = undefined,
    overflow: ?std.ArrayListUnmanaged(u8) = null,
    heap_allocator: Allocator,

    pub fn init(heap_allocator: Allocator) StackWriter {
        return .{ .heap_allocator = heap_allocator };
    }

    pub fn writer(self: *StackWriter) Writer {
        return .{
            .vtable = &.{ .drain = drain },
            .buffer = &self.buf,
        };
    }

    pub fn deinit(self: *StackWriter) void {
        if (self.overflow) |*list| {
            list.deinit(self.heap_allocator);
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *StackWriter = @ptrCast(@alignCast(w.buffer.ptr));

        const existing = Writer.buffered(w);
        const new_total = Writer.countSplat(data, splat);

        if (self.overflow == null) {
            var list: std.ArrayListUnmanaged(u8) = .empty;
            list.ensureTotalCapacity(self.heap_allocator, existing.len + new_total) catch return error.WriteFailed;
            if (existing.len > 0) list.appendSliceAssumeCapacity(existing);
            for (data[0 .. data.len - 1]) |buf| {
                list.appendSliceAssumeCapacity(buf);
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                list.appendSliceAssumeCapacity(pattern);
            }
            self.overflow = list;
            w.buffer = list.items;
            w.end = list.items.len;
            return new_total;
        }

        var list = &self.overflow.?;
        list.ensureTotalCapacity(self.heap_allocator, list.items.len + new_total) catch return error.WriteFailed;
        for (data[0 .. data.len - 1]) |buf| {
            list.appendSliceAssumeCapacity(buf);
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            list.appendSliceAssumeCapacity(pattern);
        }
        w.buffer = list.items;
        w.end = list.items.len;
        return new_total;
    }

    pub fn slice(self: *const StackWriter, w: *const Writer) []const u8 {
        if (self.overflow) |*list| {
            return list.items;
        }
        return Writer.buffered(w);
    }

    pub fn toOwnedSlice(self: *StackWriter, w: *const Writer) ![]u8 {
        if (self.overflow) |*list| {
            const result = try list.toOwnedSlice(self.heap_allocator);
            self.overflow = null;
            return result;
        }
        const buffered = Writer.buffered(w);
        if (buffered.len == 0) return buffered;
        return try self.heap_allocator.dupe(u8, buffered);
    }
};
