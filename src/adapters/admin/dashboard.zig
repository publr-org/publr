const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const definitions = @import("definitions.zig");
const credentials = @import("../../server/credentials.zig");
const ai = @import("../../operations/ai.zig");
const ai_model = @import("../../model/ai.zig");
const people = @import("../../operations/device/people.zig");
const activity = @import("../../operations/activity.zig");
const health = @import("../../operations/health.zig");
const statuses = @import("../../operations/status.zig");
const role = @import("../../model/role.zig");
const agent_setup = @import("agent_setup.zig");
const oauth = @import("../../server/oauth.zig");

const Props = admin.views.Dashboard.Props;
const Earlier = admin.views.Dashboard.EarlierItem;
const Waiting = admin.views.Dashboard.WaitingItem;
const Change = admin.views.Dashboard.ChangesItem;

/// The tools the Overview names, the last used first.
const devices_shown_max: u32 = 3;

/// The changes the Overview lists.
const changes_shown_max: u32 = 6;

/// Everything the Overview shows: how to connect a tool, or once one is what changed and what
/// waits; and the person's conversations.
pub fn props_of(session: *admin.Session) admin.Error!Props {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.project.folder.len == 0 or session.project.binary.len > 0);

    const connected = ai.connected(&session.ctx);
    const asked = admin.query_param(session, "ask") orelse "";
    const tool_names = try tool_names_of(session);
    var props: Props = .{
        .tool = if (asked.len > 0 or tool_names.len > 0) "" else tool_of(session),
        .connected = connected,
        .tool_names = tool_names,
        .waiting = &.{},
        .changes = &.{},
        .sees_changes = session.ctx.caller.holds(role.admin),
        .asked = asked,
        .asked_on = admin.query_param(session, "page") orelse "",
        .folder_command = "",
        .install_command = "",
        .login_command = "",
        .agent_command = "",
        .agent_prompt = "",
        .earlier = &.{},
        .mcp_address = "",
        .cursor_link = "",
        .reachable = reachable(session),
    };

    if (tool_names.len > 0) {
        props.waiting = try waiting_of(session);
        props.changes = if (props.sees_changes) try changes_of(session) else &.{};
    }

    if (props.tool.len > 0) {
        const mcp = try mcp_of(session);

        props.mcp_address = mcp.address;
        props.cursor_link = mcp.cursor_link;
    }

    try fill_conversations(session, &props);

    return props;
}

/// `GET /admin/agents`: the Overview's agents step for a tool that opens the agent's terminal
/// itself (the Companion's side panel): the folder to open it in and the commands to run there.
pub fn agents_step(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = admin.Session.open(request, response, ctx);

    if (!session.signed_in() or !registry.SDK.reaches_admin(&session.ctx)) {
        return response.json(.unauthorized, .{
            .@"error" = "sign_in_required",
        });
    }

    var props: Props = .{
        .tool = "other",
        .connected = false,
        .tool_names = "",
        .waiting = &.{},
        .changes = &.{},
        .sees_changes = false,
        .folder_command = "",
        .install_command = "",
        .login_command = "",
        .agent_command = "",
        .agent_prompt = "",
        .earlier = &.{},
        .mcp_address = "",
        .cursor_link = "",
        .reachable = false,
    };

    try fill_agents(&session, &props);

    const here = props.folder_command.len > 0;

    try response.json(.ok, .{
        .folder = if (here) session.project.folder else null,
        .binary = if (here) session.project.binary else null,
        .folder_command = props.folder_command,
        // The Companion runs it in the folder it opened: only the site's own folder has it.
        .install_command = if (here) props.install_command else "",
        .login_command = props.login_command,
    });
}

/// The tools connected to this site, whoever connected them, named; empty means it is still
/// to set up.
fn tool_names_of(session: *admin.Session) admin.Error![]const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(devices_shown_max > 0);

    const arena = session.arena;
    const found = people.recently_used(&session.ctx, devices_shown_max) catch {
        return error.OutOfMemory;
    };
    const names = try arena.alloc([]const u8, found.len);

    for (found, names) |device, *name| {
        name.* = device.name;
    }

    return std.mem.join(arena, ", ", names);
}

/// What only a person can settle: drafts, Site Health's open cases. Only what there is.
fn waiting_of(session: *admin.Session) admin.Error![]const Waiting {
    std.debug.assert(session.signed_in());

    const drafts = statuses.drafts_waiting(&session.ctx) catch 0;
    const counted = registry.SDK.dispatch(&session.ctx, health.Count, .{}) catch null;
    const issues = if (counted) |found| found.count else 0;
    var waiting: std.ArrayList(Waiting) = .empty;

    if (drafts > 0) {
        try waiting.append(session.arena, .{
            .label = try session.translated_count(
                "{count} draft not published",
                "{count} drafts not published",
                drafts,
            ),
            .href = "/admin/content?status=is:draft",
        });
    }

    if (issues > 0) {
        try waiting.append(session.arena, .{
            .label = try session.translated_count(
                "{count} issue in Site Health",
                "{count} issues in Site Health",
                issues,
            ),
            .href = "/admin/health",
        });
    }

    return waiting.items;
}

/// What the Overview lists as a change, and how it says it (`translated_in("change", …)`).
const change_labels = [_][2][]const u8{
    .{ "record.create", "Created" },
    .{ "record.save", "Edited" },
    .{ "record.publish", "Published" },
    .{ "record.publish_version", "Published" },
    .{ "record.transition", "Changed status of" },
    .{ "record.delete", "Deleted" },
    .{ "content_type.create", "Added content type" },
    .{ "content_type.update", "Changed content type" },
    .{ "content_type.delete", "Removed content type" },
    .{ "apps.write", "Edited" },
    .{ "apps.edit", "Edited" },
    .{ "apps.remove", "Deleted" },
    .{ "plugin.install", "Added plugin" },
    .{ "plugin.add", "Added plugin" },
    .{ "plugin.enable", "Turned on plugin" },
    .{ "plugin.disable", "Turned off plugin" },
    .{ "plugin.remove", "Removed plugin" },
    .{ "merge.accept", "Merged branch" },
};

const change_operations = names: {
    var json: []const u8 = "[";

    for (change_labels, 0..) |pair, index| {
        json = json ++ (if (index == 0) "\"" else ",\"") ++ pair[0] ++ "\"";
    }

    break :names json ++ "]";
};

/// What changed on the site lately, each said in the person's language.
fn changes_of(session: *admin.Session) admin.Error![]const Change {
    std.debug.assert(session.signed_in());
    std.debug.assert(changes_shown_max > 0);

    const arena = session.arena;
    const found = activity.recent_changes(
        &session.ctx,
        change_operations,
        changes_shown_max,
    ) catch return error.OutOfMemory;
    const changes = try arena.alloc(Change, found.len);

    for (found, changes) |change, *row| {
        const deleted = std.mem.eql(u8, change.operation, "record.delete");
        const gone = std.mem.startsWith(u8, change.operation, "record.") and
            change.subject.len == 0;

        row.* = .{
            .who = try who_of(session, change),
            .action = try action_of(session, change),
            .subject = if (gone)
                try session.translated("Removed record", .{})
            else
                change.subject,
            .href = if (change.record.len > 0 and !deleted)
                try std.fmt.allocPrint(arena, "/admin/content/{s}", .{change.record})
            else
                "",
            .when = try ago_of(session, change.at),
        };
    }

    return changes;
}

fn who_of(session: *const admin.Session, change: activity.Change) admin.Error![]const u8 {
    std.debug.assert(change.at >= 0);

    return switch (change.who) {
        .you => session.translated("You", .{}),
        // On a host nobody is at the site's own computer: it is the platform's doing.
        .operator => if (registry.hosted)
            session.translated("System", .{})
        else
            session.translated("Command line", .{}),
        .named => change.name,
    };
}

fn action_of(session: *const admin.Session, change: activity.Change) admin.Error![]const u8 {
    std.debug.assert(change.operation.len > 0);

    const published = std.mem.eql(u8, change.operation, "record.transition") and
        std.mem.eql(u8, change.transition, "publish");

    if (published) {
        return session.translated_in("change", "Published");
    }

    for (change_labels) |pair| {
        if (std.mem.eql(u8, pair[0], change.operation)) {
            return session.translated_in("change", pair[1]);
        }
    }

    return change.operation;
}

/// How long ago, in words for the first week, then the date.
fn ago_of(session: *const admin.Session, at: i64) admin.Error![]const u8 {
    std.debug.assert(at >= 0);

    const minutes = @divFloor(session.ctx.now_ms - at, std.time.ms_per_min);

    if (minutes < 1) {
        return session.translated("Just now", .{});
    }

    if (minutes < 60) {
        return session.translated_count(
            "{count} minute ago",
            "{count} minutes ago",
            @intCast(minutes),
        );
    }

    if (minutes < 24 * 60) {
        return session.translated_count(
            "{count} hour ago",
            "{count} hours ago",
            @intCast(@divFloor(minutes, 60)),
        );
    }

    if (minutes < 7 * 24 * 60) {
        return session.translated_count(
            "{count} day ago",
            "{count} days ago",
            @intCast(@divFloor(minutes, 24 * 60)),
        );
    }

    return admin.time_text(session.arena, at)[0.."YYYY-MM-DD".len];
}

/// The tool picked to connect, its setup shown; none unless `?tool=` names one.
pub fn tool_of(session: *admin.Session) []const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(tools.len > 1);

    const asked = admin.query_param(session, "tool") orelse return "";

    return known_tool(asked) orelse "";
}

/// The tools with their own steps to connect.
const tools = [_][]const u8{
    "claude_code", "codex", "cursor", "windsurf", "claude_ai", "chatgpt", "other",
};

fn known_tool(text: []const u8) ?[]const u8 {
    std.debug.assert(text.len <= 64 << 10);
    std.debug.assert(tools.len > 1);

    for (tools) |tool| {
        if (std.mem.eql(u8, text, tool)) {
            return tool;
        }
    }

    return null;
}

/// The commands that set an agent to work on this project. Opened on this machine, with
/// the folder `serve` runs in known and no host running it (`registry.hosted`): work in
/// that folder with its own binary. Otherwise:
/// the publr command, signed in at the address the browser used, the skill in the agent's
/// own folder.
fn fill_agents(session: *admin.Session, props: *Props) admin.Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(props.login_command.len == 0);

    const arena = session.arena;
    const project = session.project;
    const host = session.request.header("host") orelse "";

    if (registry.hosted or project.folder.len == 0 or !credentials.host_on_this_machine(host)) {
        const host_url = try definitions.host_url_of(session);
        const site = try std.fmt.allocPrint(arena, "{s}{s}", .{ host_url, project.admin_path() });
        const agent = try agent_setup.of(session, site);

        props.agent_command = agent.command;
        props.agent_prompt = agent.prompt;
        props.login_command = try std.fmt.allocPrint(arena, "publr login {s}", .{site});

        return;
    }

    const folder = try quoted(arena, project.folder);
    const binary = try quoted(arena, project.binary);

    props.folder_command = try std.fmt.allocPrint(arena, "cd {s}", .{folder});
    props.install_command = try std.fmt.allocPrint(arena, "{s} skill install", .{binary});
}

/// Whether this site's address answers from the internet: where it is on this computer, a chat
/// app's servers cannot add it.
pub fn reachable(session: *const admin.Session) bool {
    std.debug.assert(session.signed_in());

    return !credentials.host_on_this_machine(session.request.header("host") orelse "");
}

pub const Mcp = struct {
    address: []const u8 = "",
    cursor_link: []const u8 = "",
};

/// This site's MCP address, which every tool adds, and Cursor's link that adds it.
pub fn mcp_of(session: *admin.Session) admin.Error!Mcp {
    std.debug.assert(session.signed_in());
    std.debug.assert(cursor_install.len > 0);

    const arena = session.arena;
    const base = try oauth.tool_base_of(session.project, session.request, arena);
    const address = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, oauth.mcp_path });
    const config = try std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{address});
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(config.len));
    var link: std.Io.Writer.Allocating = .init(arena);

    _ = encoder.encode(encoded, config);
    link.writer.writeAll(cursor_install) catch return error.OutOfMemory;
    std.Uri.Component.percentEncode(&link.writer, encoded, std.ascii.isAlphanumeric) catch {
        return error.OutOfMemory;
    };

    return .{
        .address = address,
        .cursor_link = link.written(),
    };
}

/// Cursor's link that adds an MCP server, its config base64 in `config`.
const cursor_install = "cursor://anysphere.cursor-deeplink/mcp/install?name=publr&config=";

/// The person's conversations, newest first, each leading to its workspace.
fn fill_conversations(session: *admin.Session, props: *Props) admin.Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(props.earlier.len == 0);

    const arena = session.arena;
    const listed = registry.SDK.dispatch(&session.ctx, ai.List, .{}) catch |err| switch (err) {
        error.Denied => return,
        else => return error.OutOfMemory,
    };
    const earlier = try arena.alloc(Earlier, listed.conversations.len);

    for (listed.conversations, earlier) |conversation, *item| {
        item.* = .{
            .id = conversation.id,
            .prompt = ai_model.summary_of(conversation.prompt),
            .label = try label_of(session, conversation.state),
            .href = try std.fmt.allocPrint(arena, "/admin/ai/{s}", .{conversation.id}),
        };
    }

    props.earlier = earlier;
}

/// A conversation's state as the Overview words it.
fn label_of(session: *const admin.Session, state: []const u8) admin.Error![]const u8 {
    std.debug.assert(state.len <= 64);

    const labels = [_][2][]const u8{
        .{ "running", try session.translated("Working", .{}) },
        .{ "stopping", try session.translated("Stopping", .{}) },
        .{ "finished", try session.translated("Done", .{}) },
        .{ "stopped", try session.translated("Stopped", .{}) },
        .{ "waiting", try session.translated("Waiting for you", .{}) },
        .{ "failed", try session.translated("Failed", .{}) },
    };

    for (labels) |pair| {
        if (std.mem.eql(u8, pair[0], state)) {
            return pair[1];
        }
    }

    return state;
}

/// A path as a shell word: as it is when nothing in it needs quoting, else in single quotes.
fn quoted(arena: std.mem.Allocator, path: []const u8) admin.Error![]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= std.fs.max_path_bytes);

    for (path) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "/._-+", byte) != null;

        if (!plain) {
            const escaped = try std.mem.replaceOwned(u8, arena, path, "'", "'\\''");

            return std.fmt.allocPrint(arena, "'{s}'", .{escaped});
        }
    }

    return path;
}

test "a path becomes one shell word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/sites/blog", try quoted(arena, "/sites/blog"));
    try std.testing.expectEqualStrings("'/my sites/blog'", try quoted(arena, "/my sites/blog"));
    try std.testing.expectEqualStrings("'/Dawid'\\''s'", try quoted(arena, "/Dawid's"));
}

test "only the tools offered are remembered" {
    try std.testing.expectEqualStrings("cursor", known_tool("cursor").?);
    try std.testing.expect(known_tool("here") == null);
    try std.testing.expect(known_tool("keys") == null);
    try std.testing.expect(known_tool("") == null);
}
