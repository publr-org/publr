const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const definitions = @import("definitions.zig");
const credentials = @import("../../server/credentials.zig");
const identity_module = @import("../rest/identity.zig");
const ai = @import("../../operations/ai.zig");
const ai_model = @import("../../model/ai.zig");
const providers = @import("../../operations/ai/providers.zig");
const setup = @import("../../operations/ai/setup.zig");
const agent_setup = @import("agent_setup.zig");

const Props = admin.views.Dashboard.Props;
const Earlier = admin.views.Dashboard.EarlierItem;

/// Which way of building the Overview shows, remembered per browser.
pub const mode_cookie = "publr_admin_build_mode";
const year_s: u32 = 365 * 24 * 60 * 60;

/// Everything the Overview shows: the way of building, what an agent is told, and the
/// person's conversations.
pub fn props_of(session: *admin.Session) admin.Error!Props {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.project.folder.len == 0 or session.project.binary.len > 0);

    const connected = ai.connected(&session.ctx);
    const asked = admin.query_param(session, "ask") orelse "";
    var props: Props = .{
        .mode = if (asked.len > 0) "keys" else try mode_of(session, connected),
        .connected = connected,
        .asked = asked,
        .asked_on = admin.query_param(session, "page") orelse "",
        .folder_command = "",
        .install_command = "",
        .login_command = "",
        .agent_command = "",
        .agent_prompt = "",
        .earlier = &.{},
    };

    try fill_agents(session, &props);
    try fill_conversations(session, &props);

    if (std.mem.eql(u8, props.mode, "keys") and !connected) {
        try fill_providers(session, &props);
    }

    props.agents_tab = agents_tab_of(session);
    props.agents_tab_from = if (registry.agents_tab) |tab| tab.plugin else "";
    props.branch_work = registry.work_start != null;

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
        .mode = "agents",
        .connected = false,
        .folder_command = "",
        .install_command = "",
        .login_command = "",
        .agent_command = "",
        .agent_prompt = "",
        .earlier = &.{},
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

/// `?mode=` when given, remembered for the next visit; else the remembered one; else the
/// person's own key once a provider is connected, their own agent before.
fn mode_of(session: *admin.Session, connected: bool) admin.Error![]const u8 {
    std.debug.assert(mode_cookie.len > 0);
    std.debug.assert(year_s > 0);

    if (admin.query_param(session, "mode")) |asked| {
        if (known_mode(asked)) |mode| {
            const cookie = try std.fmt.allocPrint(
                session.arena,
                "{s}={s}; Path=/admin; HttpOnly; SameSite=Lax; Max-Age={d}{s}",
                .{ mode_cookie, mode, year_s, identity_module.secure_suffix(session.request) },
            );

            try session.response.set_header("Set-Cookie", cookie);

            return mode;
        }
    }

    const header = session.request.header("cookie") orelse "";
    const kept = identity_module.cookie_value(header, mode_cookie) orelse "";

    return known_mode(kept) orelse if (connected) "keys" else "agents";
}

fn known_mode(text: []const u8) ?[]const u8 {
    std.debug.assert(text.len <= 64 << 10);

    if (std.mem.eql(u8, text, "keys")) {
        return "keys";
    }

    if (std.mem.eql(u8, text, "agents")) {
        return "agents";
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

    if (registry.hosted or project.folder.len == 0 or !local(host)) {
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

/// A plugin's own contents for the "Your agent" tab, through the admin's sanitizer; null
/// when no plugin declares one or it does not read cleanly.
fn agents_tab_of(session: *const admin.Session) ?admin.render.Node {
    std.debug.assert(session.signed_in());

    const tab = registry.agents_tab orelse return null;

    std.debug.assert(tab.html.len > 0);

    const sanitize = @import("../../lib/sanitize.zig");
    const cleaned = sanitize.sanitize(session.arena, tab.html, .admin) catch return null;

    return admin.render.raw(cleaned);
}

/// Before any provider is connected: the ones installed, each waiting for its key; with
/// none, the official ones to pick from.
fn fill_providers(session: *admin.Session, props: *Props) admin.Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(!props.connected);

    const arena = session.arena;
    const listed = registry.SDK.dispatch(&session.ctx, providers.Providers, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else {};
    };
    var waiting: std.ArrayList(admin.views.Dashboard.ProvidersItem) = .empty;

    for (listed.providers) |provider| {
        const given = provider.description.key orelse continue;

        try waiting.append(arena, .{
            .plugin = provider.plugin,
            .label = provider.description.label,
            .key_secret = given.secret,
            .key_set = provider.key_set,
            .key_url = given.create_url,
            .key_steps = try std.mem.join(arena, " ", given.steps),
        });
    }

    props.providers = waiting.items;

    if (waiting.items.len > 0) {
        return;
    }

    const catalog = registry.SDK.dispatch(&session.ctx, setup.Catalog, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else {};
    };
    var offered: std.ArrayList(admin.views.Dashboard.OfferedItem) = .empty;

    for (catalog.offered) |item| {
        if (!item.installed) {
            try offered.append(arena, .{
                .name = item.name,
                .label = item.label,
                .summary = item.summary,
            });
        }
    }

    props.offered = offered.items;
    props.reached = catalog.reached;
}

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
        .{ "running", try session.translated("Working") },
        .{ "stopping", try session.translated("Stopping") },
        .{ "finished", try session.translated("Done") },
        .{ "stopped", try session.translated("Stopped") },
        .{ "waiting", try session.translated("Waiting for you") },
        .{ "failed", try session.translated("Failed") },
    };

    for (labels) |pair| {
        if (std.mem.eql(u8, pair[0], state)) {
            return pair[1];
        }
    }

    return state;
}

/// Whether a `Host` header names this machine, its port aside.
fn local(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);
    std.debug.assert(credentials.address_len_max > 0);

    const bracket_end = if (host.len > 0 and host[0] == '[')
        std.mem.indexOfScalar(u8, host, ']')
    else
        null;
    const name_end = if (bracket_end) |end|
        end + 1
    else
        std.mem.indexOfScalar(u8, host, ':') orelse host.len;
    const name = host[0..name_end];

    return name.len > 0 and name.len <= credentials.address_len_max and
        credentials.on_this_machine(name);
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

test "a host on this machine is told from one elsewhere" {
    try std.testing.expect(local("localhost:8080"));
    try std.testing.expect(local("blog.localhost"));
    try std.testing.expect(local("publr.local:8080"));
    try std.testing.expect(local("127.0.0.1:8096"));
    try std.testing.expect(local("[::1]:8080"));
    try std.testing.expect(!local("example.com"));
    try std.testing.expect(!local("localhost.example.com:8080"));
    try std.testing.expect(!local(""));
}

test "only the two ways of building are remembered" {
    try std.testing.expectEqualStrings("keys", known_mode("keys").?);
    try std.testing.expect(known_mode("cloud") == null);
}
