//! `/mcp`: this Publr for MCP clients (Streamable HTTP, JSON answers, no streams), signed in
//! as a device through OAuth (`oauth.zig`). Three tools: `guide`, how to build on Publr;
//! `setup`, how to work with the CLI on this computer when the site is on it; and `run`, a
//! command's words run here as the device, as `/api/cli` runs them.

const std = @import("std");
const http = @import("../lib/http.zig");
const sdk = @import("../sdk.zig");
const version = @import("../publr.zig").version;
const registry = @import("registry.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const credentials = @import("credentials.zig");
const remote = @import("remote.zig");
const oauth = @import("oauth.zig");
const agents = @import("agents.zig");
const Project = @import("project.zig").Project;

const Request = http.Request;
const Response = http.Response;
const Context = http.Context;
const Value = std.json.Value;

pub const route = oauth.mcp_path;
pub const protocol_version = "2025-06-18";
pub const args_max: u32 = 64;
pub const body_bytes_max: u32 = 1 << 20;

const instructions =
    \\This server is one Publr site, the one its person approved. Call `setup` first: it says
    \\what this device may do and how to work. If the site is on this computer, you edit its
    \\files with your own tools and run the publr CLI in its folder. Otherwise run publr
    \\commands with the `run` tool, as words: ["record", "list", "--type", "post"]. Read
    \\`guide` before building anything. Whenever you work in a branch, end your reply to your
    \\person with its merge link, the `merge` address that making it answered.
;

const preamble =
    \\# You are connected to the Publr site at {s}
    \\
    \\The guide below is written for someone running `publr` in a site's folder. Call
    \\`setup`: when this site is on this computer it says where its folder is, and you work
    \\there with your own file tools and the CLI, never `run`, in place of `--as-admin` the
    \\`--device` it gives you. When it is not, every `publr <words>` in the guide is the
    \\`run` tool with those words, without `publr` (`publr content_type list` is `run` with
    \\["content_type", "list"]); `--as` and `--as-admin` do not apply, you act as the person
    \\who connected you. Pages and other app files are then `apps files`,
    \\`apps read --path <path>` and `apps write --path <path> --content <text>`.
    \\
    \\
;

const run_schema =
    \\{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},
    \\"description":"The command's words, as after `publr`: [\"record\", \"list\"]"}},
    \\"required":["args"]}
;
const empty_schema =
    \\{"type":"object","properties":{}}
;

/// `POST /mcp`: one JSON-RPC message from a client signed in as a device.
pub fn handle(request: *Request, response: *Response, ctx: *Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .post);

    const project = Project.of(ctx);
    const identity = identity_module.identify(request, ctx.arena, project);

    if (identity.caller != .token) {
        return unauthorized(project, request, response, ctx.arena);
    }

    if (request.body.len > body_bytes_max) {
        return response.json(.payload_too_large, .{
            .@"error" = "too_large",
        });
    }

    const message = std.json.parseFromSliceLeaky(Value, ctx.arena, request.body, .{}) catch {
        return rpc_error(response, .null, -32700, "Parse error");
    };

    if (message != .object) {
        return rpc_error(response, .null, -32600, "Invalid request");
    }

    const method = string_of(message, "method") orelse "";
    // A notification: nothing to answer.
    const id = message.object.get("id") orelse return response.text(.accepted, "");

    if (eql(method, "initialize")) {
        return result(response, id, .{
            .protocolVersion = protocol_version,
            .capabilities = .{
                .tools = .{
                    .listChanged = false,
                },
            },
            .serverInfo = .{
                .name = "publr",
                .version = version,
            },
            .instructions = instructions,
        });
    }

    if (eql(method, "ping")) {
        return result(response, id, .{});
    }

    if (eql(method, "tools/list")) {
        return tools(response, ctx.arena, id);
    }

    if (eql(method, "tools/call")) {
        return call(project, request, response, ctx.arena, .{
            .id = id,
            .message = message,
            .device = identity.caller,
        });
    }

    return rpc_error(response, id, -32601, "Method not found");
}

/// `GET /mcp`: no stream to open; everything is answered as it is asked.
pub fn refuse_stream(request: *Request, response: *Response, ctx: *Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    try response.set_header("Allow", "POST");
    try response.text(.method_not_allowed, "Use POST\n");
}

fn unauthorized(
    project: *const Project,
    request: *const Request,
    response: *Response,
    arena: std.mem.Allocator,
) http.Error!void {
    std.debug.assert(request.path().len > 0);

    const base = try oauth.base_of(project, request, arena);
    const challenge = try std.fmt.allocPrint(
        arena,
        "Bearer resource_metadata=\"{s}{s}\"",
        .{ base, oauth.resource_route },
    );

    try response.set_header("WWW-Authenticate", challenge);
    try response.json(.unauthorized, .{
        .@"error" = "invalid_token",
    });
}

fn tools(response: *Response, arena: std.mem.Allocator, id: Value) http.Error!void {
    std.debug.assert(run_schema.len > 0);

    const run_input = std.json.parseFromSliceLeaky(Value, arena, run_schema, .{}) catch {
        return error.OutOfMemory;
    };
    const empty_input = std.json.parseFromSliceLeaky(Value, arena, empty_schema, .{}) catch {
        return error.OutOfMemory;
    };

    try result(response, id, .{
        .tools = .{
            .{
                .name = "setup",
                .description = "Whether this site is on this computer, and if so how to work " ++
                    "with its publr CLI in its folder. Call it first.",
                .inputSchema = empty_input,
            },
            .{
                .name = "guide",
                .description = "How to build on Publr: read it before anything else.",
                .inputSchema = empty_input,
            },
            .{
                .name = "run",
                .description = "Run a publr command on the site, as its words without " ++
                    "`publr`. Start with [\"--help\"]; every namespace and command takes --help.",
                .inputSchema = run_input,
            },
        },
    });
}

const Call = struct {
    id: Value,
    message: Value,
    device: sdk.Caller,
};

fn call(
    project: *const Project,
    request: *const Request,
    response: *Response,
    arena: std.mem.Allocator,
    asked: Call,
) http.Error!void {
    std.debug.assert(asked.device == .token);

    const params = asked.message.object.get("params") orelse {
        return rpc_error(response, asked.id, -32602, "No params");
    };
    const tool = if (params == .object) string_of(params, "name") orelse "" else "";

    if (eql(tool, "guide")) {
        const base = try oauth.base_of(project, request, arena);
        const text = try std.fmt.allocPrint(arena, preamble ++ "{s}", .{ base, agents.guide });

        return text_result(response, asked.id, text, false);
    }

    if (eql(tool, "setup")) {
        const text = try setup_of(project, request, arena, asked.device.token);

        return text_result(response, asked.id, text, false);
    }

    if (!eql(tool, "run")) {
        return rpc_error(response, asked.id, -32602, "Unknown tool");
    }

    const args = try args_of(arena, params) orelse {
        return text_result(response, asked.id, "`args` must be a list of words, at most 64", true);
    };
    const answer = try remote.run_in(project, arena, asked.device, args);
    const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ answer.out, answer.err });

    try text_result(response, asked.id, text, answer.code != 0);
}

/// What this device may do here and how to work: on this computer, with the folder `serve`
/// runs in and no host running it, in that folder with its binary as the device; anywhere
/// else with `run`.
fn setup_of(
    project: *const Project,
    request: *const Request,
    arena: std.mem.Allocator,
    device: sdk.Caller.Token,
) http.Error![]const u8 {
    std.debug.assert(project.folder.len == 0 or project.binary.len > 0);
    std.debug.assert(device.id.len > 0);

    const host = request.header("host") orelse "";
    const here = !registry.hosted and project.folder.len > 0 and
        credentials.host_on_this_machine(host);
    const on_copies = device.scope == .write and registry.copies_list != null;

    if (!here) {
        return setup_elsewhere(project, request, arena, device.scope, on_copies);
    }

    const site = if (project.site_origin.len > 0)
        project.site_origin
    else
        try oauth.base_of(project, request, arena);
    const as_device = try std.fmt.allocPrint(arena, "{s} --device {s}", .{
        project.binary,
        device.id,
    });

    if (device.scope == .read) {
        return std.fmt.allocPrint(arena,
            \\This site is on this computer, in {s}. This device may only read: change nothing.
            \\
            \\- Read its files with your own file tools: apps/<app>/ and plugins/<name>/.
            \\- Content and settings are in the database: `{s} <command>` in that folder
            \\  (`{s} --help` lists them). Never `--as-admin`.
            \\- The site is at {s}.
        , .{ project.folder, as_device, as_device, site }) catch error.OutOfMemory;
    }

    if (on_copies) {
        return std.fmt.allocPrint(arena,
            \\This site is on this computer, in {s}. This device works on copies of it: never
            \\change the files in that folder, and never use `--as-admin`. For each task, there:
            \\
            \\1. `{s} environments create --kind branch --name "<the task>"`. It answers the
            \\   branch's `name`, `address` and `merge`.
            \\2. `{s} environments locate --name <name>` answers its `folder`. Read and edit
            \\   the files there as in any codebase, with your own file tools: apps/<app>/
            \\   (pages, layouts, components, public/) and plugins/<name>/. Its server watches
            \\   apps/: a saved file is live on the branch within half a second.
            \\3. Content, content types and settings: `{s} --env <name> --device {s} <command>`
            \\   from this site's folder. `{s} --help` lists the commands.
            \\4. Always end your reply with the `merge` address it answered: your person reviews
            \\   the branch there and merges it into the live site.
        , .{
            project.folder,
            as_device,
            as_device,
            project.binary,
            device.id,
            as_device,
        }) catch error.OutOfMemory;
    }

    const drafts: []const u8 = if (device.scope == .publish)
        ""
    else
        "\n- Content you change waits as drafts: your person publishes it.";

    return std.fmt.allocPrint(arena,
        \\This site is on this computer, in {s}. Work there as in any codebase:
        \\
        \\- Read and edit its files with your own file tools: apps/<app>/ (pages, layouts,
        \\  components, public/) and plugins/<name>/. Never use `apps read`, `apps write` or
        \\  the `run` tool for files: those are for a site on another computer.
        \\- The running server watches apps/: a saved file is live within half a second.
        \\  `{s} apps load` in that folder says why a change did not load.
        \\- Content, content types and settings live in the database, not in files: change
        \\  them with `{s} <command>` in that folder (`{s} --help` lists them). That is how
        \\  your work carries this device's name: never `--as-admin`.{s}
        \\- The site is at {s}.
    , .{
        project.folder,
        as_device,
        as_device,
        as_device,
        drafts,
        site,
    }) catch error.OutOfMemory;
}

/// A site elsewhere: `run`, and where it keeps copies, a clone for an agent with a terminal.
fn setup_elsewhere(
    project: *const Project,
    request: *const Request,
    arena: std.mem.Allocator,
    scope: @import("../model/device.zig").Scope,
    on_copies: bool,
) http.Error![]const u8 {
    std.debug.assert(!on_copies or scope == .write);

    if (scope == .read) {
        return "This site runs on another computer, and this device may only read. Run " ++
            "publr commands with the `run` tool; change nothing.";
    }

    const by_run: []const u8 = if (on_copies)
        "This site runs on another computer, and this device works on copies of it. " ++
            "With the `run` tool: make one for each task, [\"environments\", \"create\", " ++
            "\"--kind\", \"branch\", \"--name\", \"<the task>\"], then put \"--env\" " ++
            "and its name first in every command: [\"--env\", \"<name>\", \"record\", " ++
            "\"list\"]. Always end your reply with the `merge` address making it answered: " ++
            "your person reviews it there and merges it."
    else
        "This site runs on another computer. Run every publr command with the `run` tool. " ++
            "Where the site has environments or branches, put \"--env\" and a name first to " ++
            "run a command in one.";

    if (registry.copies_list == null) {
        return by_run;
    }

    const base = try oauth.base_of(project, request, arena);

    return std.fmt.allocPrint(arena,
        \\If you can run commands on this computer, work on a local copy of the site instead:
        \\
        \\1. In an empty folder:
        \\   `curl -fsSL https://publr.dev/install.sh | PUBLR_HOME=. PUBLR_VERSION=v{s} sh`
        \\2. `./publr clone {s} site`. It opens your person's browser once to approve it.
        \\3. `cd site && ../publr serve` (in the background). Build there as in any codebase, with
        \\   your own file tools and `../publr --as-admin <command>`.
        \\4. `../publr push` sends the folder up as a branch. Give your person the links it prints:
        \\   they review it and merge it. Nothing you do there touches the live site.
        \\
        \\Otherwise: {s}
    , .{ version, base, by_run }) catch error.OutOfMemory;
}

fn args_of(arena: std.mem.Allocator, params: Value) error{OutOfMemory}!?[]const []const u8 {
    std.debug.assert(args_max > 0);

    const arguments = if (params == .object) params.object.get("arguments") else null;
    const holder = arguments orelse return null;
    const list = if (holder == .object) holder.object.get("args") orelse return null else {
        return null;
    };

    if (list != .array or list.array.items.len == 0 or list.array.items.len > args_max) {
        return null;
    }

    const words = try arena.alloc([]const u8, list.array.items.len);

    for (list.array.items, words) |item, *word| {
        if (item != .string) {
            return null;
        }

        word.* = item.string;
    }

    return words;
}

fn text_result(response: *Response, id: Value, text: []const u8, failed: bool) http.Error!void {
    std.debug.assert(text.len <= 64 << 20);

    try result(response, id, .{
        .content = .{.{
            .type = "text",
            .text = text,
        }},
        .isError = failed,
    });
}

fn result(response: *Response, id: Value, value: anytype) http.Error!void {
    try response.json(.ok, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = value,
    });
}

fn rpc_error(response: *Response, id: Value, code: i32, text: []const u8) http.Error!void {
    std.debug.assert(text.len > 0);

    try response.json(.ok, .{
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
