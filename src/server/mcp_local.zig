//! `publr mcp`: Publr for an agent's tool on this computer, added once for every project. An
//! MCP server over standard input and output that passes each message, as it came, to the
//! site the tool's folder works on (`mcp_local/folder.zig`), signed in as this computer
//! (`mcp_local/sign_in.zig`), and the site's answer back. The tools are the site's, so one
//! `publr` serves sites on any release; only `link` is this program's own.
const std = @import("std");
const credentials = @import("credentials.zig");
const remote = @import("remote.zig");
const mcp = @import("mcp.zig");
const version = @import("../publr.zig").version;
const folder_module = @import("mcp_local/folder.zig");
const sign_in_module = @import("mcp_local/sign_in.zig");
const texts = @import("mcp_local/texts.zig");

const Value = std.json.Value;
const message_bytes_max: u32 = mcp.body_bytes_max;
/// A tool talks to one process for as long as its window is open: no end but its own.
const messages_max: u64 = std.math.maxInt(u64);

const usage =
    \\usage: publr mcp [--folder <path>]
    \\
    \\An MCP server over standard input and output, for an agent's tool on this computer. It
    \\works on the site the folder names in .publr/site, or the site the folder is, and passes
    \\every message there. Without --folder, the folder the tool starts it in.
    \\
;

const instructions = mcp.instructions ++
    \\
    \\
    \\This server works on the Publr site the open folder is linked to. When a tool answers
    \\that the folder is not linked yet, ask your person which site it is for, then call
    \\`link` with its address.
;

const link_tool = "{\"name\":\"link\",\"description\":\"Link the open folder to a " ++
    "Publr site, once, when your person names it: every tool here then works on that " ++
    "site.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"address\":" ++
    "{\"type\":\"string\",\"description\":\"The site's admin address, as your " ++
    "person gives it: https://shop--admin.publr.app\"}},\"required\":[\"address\"]}}";
const no_input = "{\"type\":\"object\",\"properties\":{}}";

/// What the tools are before the site can be asked (not linked, or not signed in yet): the
/// site's three by name, so a tool that never asks again still has them, and `link`.
const stand_ins = "{\"tools\":[{\"name\":\"setup\",\"description\":\"How to work " ++
    "on this site. Call it first.\",\"inputSchema\":" ++ no_input ++ "},{\"name\":" ++
    "\"guide\",\"description\":\"How to build on Publr: read it before anything " ++
    "else.\",\"inputSchema\":" ++ no_input ++ "},{\"name\":\"run\",\"description\":" ++
    "\"Run a publr command on the site, as its words without `publr`.\",\"inputSchema\":" ++
    mcp.run_schema ++ "}," ++ link_tool ++ "]}";

const Local = struct {
    /// The folder the tool started this in.
    start: []const u8,
    sign_in: sign_in_module.SignIn,
    out: *std.Io.Writer,
};

const Site = struct {
    address: []const u8,
    token: []const u8,
};

/// The site to send to, or what to answer instead.
const Reach = union(enum) {
    site: Site,
    says: []const u8,
};

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    std.debug.assert(message_bytes_max > 0);

    const keep = init.arena.allocator();
    const given = folder_flag(args) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const named = given orelse init.environ_map.get("CLAUDE_PROJECT_DIR");
    const line_buffer = try init.gpa.alloc(u8, message_bytes_max);
    defer init.gpa.free(line_buffer);

    var output_buffer: [64 << 10]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, line_buffer);
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var message_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer message_arena.deinit();

    var local: Local = .{
        .start = try folder_module.start_folder(init.io, keep, named),
        .sign_in = .{
            .keep = keep,
        },
        .out = &stdout.interface,
    };
    var count: u64 = 0;

    while (count < messages_max) : (count += 1) {
        const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = try stdin.interface.discardDelimiterInclusive('\n');
                try reply_error(local.out, .null, -32600, "Message too large");
                try local.out.flush();
                continue;
            },
            else => return err,
        } orelse return 0;

        _ = message_arena.reset(.retain_capacity);

        var scoped = init;
        scoped.arena = &message_arena;

        try answer(&local, scoped, line);
        try local.out.flush();
    }

    return 0;
}

/// `--folder <path>`: the path, null without the flag, or (as the outer null) bad words.
fn folder_flag(args: []const []const u8) ??[]const u8 {
    std.debug.assert(args.len <= mcp.args_max);

    if (args.len == 0) {
        return @as(?[]const u8, null);
    }

    if (args.len == 2 and std.mem.eql(u8, args[0], "--folder")) {
        return @as(?[]const u8, args[1]);
    }

    return null;
}

fn answer(local: *Local, init: std.process.Init, line: []const u8) !void {
    std.debug.assert(line.len <= message_bytes_max);

    const arena = init.arena.allocator();
    const text = std.mem.trim(u8, line, " \r\t");

    if (text.len == 0) {
        return;
    }

    const message = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch {
        return reply_error(local.out, .null, -32700, "Parse error");
    };

    if (message != .object) {
        return reply_error(local.out, .null, -32600, "Invalid request");
    }

    const method = string_of(message, "method") orelse "";
    // A notification, or an answer to a request this never makes.
    const id = message.object.get("id") orelse return;

    if (method.len == 0) {
        return;
    }

    dispatch(local, init, .{
        .id = id,
        .message = message,
        .text = text,
    }, method) catch |err| {
        // A site that cannot be reached, or a file that cannot be written: the agent hears
        // why, and this keeps serving.
        const said = try std.fmt.allocPrint(arena, "publr: {t}", .{err});

        try text_result(local.out, id, said, true);
    };
}

fn dispatch(local: *Local, init: std.process.Init, asked: Asked, method: []const u8) !void {
    std.debug.assert(asked.message == .object);
    std.debug.assert(method.len > 0);

    if (eql(method, "initialize")) {
        return initialize(local, asked.id, asked.message);
    }

    if (eql(method, "ping")) {
        return write_result(local.out, asked.id, struct {}{});
    }

    if (eql(method, "tools/list")) {
        return list(local, init, asked.id, asked.text);
    }

    if (eql(method, "tools/call")) {
        return call(local, init, asked);
    }

    return reply_error(local.out, asked.id, -32601, "Method not found");
}

fn initialize(local: *Local, id: Value, message: Value) !void {
    std.debug.assert(message == .object);

    const params = message.object.get("params") orelse Value.null;
    const client = if (params == .object) params.object.get("clientInfo") else null;
    const client_name = if (client) |info| (if (info == .object)
        string_of(info, "name") orelse ""
    else
        "") else "";

    if (local.sign_in.name.len == 0) {
        local.sign_in.name = try sign_in_module.device_name(local.sign_in.keep, client_name);
    }

    std.debug.assert(local.sign_in.name.len > 0);

    try write_result(local.out, id, .{
        .protocolVersion = mcp.protocol_version,
        .capabilities = .{
            .tools = .{
                .listChanged = true,
            },
        },
        .serverInfo = .{
            .name = "publr",
            .version = version,
        },
        .instructions = instructions,
    });
}

/// The site's tools and `link`; the stand-ins while the site cannot be asked.
fn list(local: *Local, init: std.process.Init, id: Value, text: []const u8) !void {
    std.debug.assert(text.len > 0);

    const arena = init.arena.allocator();
    const reached = try reach(local, init, false);

    if (reached == .site) {
        if (forward(init, reached.site, text)) |reply| {
            const tools = tools_of(arena, reply);

            if (tools) |found| {
                const link_value = try std.json.parseFromSliceLeaky(Value, arena, link_tool, .{});

                try found.array.append(link_value);
                return write_json(local.out, found.message);
            }
        } else |err| {
            std.log.warn("{s}: {t}", .{ reached.site.address, err });
        }
    }

    const fallback = try std.json.parseFromSliceLeaky(Value, arena, stand_ins, .{});

    try write_result(local.out, id, fallback);
}

const Tools = struct {
    message: Value,
    array: *std.json.Array,
};

/// The site's answer to `tools/list`, and its list to add to; null when it is not one.
fn tools_of(arena: std.mem.Allocator, reply: remote.Reply) ?Tools {
    std.debug.assert(reply.body.len <= 64 << 20);

    if (reply.status != .ok) {
        return null;
    }

    const message = std.json.parseFromSliceLeaky(Value, arena, reply.body, .{}) catch {
        return null;
    };
    const result = if (message == .object) message.object.getPtr("result") else null;
    const holder = result orelse return null;
    const tools = if (holder.* == .object) holder.object.getPtr("tools") else null;
    const array = tools orelse return null;

    if (array.* != .array) {
        return null;
    }

    return .{
        .message = message,
        .array = &array.array,
    };
}

const Asked = struct {
    id: Value,
    message: Value,
    text: []const u8,
};

fn call(local: *Local, init: std.process.Init, asked: Asked) !void {
    std.debug.assert(asked.message == .object);

    const arena = init.arena.allocator();
    const params = asked.message.object.get("params") orelse {
        return reply_error(local.out, asked.id, -32602, "No params");
    };
    const tool = if (params == .object) string_of(params, "name") orelse "" else "";

    if (eql(tool, "link")) {
        return link(local, init, asked.id, params);
    }

    const site = switch (try reach(local, init, true)) {
        .site => |found| found,
        .says => |text| return text_result(local.out, asked.id, text, true),
    };
    const reply = forward(init, site, asked.text) catch |err| {
        const text = try std.fmt.allocPrint(arena, "Could not reach {s}: {t}", .{
            site.address,
            err,
        });

        return text_result(local.out, asked.id, text, true);
    };

    if (reply.status == .unauthorized) {
        _ = try credentials.remove(init, site.address);

        const text = try std.fmt.allocPrint(arena, "This computer's sign-in to {s} was " ++
            "revoked or has expired. Ask again: your person approves it anew.", .{site.address});

        return text_result(local.out, asked.id, text, true);
    }

    if (reply.status != .ok) {
        const text = try std.fmt.allocPrint(arena, "{s} answered {d}", .{
            site.address,
            @intFromEnum(reply.status),
        });

        return text_result(local.out, asked.id, text, true);
    }

    try local.out.writeAll(std.mem.trim(u8, reply.body, " \r\n\t"));
    try local.out.writeByte('\n');
}

/// The site the folder works on and this computer's token for it; with `ask`, the person
/// asked in the browser when there is none yet.
fn reach(local: *Local, init: std.process.Init, ask: bool) !Reach {
    std.debug.assert(local.start.len > 0);

    const arena = init.arena.allocator();
    const named = switch (try folder_module.find(init.io, arena, local.start)) {
        .linked, .serving => |found| found.address,
        .stopped => |found| return .{
            .says = try texts.stopped(arena, found.folder),
        },
        .none => return .{
            .says = try texts.not_linked(init, local.start),
        },
    };
    const address = try credentials.normalize(arena, named) orelse {
        return .{
            .says = try texts.bad_link(arena, named),
        };
    };

    if (!ask) {
        const kept = try credentials.find(init, address) orelse return .{
            .says = "",
        };

        return .{
            .site = .{
                .address = address,
                .token = kept.token,
            },
        };
    }

    return switch (try local.sign_in.token(init, address)) {
        .token => |token| .{
            .site = .{
                .address = address,
                .token = token,
            },
        },
        .waiting => |approve| .{
            .says = try texts.waiting(arena, approve),
        },
        .refused => |state| .{
            .says = try texts.refused(arena, state),
        },
    };
}

/// `link`: names the site the folder works on, then signs this computer in to it.
fn link(local: *Local, init: std.process.Init, id: Value, params: Value) !void {
    std.debug.assert(params == .object);

    const arena = init.arena.allocator();
    const arguments = params.object.get("arguments") orelse Value.null;
    const typed = if (arguments == .object) string_of(arguments, "address") else null;
    const given = typed orelse {
        return text_result(local.out, id, "`address` is the site's admin address", true);
    };
    // The MCP address, `<admin>/mcp`, names the same site.
    const site_part = if (std.mem.endsWith(u8, given, mcp.route))
        given[0 .. given.len - mcp.route.len]
    else
        given;
    const named = try credentials.normalize(arena, site_part) orelse {
        return text_result(local.out, id, try texts.bad_link(arena, given), true);
    };

    if (!texts.linkable(init, local.start)) {
        return text_result(local.out, id, try texts.no_project(arena, local.start), true);
    }

    if (try folder_module.is_site(init.io, arena, local.start)) {
        return text_result(local.out, id, texts.is_a_site, true);
    }

    const address = remote.settle(init.io, arena, named) catch {
        return text_result(local.out, id, try texts.bad_link(arena, named), true);
    };

    // Signed in first, so a folder is only ever linked to a site that answered.
    const outcome = local.sign_in.token(init, address) catch |err| {
        const text = try std.fmt.allocPrint(arena, "Could not reach {s} ({t}). Check the " ++
            "address with your person.", .{ address, err });

        return text_result(local.out, id, text, true);
    };

    try folder_module.link(init.io, arena, local.start, address);

    const text = switch (outcome) {
        .token => try std.fmt.allocPrint(arena, "This folder ({s}) now works on {s}.", .{
            local.start,
            address,
        }),
        .waiting => |approve| try texts.waiting(arena, approve),
        .refused => |state| try texts.refused(arena, state),
    };

    try text_result(local.out, id, text, false);
    try write_json(local.out, .{
        .jsonrpc = "2.0",
        .method = "notifications/tools/list_changed",
    });
}

fn forward(init: std.process.Init, site: Site, text: []const u8) !remote.Reply {
    std.debug.assert(site.token.len > 0);
    std.debug.assert(text.len > 0);

    const arena = init.arena.allocator();

    return remote.post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, mcp.route }),
        .payload = text,
        .token = site.token,
    });
}

fn write_json(out: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, out);
    try out.writeByte('\n');
}

fn write_result(out: *std.Io.Writer, id: Value, value: anytype) !void {
    try write_json(out, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = value,
    });
}

fn text_result(out: *std.Io.Writer, id: Value, text: []const u8, failed: bool) !void {
    std.debug.assert(text.len > 0);

    try write_result(out, id, .{
        .content = .{.{
            .type = "text",
            .text = text,
        }},
        .isError = failed,
    });
}

fn reply_error(out: *std.Io.Writer, id: Value, code: i32, text: []const u8) !void {
    std.debug.assert(text.len > 0);

    try write_json(out, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{
            .code = code,
            .message = text,
        },
    });
}

fn string_of(value: Value, key: []const u8) ?[]const u8 {
    const found = value.object.get(key) orelse return null;

    return if (found == .string) found.string else null;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "the stand-in tools are the site's three by name, and link" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const parsed = try std.json.parseFromSliceLeaky(Value, arena_state.allocator(), stand_ins, .{});
    const tools = parsed.object.get("tools").?.array.items;

    try std.testing.expectEqual(@as(usize, 4), tools.len);
    try std.testing.expectEqualStrings("setup", tools[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("run", tools[2].object.get("name").?.string);
    try std.testing.expectEqualStrings("link", tools[3].object.get("name").?.string);
    try std.testing.expect(folder_flag(&.{"--folder"}) == null);
    try std.testing.expectEqualStrings("/a", folder_flag(&.{ "--folder", "/a" }).?.?);
}

test "the site's tools gain link" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const reply: remote.Reply = .{
        .status = .ok,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"run\"}]}}",
    };
    const found = tools_of(arena, reply).?;

    try std.testing.expectEqual(@as(usize, 1), found.array.items.len);
    try std.testing.expect(tools_of(arena, .{
        .status = .unauthorized,
        .body = "{}",
    }) == null);
}

test {
    std.testing.refAllDecls(folder_module);
    std.testing.refAllDecls(sign_in_module);
    std.testing.refAllDecls(texts);
}
