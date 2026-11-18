const std = @import("std");
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");

pub fn eval(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const script = args[1].as_slice();
    const numkeys_raw = args[2].as_int() catch {
        return resp.write_error(writer, "ERR value is not an integer or out of range");
    };
    if (numkeys_raw < 0) {
        return resp.write_error(writer, "ERR Number of keys can't be negative");
    }
    const nk: usize = @intCast(numkeys_raw);
    if (3 + nk > args.len) {
        return resp.write_error(writer, "ERR Number of keys can't be greater than number of args");
    }
    const keys = args[3 .. 3 + nk];
    const argv = args[3 + nk ..];
    try client.server.lua_engine.eval(writer, client.store, &client.server.registry, script, keys, argv);
}

pub fn evalsha(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const sha = args[1].as_slice();
    const script = client.server.lua_engine.get_script(sha) orelse {
        return resp.write_error(writer, "NOSCRIPT No matching script. Please use EVAL.");
    };
    const numkeys_raw = args[2].as_int() catch {
        return resp.write_error(writer, "ERR value is not an integer or out of range");
    };
    if (numkeys_raw < 0) {
        return resp.write_error(writer, "ERR Number of keys can't be negative");
    }
    const nk: usize = @intCast(numkeys_raw);
    if (3 + nk > args.len) {
        return resp.write_error(writer, "ERR Number of keys can't be greater than number of args");
    }
    const keys = args[3 .. 3 + nk];
    const argv = args[3 + nk ..];
    try client.server.lua_engine.eval(writer, client.store, &client.server.registry, script, keys, argv);
}

pub fn script_cmd(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const sub = args[1].as_slice();
    if (std.ascii.eqlIgnoreCase(sub, "LOAD")) {
        if (args.len != 3) {
            return resp.write_error(writer, "ERR wrong number of arguments for SCRIPT LOAD");
        }
        const sha = try client.server.lua_engine.script_load(args[2].as_slice());
        return resp.write_bulk_string(writer, sha);
    } else if (std.ascii.eqlIgnoreCase(sub, "EXISTS")) {
        try resp.write_list_len(writer, args.len - 2);
        for (args[2..]) |sha_val| {
            const exists = client.server.lua_engine.script_exists(sha_val.as_slice());
            try resp.write_int(writer, @as(i64, if (exists) 1 else 0));
        }
    } else if (std.ascii.eqlIgnoreCase(sub, "FLUSH")) {
        client.server.lua_engine.script_flush();
        try resp.write_ok(writer);
    } else {
        try resp.write_error(writer, "ERR unknown SCRIPT subcommand");
    }
}
