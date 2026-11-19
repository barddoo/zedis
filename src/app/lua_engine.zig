const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("../storage/store.zig").Store;
const Client = @import("client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");

// LuaJIT (Lua 5.1) C API
pub const State = opaque {};
pub const lua_Integer = isize;
pub const lua_Number = f64;
pub const lua_CFunction = *const fn (*State) callconv(.c) c_int;

pub const REGISTRYINDEX: c_int = -10000;
pub const GLOBALSINDEX: c_int = -10002;
pub const LUA_OK: c_int = 0;
pub const T_NIL: c_int = 0;
pub const T_BOOLEAN: c_int = 1;
pub const T_NUMBER: c_int = 3;
pub const T_STRING: c_int = 4;
pub const T_TABLE: c_int = 5;

extern fn luaL_newstate() ?*State;
extern fn lua_close(L: *State) void;
extern fn luaL_openlibs(L: *State) void;
extern fn lua_settop(L: *State, idx: c_int) void;
extern fn lua_gettop(L: *State) c_int;
extern fn lua_type(L: *State, idx: c_int) c_int;
extern fn lua_toboolean(L: *State, idx: c_int) c_int;
extern fn lua_tointeger(L: *State, idx: c_int) lua_Integer;
extern fn lua_tonumber(L: *State, idx: c_int) lua_Number;
extern fn lua_tolstring(L: *State, idx: c_int, len: ?*usize) ?[*]const u8;
extern fn lua_objlen(L: *State, idx: c_int) usize;
extern fn lua_rawgeti(L: *State, idx: c_int, n: c_int) void;
extern fn lua_rawseti(L: *State, idx: c_int, n: c_int) void;
extern fn lua_createtable(L: *State, narr: c_int, nrec: c_int) void;
extern fn lua_pushlightuserdata(L: *State, p: ?*anyopaque) void;
extern fn lua_pushlstring(L: *State, s: [*]const u8, len: usize) void;
extern fn lua_pushstring(L: *State, s: [*:0]const u8) void;
extern fn lua_pushinteger(L: *State, n: lua_Integer) void;
extern fn lua_pushnumber(L: *State, n: lua_Number) void;
extern fn lua_pushboolean(L: *State, b: c_int) void;
extern fn lua_pushnil(L: *State) void;
extern fn lua_pushcclosure(L: *State, fn_ptr: lua_CFunction, n: c_int) void;
extern fn lua_getfield(L: *State, idx: c_int, k: [*:0]const u8) void;
extern fn lua_setfield(L: *State, idx: c_int, k: [*:0]const u8) void;
extern fn lua_remove(L: *State, idx: c_int) void;
extern fn lua_error(L: *State) c_int;
extern fn luaL_loadbuffer(L: *State, buff: [*]const u8, sz: usize, name: [*:0]const u8) c_int;
extern fn lua_pcall(L: *State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int;
extern fn luaL_error(L: *State, fmt: [*:0]const u8) c_int;

// lua_setglobal/lua_getglobal are #define macros in LuaJIT — wrap as inline Zig
pub inline fn lua_setglobal(L: *State, name: [*:0]const u8) void {
    lua_setfield(L, GLOBALSINDEX, name);
}
pub inline fn lua_getglobal(L: *State, name: [*:0]const u8) void {
    lua_getfield(L, GLOBALSINDEX, name);
}
pub inline fn lua_pop(L: *State, n: c_int) void {
    lua_settop(L, -(n) - 1);
}
pub inline fn lua_newtable(L: *State) void {
    lua_createtable(L, 0, 0);
}

const EvalContext = struct {
    store: *Store,
    client: *Client,
};
var current_ctx: ?EvalContext = null;

fn redis_call_fn(L: *State) callconv(.c) c_int {
    return redis_call_impl(L, true);
}

fn redis_pcall_fn(L: *State) callconv(.c) c_int {
    return redis_call_impl(L, false);
}

fn redis_call_impl(L: *State, raise_errors: bool) c_int {
    const ctx = current_ctx orelse {
        _ = luaL_error(L, "redis.call called outside EVAL context");
        unreachable;
    };

    const n = lua_gettop(L);
    if (n == 0) {
        _ = luaL_error(L, "redis.call requires at least one argument");
        unreachable;
    }

    var args_buf: [128]Value = undefined;
    if (n > args_buf.len) {
        _ = luaL_error(L, "redis.call: too many arguments");
        unreachable;
    }

    for (0..@intCast(n)) |i| {
        const idx: c_int = @intCast(i + 1);
        var slen: usize = 0;
        const s = lua_tolstring(L, idx, &slen) orelse {
            _ = luaL_error(L, "redis.call: argument must be a string or number");
            unreachable;
        };
        args_buf[i] = .{ .data = s[0..slen] };
    }
    const args = args_buf[0..@intCast(n)];

    var resp_buf: [65536]u8 = undefined;
    var tmp_writer: std.Io.Writer = .fixed(&resp_buf);
    ctx.client.server.execute_script_command(ctx.client, args, &tmp_writer);

    const result = tmp_writer.buffered();
    if (result.len == 0) {
        lua_pushnil(L);
        return 1;
    }

    var consumed: usize = 0;
    resp_to_lua(L, result, &consumed) catch {
        _ = luaL_error(L, "redis.call: failed to parse response");
        unreachable;
    };

    // For redis.call (not pcall), re-raise error replies
    if (raise_errors and lua_type(L, -1) == T_TABLE) {
        lua_getfield(L, -1, "err");
        if (lua_type(L, -1) == T_STRING) {
            lua_remove(L, -2);
            _ = lua_error(L);
            unreachable;
        }
        lua_pop(L, 1);
    }

    return 1;
}

fn redis_status_reply_fn(L: *State) callconv(.c) c_int {
    if (lua_gettop(L) < 1) {
        _ = luaL_error(L, "redis.status_reply requires a string argument");
        unreachable;
    }
    var slen: usize = 0;
    const ptr = lua_tolstring(L, 1, &slen) orelse {
        _ = luaL_error(L, "redis.status_reply: argument must be a string");
        unreachable;
    };
    lua_newtable(L);
    lua_pushlstring(L, ptr, slen);
    lua_setfield(L, -2, "ok");
    return 1;
}

fn redis_error_reply_fn(L: *State) callconv(.c) c_int {
    if (lua_gettop(L) < 1) {
        _ = luaL_error(L, "redis.error_reply requires a string argument");
        unreachable;
    }
    var slen: usize = 0;
    const ptr = lua_tolstring(L, 1, &slen) orelse {
        _ = luaL_error(L, "redis.error_reply: argument must be a string");
        unreachable;
    };
    lua_newtable(L);
    lua_pushlstring(L, ptr, slen);
    lua_setfield(L, -2, "err");
    return 1;
}

fn lua_to_resp(L: *State, idx: c_int, writer: *std.Io.Writer) !void {
    const abs: c_int = if (idx < 0) lua_gettop(L) + idx + 1 else idx;
    switch (lua_type(L, abs)) {
        T_NIL => try resp.write_null(writer),
        T_BOOLEAN => {
            if (lua_toboolean(L, abs) != 0)
                try resp.write_int(writer, @as(i64, 1))
            else
                try resp.write_null(writer);
        },
        T_NUMBER => {
            const n = lua_tointeger(L, abs);
            try resp.write_int(writer, @as(i64, n));
        },
        T_STRING => {
            var slen: usize = 0;
            const ptr = lua_tolstring(L, abs, &slen) orelse {
                try resp.write_null(writer);
                return;
            };
            try resp.write_bulk_string(writer, ptr[0..slen]);
        },
        T_TABLE => {
            lua_getfield(L, abs, "ok");
            if (lua_type(L, -1) == T_STRING) {
                var slen: usize = 0;
                const ptr = lua_tolstring(L, -1, &slen) orelse {
                    lua_pop(L, 1);
                    try resp.write_simple_string(writer, "OK");
                    return;
                };
                lua_pop(L, 1);
                try resp.write_simple_string(writer, ptr[0..slen]);
                return;
            }
            lua_pop(L, 1);

            lua_getfield(L, abs, "err");
            if (lua_type(L, -1) == T_STRING) {
                var slen: usize = 0;
                const ptr = lua_tolstring(L, -1, &slen) orelse {
                    lua_pop(L, 1);
                    try resp.write_error(writer, "ERR");
                    return;
                };
                lua_pop(L, 1);
                try resp.write_error(writer, ptr[0..slen]);
                return;
            }
            lua_pop(L, 1);

            const arr_len = lua_objlen(L, abs);
            try resp.write_list_len(writer, arr_len);
            var i: usize = 1;
            while (i <= arr_len) : (i += 1) {
                lua_rawgeti(L, abs, @intCast(i));
                try lua_to_resp(L, -1, writer);
                lua_pop(L, 1);
            }
        },
        else => try resp.write_null(writer),
    }
}

fn resp_to_lua(L: *State, data: []const u8, consumed: *usize) !void {
    if (data.len == 0) return error.InvalidResp;
    switch (data[0]) {
        '+' => {
            const eol = std.mem.indexOf(u8, data[1..], "\r\n") orelse return error.InvalidResp;
            const msg = data[1 .. 1 + eol];
            lua_newtable(L);
            lua_pushlstring(L, msg.ptr, msg.len);
            lua_setfield(L, -2, "ok");
            consumed.* = 1 + eol + 2;
        },
        '-' => {
            const eol = std.mem.indexOf(u8, data[1..], "\r\n") orelse return error.InvalidResp;
            const msg = data[1 .. 1 + eol];
            lua_newtable(L);
            lua_pushlstring(L, msg.ptr, msg.len);
            lua_setfield(L, -2, "err");
            consumed.* = 1 + eol + 2;
        },
        ':' => {
            const eol = std.mem.indexOf(u8, data[1..], "\r\n") orelse return error.InvalidResp;
            const n = std.fmt.parseInt(i64, data[1 .. 1 + eol], 10) catch return error.InvalidResp;
            lua_pushinteger(L, @intCast(n));
            consumed.* = 1 + eol + 2;
        },
        '$' => {
            const eol = std.mem.indexOf(u8, data[1..], "\r\n") orelse return error.InvalidResp;
            const bulk_len = std.fmt.parseInt(i64, data[1 .. 1 + eol], 10) catch return error.InvalidResp;
            const hdr_end = 1 + eol + 2;
            if (bulk_len < 0) {
                lua_pushboolean(L, 0);
                consumed.* = hdr_end;
                return;
            }
            const str_len: usize = @intCast(bulk_len);
            if (hdr_end + str_len + 2 > data.len) return error.InvalidResp;
            lua_pushlstring(L, data[hdr_end..].ptr, str_len);
            consumed.* = hdr_end + str_len + 2;
        },
        '*' => {
            const eol = std.mem.indexOf(u8, data[1..], "\r\n") orelse return error.InvalidResp;
            const count = std.fmt.parseInt(i64, data[1 .. 1 + eol], 10) catch return error.InvalidResp;
            const hdr_end = 1 + eol + 2;
            if (count < 0) {
                lua_pushboolean(L, 0);
                consumed.* = hdr_end;
                return;
            }
            const elem_count: usize = @intCast(count);
            lua_createtable(L, @intCast(elem_count), 0);
            var pos: usize = hdr_end;
            for (1..elem_count + 1) |i| {
                var elem_consumed: usize = 0;
                try resp_to_lua(L, data[pos..], &elem_consumed);
                lua_rawseti(L, -2, @intCast(i));
                pos += elem_consumed;
            }
            consumed.* = pos;
        },
        else => return error.InvalidResp,
    }
}

fn sha1_hex(script: []const u8, out: *[40]u8) void {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(script, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
}

pub const LuaEngine = struct {
    L: *State,
    cache: std.StringHashMapUnmanaged([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !LuaEngine {
        const L = luaL_newstate() orelse return error.OutOfMemory;
        errdefer lua_close(L);

        luaL_openlibs(L);

        const dangerous = [_][*:0]const u8{ "io", "os", "dofile", "loadfile", "require", "load" };
        for (dangerous) |name| {
            lua_pushnil(L);
            lua_setglobal(L, name);
        }

        lua_newtable(L);
        lua_pushcclosure(L, redis_call_fn, 0);
        lua_setfield(L, -2, "call");
        lua_pushcclosure(L, redis_pcall_fn, 0);
        lua_setfield(L, -2, "pcall");
        lua_pushcclosure(L, redis_status_reply_fn, 0);
        lua_setfield(L, -2, "status_reply");
        lua_pushcclosure(L, redis_error_reply_fn, 0);
        lua_setfield(L, -2, "error_reply");
        lua_setglobal(L, "redis");

        return .{
            .L = L,
            .cache = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LuaEngine) void {
        lua_close(self.L);
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cache.deinit(self.allocator);
    }

    pub fn eval(
        self: *LuaEngine,
        writer: *std.Io.Writer,
        store: *Store,
        client: *Client,
        script: []const u8,
        keys: []const Value,
        argv: []const Value,
    ) !void {
        const L = self.L;
        lua_settop(L, 0);

        current_ctx = .{ .store = store, .client = client };
        defer current_ctx = null;

        lua_createtable(L, @intCast(keys.len), 0);
        for (keys, 1..) |k, i| {
            const s = k.as_slice();
            lua_pushlstring(L, s.ptr, s.len);
            lua_rawseti(L, -2, @intCast(i));
        }
        lua_setglobal(L, "KEYS");

        lua_createtable(L, @intCast(argv.len), 0);
        for (argv, 1..) |a, i| {
            const s = a.as_slice();
            lua_pushlstring(L, s.ptr, s.len);
            lua_rawseti(L, -2, @intCast(i));
        }
        lua_setglobal(L, "ARGV");

        const load_rc = luaL_loadbuffer(L, script.ptr, script.len, "@user_script");
        if (load_rc != LUA_OK) {
            var slen: usize = 0;
            if (lua_tolstring(L, -1, &slen)) |ptr| {
                resp.write_error(writer, ptr[0..slen]) catch {};
            } else {
                resp.write_error(writer, "ERR Script compilation error") catch {};
            }
            lua_settop(L, 0);
            return;
        }

        const run_rc = lua_pcall(L, 0, 1, 0);
        if (run_rc != LUA_OK) {
            var slen: usize = 0;
            if (lua_tolstring(L, -1, &slen)) |ptr| {
                resp.write_error(writer, ptr[0..slen]) catch {};
            } else {
                resp.write_error(writer, "ERR Script execution error") catch {};
            }
            lua_settop(L, 0);
            return;
        }

        if (lua_gettop(L) > 0) {
            lua_to_resp(L, -1, writer) catch {
                resp.write_null(writer) catch {};
            };
        } else {
            resp.write_null(writer) catch {};
        }

        lua_settop(L, 0);
    }

    pub fn script_load(self: *LuaEngine, script: []const u8) ![]const u8 {
        var hex_buf: [40]u8 = undefined;
        sha1_hex(script, &hex_buf);

        if (self.cache.getEntry(hex_buf[0..])) |entry| {
            return entry.key_ptr.*;
        }

        const key = try self.allocator.dupe(u8, hex_buf[0..]);
        errdefer self.allocator.free(key);
        const val = try self.allocator.dupe(u8, script);
        errdefer self.allocator.free(val);

        try self.cache.put(self.allocator, key, val);
        return key;
    }

    pub fn script_flush(self: *LuaEngine) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cache.deinit(self.allocator);
        self.cache = .{};
    }

    pub fn script_exists(self: *const LuaEngine, sha: []const u8) bool {
        return self.cache.contains(sha);
    }

    pub fn get_script(self: *const LuaEngine, sha: []const u8) ?[]const u8 {
        return self.cache.get(sha);
    }
};
