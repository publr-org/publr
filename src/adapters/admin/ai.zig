const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const ai = @import("../../operations/ai.zig");
const ai_model = @import("../../model/ai.zig");
const Hub = @import("../../server/live.zig").Hub;

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;

test {
    _ = @import("ai_around.zig");
}

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.post("/admin/ai/ask", &ask);
    router.get("/admin/ai/:id", &workspace);
    router.get("/admin/ai/:id/live", &watch);
    @import("ai_settings.zig").register(router);
    @import("ai_around.zig").register(router);
}

/// `POST /admin/ai/ask`: the Overview's prompt. Starts the turn and shows it following.
pub fn ask(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, "/admin") orelse return;
    const session = &post.session;

    if (try refused_in_preview(session)) {
        return;
    }

    const started = registry.SDK.dispatch(&session.ctx, ai.Ask, .{
        .prompt = post.form.text("prompt") orelse "",
        .scope = post.form.get("scope") orelse "write",
        .pictures = try pictures_of(session.arena, &post.form),
        .page = post.form.get("page") orelse "",
    }) catch |err| return admin.fail(session, err, "/admin");
    const back = try std.fmt.allocPrint(session.arena, "/admin/ai/{s}", .{started.id});

    try response.redirect(.see_other, back);
}

/// `GET /admin/ai/:id/live`: a WebSocket the workspace listens on, told each time the
/// conversation changes. The person's own conversations only.
pub fn watch(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", "/admin") orelse return;

    const own: ai.Get.In = .{
        .id = id,
        .after = ai_model.steps_max,
    };

    _ = registry.SDK.dispatch(&session.ctx, ai.Get, own) catch |err| {
        return admin.fail(&session, err, "/admin");
    };

    const live = session.project.live orelse {
        return response.text(.service_unavailable, "Nothing is watched here");
    };
    const hub: *Hub = @ptrCast(@alignCast(live.context));
    const taken = hub.take(id) orelse {
        return response.text(.service_unavailable, "Too many workspaces are open");
    };

    if (!ctx.extensions.websocket.upgrade(ctx, request, Hub.handlers(taken))) {
        taken.used = false;
        return response.text(.upgrade_required, "A WebSocket is expected");
    }
}

/// `GET /admin/ai/:id`: the conversation's workspace, the admin page the agent last worked
/// on beside the conversation.
pub fn workspace(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    if (try refused_in_preview(&session)) {
        return;
    }

    const id = try admin.param(&session, "id", "/admin") orelse return;
    const read = registry.SDK.dispatch(&session.ctx, ai.Get, .{
        .id = id,
    }) catch |err| {
        return admin.fail(&session, err, "/admin");
    };
    const steps = try session.arena.alloc(admin.views.AiWorkspace.StepsItem, read.steps.len);
    const in_trash = registry.SDK.dispatch(&session.ctx, trash_operations.List, .{
        .conversation = id,
        .limit = 200,
    }) catch trash_operations.List.Out{
        .entries = &.{},
        .keep_days = 0,
    };
    const frame_path = read.last_page.href;
    const trash_entries = try session.arena.alloc([]const u8, in_trash.entries.len);

    for (read.steps, steps) |step, *shown| {
        shown.* = try step_of(&session, step, in_trash.entries);
    }

    for (in_trash.entries, trash_entries) |entry, *entry_id| {
        entry_id.* = entry.id;
    }

    const asked = ai_model.asked_of(read.conversation.prompt);

    try admin.screen(&session, .ok, admin.views.AiWorkspace, .{
        .id = read.conversation.id,
        .prompt = asked.words,
        .asked_on = asked.page,
        .title = ai_model.summary_of(asked.words),
        .prompt_pictures = try sources_of(&session, read.prompt_pictures),
        .conversation_state = read.conversation.state,
        .steps = steps,
        .earlier = @floatFromInt(read.earlier),
        .frame_path = frame_path,
        .frame_label = read.last_page.summary,
        .frame_position = @floatFromInt(read.last_page.position),
        .frame_url = if (ai_model.previewable(frame_path))
            try framed_url(&session, frame_path)
        else
            "",
        .review_path = read.removal.href,
        .undoable = trash_entries.len > 0,
        .trash_entries = trash_entries,
    }, .{});
}

const trash_prefix = "/admin/trash?entry=";

/// A workspace, or a conversation started, inside the workspace's own preview (a framed
/// page, `framed=1` or a browser loading a frame): refused, so no AI is drawn inside an AI.
fn refused_in_preview(session: *const admin.Session) Error!bool {
    std.debug.assert(session.signed_in());
    std.debug.assert(std.mem.startsWith(u8, session.request.path(), "/admin/ai"));

    if (!admin.chrome.framed(session)) {
        return false;
    }

    const text = try session.translated("The AI workspace can't open inside its own preview.", .{});
    const heading = try session.translated("Not in the preview", .{});

    try admin.message(session, heading, text, &.{}, "/admin/content", .{});

    return true;
}

/// A step as the workspace shows it: its words read, its pictures, and whether it removed
/// something for good (a list to review) or into the trash (still there to undo).
fn step_of(
    session: *admin.Session,
    step: ai.Step,
    in_trash: []const trash_operations.Shown,
) Error!admin.views.AiWorkspace.StepsItem {
    std.debug.assert(step.kind.len > 0);

    var shown: admin.views.AiWorkspace.StepsItem = .{
        .position = @floatFromInt(step.position),
        .kind = step.kind,
        .summary = step.summary,
        .detail = step.detail,
        .failed = step.failed,
        .href = step.href,
        .blocks = try blocks_of(session.arena, step.blocks),
        .pictures = try sources_of(session, step.pictures),
        .destructive = std.mem.startsWith(u8, step.href, "/admin/removals/"),
        .trash_entry = if (std.mem.startsWith(u8, step.href, trash_prefix))
            step.href[trash_prefix.len..]
        else
            "",
    };

    // Restored, or gone for good, since: nothing left to undo.
    if (shown.trash_entry.len > 0 and !held(in_trash, shown.trash_entry)) {
        const suffix = " (in the trash)";
        const words = if (std.mem.endsWith(u8, step.summary, suffix))
            step.summary[0 .. step.summary.len - suffix.len]
        else
            step.summary;

        shown.trash_entry = "";
        shown.summary = try session.translated(
            "{summary} (no longer in the trash)",
            .{
                .values = &.{.{
                    .name = "summary",
                    .value = words,
                }},
            },
        );
    }

    return shown;
}
const trash_operations = @import("../../operations/trash.zig");

fn held(entries: []const trash_operations.Shown, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) {
            return true;
        }
    }

    return false;
}

/// A page's address as the workspace's frame shows it: an admin page under the project's
/// base, marked `framed=1` so it draws its sheet alone; a page on the internet as it is.
fn framed_url(session: *admin.Session, path: []const u8) Error![]const u8 {
    std.debug.assert(path.len > 0);

    if (std.mem.startsWith(u8, path, "https://")) {
        return path;
    }

    std.debug.assert(path[0] == '/');

    const separator: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?";

    return std.fmt.allocPrint(session.arena, "{s}{s}{s}framed=1", .{
        session.project.admin_path(),
        path,
        separator,
    });
}

/// Where the conversation shows each picture: small, under the project's base.
fn sources_of(session: *admin.Session, keys: []const []const u8) Error![]const []const u8 {
    std.debug.assert(keys.len <= 64);

    const sources = try session.arena.alloc([]const u8, keys.len);

    for (keys, sources) |key, *source| {
        source.* = try std.fmt.allocPrint(session.arena, "{s}/media/{s}?w=320", .{
            session.project.admin_path(),
            key,
        });
    }

    return sources;
}

const Block = admin.views.AiWorkspace.BlocksItem;
const Run = admin.views.AiWorkspace.RunsItem;

/// A step's words, read from their Markdown, as the page takes them.
fn blocks_of(
    arena: std.mem.Allocator,
    blocks: []const @import("../../model/ai_markdown.zig").Block,
) Error![]const Block {
    std.debug.assert(blocks.len <= @import("../../model/ai_markdown.zig").blocks_max);

    const shown = try arena.alloc(Block, blocks.len);

    for (blocks, shown) |block, *item| {
        const runs = try arena.alloc(Run, block.runs.len);

        for (block.runs, runs) |run, *piece| {
            piece.* = .{
                .text = run.text,
                .style = run.style,
            };
        }

        item.* = .{
            .kind = block.kind,
            .number = @floatFromInt(block.number),
            .runs = runs,
        };
    }

    return shown;
}

/// The pictures a form attaches: every `picture` field, in order.
fn pictures_of(arena: std.mem.Allocator, form: *const admin.Form) Error![]const []const u8 {
    std.debug.assert(form.len <= admin.Form.pairs_max);

    var keys: std.ArrayList([]const u8) = .empty;

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, "picture") and pair.value.len > 0) {
            try keys.append(arena, pair.value);
        }
    }

    return keys.items;
}
