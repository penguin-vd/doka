//! The app's MCP server (SPEC.md, Claude Code integration): JSON-RPC over HTTP at
//! http://127.0.0.1:7777/mcp, answered from the live state. Only `initialize`, `ping`,
//! `tools/list` and `tools/call`; no streams, no sessions.
//! Requests are read here, on the server's threads; each tool call is handed to the main loop
//! (where the app's state lives) and its answer waited for.
//! Safety: it listens on 127.0.0.1 only, and refuses requests with a browser's Origin header or
//! a Host other than its own, so no web page can reach it.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const c = @import("c.zig");

const Server = @This();

const log = std.log.scoped(.mcp);

pub const port = 7777;
pub const address = "127.0.0.1";
pub const url = "http://127.0.0.1:7777/mcp";
const max_body = 4 << 20;
const versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

/// A tool call waiting for the main loop. `finish` answers it from there.
pub const Call = struct {
    gpa: std.mem.Allocator,
    io: Io,
    name: []const u8,
    // The call's `arguments`, as JSON.
    arguments: []const u8,
    // A whole MCP tool result (`{"content":[…],"isError":…}`), owned by `gpa`.
    result: ?[]u8 = null,
    done: Io.Event = .unset,
    // Whoever is second, the main loop finishing or the server giving up, frees the call.
    state: std.atomic.Value(State) = .init(.pending),
    server: *Server,

    const State = enum(u8) { pending, finished, abandoned };

    pub fn finish(call: *Call, tool_result: []u8) void {
        call.result = tool_result;
        if (call.state.cmpxchgStrong(.pending, .finished, .acq_rel, .acquire) == null) {
            call.done.set(call.io);
        } else {
            call.gpa.free(tool_result);
            freeCall(call);
        }
    }
};

pub const Handler = struct {
    ctx: *anyopaque,
    // Main loop: runs the tool; the call is answered with `Call.finish`, now or later.
    call: *const fn (ctx: *anyopaque, call: *Call) void,
    // Main loop: Claude Code said hello (or anything), for the "connected" pill.
    activity: *const fn (ctx: *anyopaque) void,
    tools: []const u8,
    instructions: []const u8,
};

gpa: std.mem.Allocator,
io: Io,
handler: Handler,
listener: ?Io.net.Server = null,
thread: ?std.Thread = null,

pub fn start(s: *Server) !void {
    const addr = try Io.net.IpAddress.parseIp4(address, port);
    s.listener = try addr.listen(s.io, .{ .reuse_address = true });
    s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
    log.info("Claude Code can connect: claude mcp add --transport http photo {s}", .{url});
}

fn acceptLoop(s: *Server) void {
    while (true) {
        const stream = s.listener.?.accept(s.io) catch |err| {
            log.err("accept: {t}", .{err});
            return;
        };
        const t = std.Thread.spawn(.{}, serveConnection, .{ s, stream }) catch {
            stream.close(s.io);
            continue;
        };
        t.detach();
    }
}

fn serveConnection(s: *Server, stream: Io.net.Stream) void {
    defer stream.close(s.io);
    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(s.io, &in_buf);
    var writer = stream.writer(s.io, &out_buf);
    var server = http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return;
        s.serveRequest(&request) catch |err| {
            log.warn("request: {t}", .{err});
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn serveRequest(s: *Server, request: *http.Server.Request) !void {
    var origin = false;
    var host_ok = false;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = true;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host_ok = hostAllowed(h.value);
    }
    if (origin or !host_ok) return request.respond("forbidden\n", .{ .status = .forbidden, .keep_alive = false });
    if (!std.mem.eql(u8, request.head.target, "/mcp")) return request.respond("not found\n", .{ .status = .not_found });
    if (request.head.method != .POST) return request.respond("", .{
        .status = .method_not_allowed,
        .extra_headers = &.{.{ .name = "allow", .value = "POST" }},
    });

    var body_buf: [8192]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buf);
    const body = try body_reader.allocRemaining(s.gpa, .limited(max_body));
    defer s.gpa.free(body);

    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const reply = try s.answer(arena.allocator(), body);
    if (reply) |json| {
        try request.respond(json, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    } else {
        try request.respond("", .{ .status = .accepted });
    }
}

pub fn hostAllowed(host: []const u8) bool {
    const allowed = [_][]const u8{ "127.0.0.1:7777", "localhost:7777", "127.0.0.1", "localhost" };
    for (allowed) |a| if (std.mem.eql(u8, host, a)) return true;
    return false;
}

/// The JSON-RPC answer to one message, or null for a notification.
pub fn answer(s: *Server, a: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const msg = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch
        return try rpcError(a, .null, -32700, "parse error");
    if (msg != .object) return try rpcError(a, .null, -32600, "expected one JSON-RPC message");
    const id = msg.object.get("id") orelse {
        s.post(.activity, null);
        return null;
    };
    const method = (msg.object.get("method") orelse return try rpcError(a, id, -32600, "no method")).string;
    const params = msg.object.get("params") orelse .null;

    if (std.mem.eql(u8, method, "initialize")) {
        s.post(.activity, null);
        const asked = if (params == .object) if (params.object.get("protocolVersion")) |v| (if (v == .string) v.string else "") else "" else "";
        const version = for (versions) |v| {
            if (std.mem.eql(u8, v, asked)) break v;
        } else versions[0];
        return try result(a, id, .{
            .protocolVersion = version,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "doka", .title = "Doka photo editor", .version = "0.1.0" },
            .instructions = s.handler.instructions,
        });
    }
    if (std.mem.eql(u8, method, "ping")) return try result(a, id, .{});
    if (std.mem.eql(u8, method, "tools/list")) {
        return try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"tools\":{s}}}}}", .{ std.json.fmt(id, .{}), s.handler.tools });
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        if (params != .object) return try rpcError(a, id, -32602, "params must be an object");
        const name = params.object.get("name") orelse return try rpcError(a, id, -32602, "no tool name");
        if (name != .string) return try rpcError(a, id, -32602, "no tool name");
        const args = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
        const tool_result = try s.callTool(name.string, try std.json.Stringify.valueAlloc(a, args, .{}));
        defer s.gpa.free(tool_result);
        return try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{s}}}", .{ std.json.fmt(id, .{}), tool_result });
    }
    return try rpcError(a, id, -32601, "method not found");
}

fn result(a: std.mem.Allocator, id: std.json.Value, value: anytype) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{f}}}", .{ std.json.fmt(id, .{}), std.json.fmt(value, .{}) });
}

fn rpcError(a: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{ std.json.fmt(id, .{}), code, std.json.fmt(message, .{}) });
}

/// A tool result with one text block.
pub fn textResult(gpa: std.mem.Allocator, text: []const u8, is_error: bool) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":{}}}", .{ std.json.fmt(text, .{}), is_error });
}

// How long a tool may take: an export of many photos takes the longest.
const call_timeout_s = 300;

fn callTool(s: *Server, name: []const u8, arguments: []const u8) ![]u8 {
    const call = try s.gpa.create(Call);
    call.* = .{
        .gpa = s.gpa,
        .io = s.io,
        .name = try s.gpa.dupe(u8, name),
        .arguments = try s.gpa.dupe(u8, arguments),
        .server = s,
    };
    s.post(.call, call);
    call.done.waitTimeout(s.io, .{ .duration = .{ .raw = .fromSeconds(call_timeout_s), .clock = .awake } }) catch {
        // Still running on the main loop: it frees the call when it finishes.
        if (call.state.cmpxchgStrong(.pending, .abandoned, .acq_rel, .acquire) == null)
            return textResult(s.gpa, "The app didn't answer in time (is a dialog open?).", true);
        // It finished just now after all.
        call.done.waitUncancelable(s.io);
    };
    defer freeCall(call);
    return call.result orelse textResult(s.gpa, "no result", true);
}

fn freeCall(call: *Call) void {
    call.gpa.free(call.name);
    call.gpa.free(call.arguments);
    call.gpa.destroy(call);
}

const Posted = struct {
    server: *Server,
    kind: enum { call, activity },
    call: ?*Call,
};

fn post(s: *Server, kind: @FieldType(Posted, "kind"), call: ?*Call) void {
    const p = s.gpa.create(Posted) catch return;
    p.* = .{ .server = s, .kind = kind, .call = call };
    _ = c.g_idle_add(onMain, p);
}

fn onMain(ctx: ?*anyopaque) callconv(.c) c_int {
    const p: *Posted = @ptrCast(@alignCast(ctx));
    const s = p.server;
    defer s.gpa.destroy(p);
    switch (p.kind) {
        .activity => s.handler.activity(s.handler.ctx),
        .call => s.handler.call(s.handler.ctx, p.call.?),
    }
    return c.g_source_remove_value;
}
