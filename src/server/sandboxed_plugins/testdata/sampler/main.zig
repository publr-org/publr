//! Every part of the plugin contract a sandboxed plugin can declare, once, so the two-mode
//! check sees each part run sandboxed and compiled in: an operation open to anyone, a write
//! with a before hook that reshapes its input and an after hook that raises a notice, an
//! event hook that answers the notice with a record, its own types and a custom field group.
//! Compiled in, it also answers a route, lists it in Settings, puts an item in the top bar,
//! keeps a state, takes `--sampler-in <folder>` off a command, notes the port `serve` got,
//! and answers the operator's `ping`: what only a compiled-in plugin does, left out of its
//! sandboxed build.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;
const record = publr.operations.record;
const notes = publr.records.of(struct { note: []const u8 }, "sample_note");
const logs = publr.records.of(struct { line: []const u8 }, "sample_log");
const tallies = publr.internal.of(struct { word: []const u8 }, "tally");

pub const manifest: publr.plugin.Manifest = .{
    .name = "sampler",
    .version = "0.1.0",
    .summary = "A sample of every part of the plugin contract, for the two-mode check",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "sampler",
    .summary = "A sample of the plugin contract",
    .details = "Notes, a log the notes' notices leave, and a greeting open to anyone.",
}};

pub const content_types = [_]publr.plugin.ContentTypeDef{
    .{
        .handle = "sample_note",
        .name = "Sample note",
        .title_field = "note",
        .fields = &.{.{ .name = "note", .label = "Note", .kind = "string", .required = true }},
    },
    .{
        .handle = "sample_log",
        .name = "Sample log",
        .title_field = "line",
        .fields = &.{.{ .name = "line", .label = "Line", .kind = "string", .required = true }},
    },
};

pub const custom_fields = [_]publr.plugin.ContentTypeDef{.{
    .handle = "sampler_profile",
    .name = "Sampler profile",
    .fields = &.{.{ .name = "motto", .label = "Motto", .kind = "string" }},
    .group = .{ .location = &.{.{ .rules = &.{.{ .field = "destination", .value = "user" }} }} },
}};

pub const operations = [_]type{ Hello, Echo, Note, Logs };

pub const internal_records = [_]publr.plugin.InternalCollection{
    .{ .kind = "tally", .indexed = &.{"word"}, .append_only = true },
};

pub const routes = [_]publr.plugin.Route{.{ .path = "/admin/sampler", .handler = &settings }};

pub const settings_pages = [_]publr.plugin.SettingsPage{.{
    .label = "Sampler",
    .icon = "stack",
    .path = "/admin/sampler",
    .operation = Logs,
}};

/// What the sampler keeps while the process runs.
pub const State = struct {
    db_path: []const u8 = "",
    port: u16 = 0,
    pings: u32 = 0,

    pub fn init(state: *State, process: publr.plugin.Process) anyerror!void {
        std.debug.assert(process.db_path.len > 0);

        state.* = .{ .db_path = try process.arena.dupe(u8, process.db_path) };
    }
};

pub const operator_commands = [_]publr.plugin.OperatorCommand{
    .{ .name = "ping", .handler = &ping },
};

/// `publr --sampler-in <folder> <command>`: the command runs in that folder.
pub fn before_command(command: *publr.plugin_hooks.Command) anyerror!void {
    std.debug.assert(command.db_path.len > 0);

    const args = command.args;

    if (args.len < 2 or !std.mem.eql(u8, args[0], "--sampler-in")) {
        return;
    }

    var dir = try std.Io.Dir.cwd().openDir(command.io, args[1], .{});
    defer dir.close(command.io);

    try std.process.setCurrentDir(command.io, dir);
    command.args = args[2..];
}

/// `serve` listening: the sampler notes where.
pub fn serving(serve: publr.plugin_hooks.Serving) anyerror!void {
    std.debug.assert(serve.port > 0);

    const states = serve.project.plugin_states orelse return;

    publr.plugin_states.from(states, @This()).port = serve.port;
}

/// `POST /_publr/sampler/ping`: the port `serve` noted, the database, and how many pings.
fn ping(
    request: *publr.http.Request,
    response: *publr.http.Response,
    ctx: *publr.http.Context,
) publr.http.Error!void {
    std.debug.assert(request.path().len > 0);

    const project = publr.project.Project.of(ctx);
    const states = project.plugin_states orelse return response.text(.not_found, "Not Found");
    const state = publr.plugin_states.from(states, @This());

    state.pings += 1;

    try response.json(.ok, .{ .port = state.port, .db_path = state.db_path, .pings = state.pings });
}

/// How many notes there are, for whoever may read them.
pub fn top_bar(session: *const publr.admin.Session) publr.admin.Error!?publr.admin.render.Node {
    std.debug.assert(session.signed_in());

    if (!publr.registry.SDK.may(&session.ctx, Logs)) {
        return null;
    }

    var listing = session.*;
    const all = publr.registry.SDK.dispatch(&listing.ctx, record.List, .{
        .type = "sample_note",
        .limit = 200,
    }) catch return null;
    const count = try std.fmt.allocPrint(session.arena, "{d}", .{all.records.len});

    return try publr.admin.render.view(session.arena, publr.admin.views.SamplerBadge, .{
        .count = count,
    });
}

/// Settings › Sampler: the log, in the admin's own chrome.
fn settings(
    request: *publr.http.Request,
    response: *publr.http.Response,
    ctx: *publr.http.Context,
) publr.http.Error!void {
    std.debug.assert(request.path().len > 0);

    var session = try publr.admin.require(request, response, ctx) orelse return;
    const shell = publr.admin.shell_of(&session);
    const logged = publr.registry.SDK.dispatch(&session.ctx, Logs, .{}) catch |err| {
        return publr.admin.fail(&session, err, "/admin/settings");
    };

    try publr.admin.render.page(response, session.arena, .ok, publr.admin.views.SamplerSettings, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .nav = try publr.admin.settings_nav.node(&session, "/admin/sampler"),
        .lines = logged.lines,
        .port = try std.fmt.allocPrint(session.arena, "{d}", .{
            publr.plugin_states.of(&session.ctx, @This()).port,
        }),
    });
}
pub const middleware = [_]type{ Shout, Announce, Log };

pub const Hello = struct {
    pub const name = "sampler.hello";
    pub const description = "Say hello to anyone";
    pub const details = "Anyone may call it, signed in or not.";
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct { who: []const u8 = "world" };
    pub const Out = struct { text: []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .text = "hello, world" };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        if (in.who.len == 0 or in.who.len > 64) {
            return error.Invalid;
        }

        const text = std.fmt.allocPrint(ctx.arena(), "hello, {s}", .{in.who}) catch {
            return error.OutOfMemory;
        };

        return .{ .text = text };
    }
};

const Point = struct { across: i64, down: i64 };

/// Every shape a field may take, answered back as it arrived.
pub const Echo = struct {
    pub const name = "sampler.echo";
    pub const description = "Answer every field back";
    pub const details = "Administrators may call it; it never fails.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        text: []const u8 = "",
        count: i64 = 0,
        ratio: f64 = 0,
        flag: bool = false,
        tags: []const []const u8 = &.{},
        mood: enum { calm, loud } = .calm,
        maybe: ?i64 = null,
        points: []const Point = &.{},
    };
    pub const Out = In;
    pub const example: In = .{ .text = "a", .count = 2, .ratio = 0.5, .flag = true };
    pub const example_out: Out = example;

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);
        std.debug.assert(in.tags.len <= 1024);

        return in;
    }
};

pub const Note = struct {
    pub const name = "sampler.note";
    pub const description = "Keep a note, in capitals";
    pub const details = "Administrators may call it. The before hook puts the note in capitals.";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { note: []const u8 };
    pub const Out = struct { note: []const u8, total: u32 };
    pub const example: In = .{ .note = "hello" };
    pub const example_out: Out = .{ .note = "HELLO", .total = 1 };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        if (in.note.len == 0 or in.note.len > 280) {
            return error.Invalid;
        }

        _ = try notes.create(ctx, .{ .note = in.note }, .{});
        _ = try tallies.create(ctx, .{ .word = in.note });

        const counted = try tallies.find(ctx, .{ .word = in.note }, .{});

        std.debug.assert(counted.len > 0);

        const all = try ctx.call(record.List, .{ .type = "sample_note", .limit = 200 });

        return .{ .note = in.note, .total = @intCast(all.records.len) };
    }
};

pub const Logs = struct {
    pub const name = "sampler.logs";
    pub const description = "The lines the notes' notices left";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { lines: []const []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .lines = &.{"noted HELLO"} };

    pub fn run(ctx: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        const all = try logs.find(ctx, .{}, .{ .limit = 200 });
        const lines = ctx.arena().alloc([]const u8, all.len) catch {
            return error.OutOfMemory;
        };

        for (all, lines) |item, *line| {
            line.* = item.value.line;
        }

        std.mem.sort([]const u8, lines, {}, before);

        return .{ .lines = lines };
    }
};

fn before(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Before: the note in capitals, whoever calls.
pub const Shout = struct {
    pub const stage: sdk.middleware.Stage = .before;
    pub const operation = "sampler.note";
    pub const reason = "Keeps every note in capitals";

    pub fn run(ctx: *PluginCtx, in: *Note.In) sdk.Error!void {
        std.debug.assert(ctx.now_ms() >= 0);

        const upper = ctx.arena().alloc(u8, in.note.len) catch return error.OutOfMemory;

        in.note = std.ascii.upperString(upper, in.note);
    }
};

/// After: a notice with the note kept.
pub const Announce = struct {
    pub const stage: sdk.middleware.Stage = .after;
    pub const operation = "sampler.note";
    pub const reason = "Tells other plugins a note was kept";

    pub fn run(ctx: *PluginCtx, in: *Note.In, out: *const Note.Out) sdk.Error!void {
        std.debug.assert(out.total > 0);

        ctx.notice("sampler.noted", in.note);
    }
};

/// Event: every `sampler.noted` notice leaves a line in the log.
pub const Log = struct {
    pub const stage: sdk.middleware.Stage = .on;
    pub const event = "sampler.noted";
    pub const reason = "Logs every note kept";

    pub fn run(ctx: *PluginCtx, happened: sdk.middleware.Event) void {
        std.debug.assert(event.len > 0);

        const subject = switch (happened) {
            .notice => |notice| notice.subject,
            else => return,
        };
        const line = std.fmt.allocPrint(ctx.arena(), "noted {s}", .{subject}) catch return;

        _ = logs.create(ctx, .{ .line = line }, .{}) catch |err| {
            ctx.log(@errorName(err));
        };
    }
};
