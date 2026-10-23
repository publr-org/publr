//! A plugin's own page: the admin's chrome with the plugin frame in the sheet, and the
//! frame's document, drawn by the plugin's read as the person looking at it.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const pages = @import("frame/pages.zig");
const panels = @import("frame/panels.zig");
const records = @import("../../operations/record.zig");
const document = @import("frame/document.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;

pub const prefix = "/admin/plugin";
pub const all = pages.all;
pub const tabs_of = pages.tabs_of;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(prefix ++ "/:plugin/:page", &show);
    router.get(prefix ++ "/:plugin/:page/frame", &frame);
    router.get(prefix ++ "/:plugin/panels/:operation/frame", &panel_frame);
}

pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const page = try found(&session) orelse return absent(&session);

    if (page.tabs) {
        return open_first_tab(&session, page);
    }

    if (page.declared()) {
        return @import("frame/form.zig").show(&session, page);
    }

    const query = request.query();
    const separator: []const u8 = if (query.len == 0) "" else "?";
    const src = try std.fmt.allocPrint(session.arena, "{s}/{s}/{s}/frame{s}{s}", .{
        prefix,
        page.plugin,
        page.path,
        separator,
        query,
    });

    const title = try session.declared(page.label);
    const operations = try pages.operations_of(&session, page.plugin);
    const all_pages = try pages.all(&session);
    const parent = pages.parent_of(all_pages, page) orelse {
        return admin.screen(&session, .ok, admin.views.PluginPage, .{
            .title = title,
            .src = src,
            .plugin = page.plugin,
            .page = page.path,
            .csrf = session.csrf_token(),
            .operations = operations,
        }, .{
            .settings_path = request.path(),
        });
    };
    // A tab: its tabbed page's header and tab bar over the frame, its entry lit in the menu.
    const header = try pages.header_of(Tab, &session, all_pages, page, parent);

    try admin.screen(&session, .ok, admin.views.PluginTabPage, .{
        .title = title,
        .src = src,
        .plugin = page.plugin,
        .page = page.path,
        .csrf = session.csrf_token(),
        .operations = operations,
        .parent = header.title,
        .description = header.description,
        .tabs = header.tabs,
        .action_label = page.action_label,
        .action_href = page.action_href,
    }, .{
        .settings_path = header.address,
    });
}

const Tab = admin.views.PluginTabPage.TabsItem;

/// The frame's document. The plugin's read takes the address's query string; a failure is
/// told inside the frame, which keeps the admin around it.
pub fn frame(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const page = try found(&session) orelse return response.text(.not_found, "Not Found");

    if (page.declared() or page.tabs) {
        return response.text(.not_found, "Not Found");
    }

    const asked = .{
        .query = request.query(),
        .base = session.project.admin_path(),
    };

    look(&session, page.path);
    try serve_frame(&session, page.operation, asked, .page);
}

/// A panel's document, `?record=<id>`: the panel's read told the record and the base path.
/// The record decides the type, so a panel shows only on records of its own type.
pub fn panel_frame(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const plugin = request.param("plugin") orelse "";
    const operation = request.param("operation") orelse "";
    const record = admin.query_param(&session, "record") orelse "";

    if (plugin.len == 0 or operation.len == 0 or record.len == 0) {
        return response.text(.not_found, "Not Found");
    }

    var reading = session;
    const got = registry.SDK.dispatch(&reading.ctx, records.Get, .{
        .id = record,
        .purpose = .edit,
    }) catch return response.text(.not_found, "Not Found");
    const panel = try panels.find(&session, plugin, operation, got.record.type) orelse {
        return response.text(.not_found, "Not Found");
    };
    const asked = .{
        .record = record,
        .base = session.project.admin_path(),
    };

    look(&session, "");
    try serve_frame(&session, panel.operation, asked, .panel);
}

/// The frame's read is told who is looking and the page, for its view's `ctx`.
fn look(session: *Session, path: []const u8) void {
    std.debug.assert(session.signed_in());

    session.ctx.view = .{
        .person = .{
            .name = session.identity.display_name,
            .email = session.identity.email,
        },
        .page = .{
            .path = path,
            .query = session.request.query(),
        },
    };
}

/// The frame's document, drawn by `operation` from `asked`; a failure is told inside the
/// frame, which keeps the admin around it. A panel is drawn by its view
/// (`publr.views.render`), a whole document; anything else is told as a failure.
fn serve_frame(
    session: *Session,
    operation: []const u8,
    asked: anytype,
    shown: enum { page, panel },
) Error!void {
    std.debug.assert(operation.len > 0);
    std.debug.assert(session.signed_in());

    const response = session.response;
    const base = session.project.admin_path();
    const html = drawn(session, operation, asked, shown == .panel) catch |err| blk: {
        const text = if (err == error.Failed and session.ctx.failure != null)
            session.ctx.failure.?.message
        else if (err == error.NotAView)
            "This panel's read answers markup of its own; a panel draws its view with " ++
                "publr.views.render on the PanelPage layout."
        else
            @errorName(err);

        break :blk try std.fmt.allocPrint(session.arena, "<p class=\"p-8\">{s}</p>", .{
            try escaped(session.arena, text),
        });
    };
    var out: std.Io.Writer.Allocating = .init(session.arena);

    document.write(&out.writer, base, html, session.ctx.view) catch return error.OutOfMemory;
    try response.set_header("Content-Security-Policy", document.policy);
    try response.set_header("Cache-Control", "no-store");
    try response.set_header("Referrer-Policy", "no-referrer");
    try response.set_header("X-Content-Type-Options", "nosniff");
    try response.html(.ok, out.written());
}

/// A tabbed page opens on its first tab the viewer may see; with none it is not there.
fn open_first_tab(session: *Session, page: pages.Page) Error!void {
    std.debug.assert(page.tabs);

    var buffer: [128]u8 = undefined;
    const all_pages = try pages.all(session);
    const tabs = try pages.tabs_of(session.arena, all_pages, page.named(&buffer));

    if (tabs.len == 0) {
        return absent(session);
    }

    try session.response.redirect(.see_other, try tabs[0].href(session.arena));
}

fn absent(session: *const Session) Error!void {
    std.debug.assert(session.signed_in());

    const text = try session.translated(
        "No page of a plugin you may open is at this address.",
        .{},
    );
    const heading = try session.translated("No such page", .{});

    try admin.message(session, heading, text, &.{}, "/admin/settings", .{});
}

fn found(session: *const Session) Error!?pages.Page {
    std.debug.assert(session.signed_in());

    const plugin = session.request.param("plugin") orelse return null;
    const path = session.request.param("page") orelse return null;

    std.debug.assert(plugin.len > 0);

    return pages.find(session, plugin, path);
}

/// What the plugin's read answers as `html`; a view's whole document when `view` is asked.
fn drawn(session: *Session, operation: []const u8, asked: anytype, view: bool) ![]const u8 {
    std.debug.assert(operation.len > 0);
    std.debug.assert(session.signed_in());

    const input = try std.json.Stringify.valueAlloc(session.arena, asked, .{});
    const output = try registry.SDK.call_json(&session.ctx, operation, input);
    const Drawn = struct {
        html: []const u8,
    };
    const parsed = try std.json.parseFromSliceLeaky(Drawn, session.arena, output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    if (view and !document.whole(parsed.html)) {
        return error.NotAView;
    }

    return parsed.html;
}

fn escaped(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    std.debug.assert(text.len > 0);

    var out: std.Io.Writer.Allocating = .init(arena);

    for (text) |char| {
        const written = switch (char) {
            '<' => out.writer.writeAll("&lt;"),
            '>' => out.writer.writeAll("&gt;"),
            '&' => out.writer.writeAll("&amp;"),
            else => out.writer.writeByte(char),
        };

        written catch return error.OutOfMemory;
    }

    std.debug.assert(out.written().len >= text.len);

    return out.written();
}
