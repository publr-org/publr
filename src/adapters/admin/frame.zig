//! A plugin's own page: the admin's chrome with the plugin frame in the sheet, and the
//! frame's document, drawn by the plugin's read as the person looking at it.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const pages = @import("frame/pages.zig");
const panels = @import("frame/panels.zig");
const records = @import("../../operations/record.zig");
const document = @import("frame/document.zig");
const identity_module = @import("../rest/identity.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;

pub const prefix = "/admin/plugin";
pub const all = pages.all;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(prefix ++ "/:plugin/:page", &show);
    router.get(prefix ++ "/:plugin/:page/frame", &frame);
    router.get(prefix ++ "/:plugin/panels/:operation/frame", &panel_frame);
    router.post(prefix ++ "/:plugin/query", &read_query);
}

/// A GROQ read the plugin's frame asks for, `{ "query", "params" }` in, the result out: run
/// as the installed plugin for the viewer, so it reads no more than both may; a compiled-in
/// plugin is trusted, as its pages are, and reads as the viewer. Only a plugin with a page
/// the viewer may open asks.
pub fn read_query(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    if (!try identity_module.guard(request, response, session.project, &session.identity)) {
        return;
    }

    const plugin = request.param("plugin") orelse return response.text(.not_found, "Not Found");

    if (!try shows_pages(&session, plugin) and !panels.any_of(&session, plugin)) {
        return response.json(.not_found, .{
            .@"error" = "no_such_plugin",
        });
    }

    const asked = std.json.parseFromSliceLeaky(Asked, session.arena, request.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return response.json(.bad_request, .{
        .@"error" = "invalid_input",
    });
    const params = try std.json.Stringify.valueAlloc(session.arena, asked.params, .{});
    const input = try std.json.Stringify.valueAlloc(session.arena, .{
        .query = asked.query,
        .params = params,
        .perspective = "all",
    }, .{});
    const output = read_as(&session, plugin, input) catch |err| {
        return response.json(.unprocessable_content, .{
            .@"error" = @errorName(err),
        });
    };

    try response.set_body(.ok, "application/json", output);
}

const Asked = struct {
    query: []const u8,
    params: std.json.Value = .null,
};

fn read_as(session: *Session, plugin: []const u8, input: []const u8) ![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(input.len > 0);

    if (session.ctx.sandboxed_plugins) |sandboxed| {
        return sandboxed.call_as(&session.ctx, plugin, "record.query", input) catch |err| {
            if (err != error.NotFound) {
                return err;
            }

            return registry.SDK.call_json(&session.ctx, "record.query", input);
        };
    }

    return registry.SDK.call_json(&session.ctx, "record.query", input);
}

fn shows_pages(session: *const Session, plugin: []const u8) Error!bool {
    std.debug.assert(plugin.len > 0);

    for (try pages.all(session)) |page| {
        if (std.mem.eql(u8, page.plugin, plugin)) {
            return true;
        }
    }

    return false;
}

pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const page = try found(&session) orelse return absent(&session);

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

    const options: admin.chrome.Options = .{
        .settings_path = request.path(),
    };

    try admin.screen(&session, .ok, admin.views.PluginPage, .{
        .title = try session.declared(page.label),
        .src = src,
        .plugin = page.plugin,
        .page = page.path,
        .csrf = session.csrf_token(),
        .operations = try pages.operations_of(&session, page.plugin),
    }, options);
}

/// The frame's document. The plugin's read takes the address's query string; a failure is
/// told inside the frame, which keeps the admin around it.
pub fn frame(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const page = try found(&session) orelse return response.text(.not_found, "Not Found");

    if (page.declared()) {
        return response.text(.not_found, "Not Found");
    }

    const asked = .{
        .query = request.query(),
        .base = session.project.admin_path(),
    };

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

    try serve_frame(&session, panel.operation, asked, .panel);
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

    document.write(&out.writer, base, html) catch return error.OutOfMemory;
    try response.set_header("Content-Security-Policy", document.policy);
    try response.set_header("Cache-Control", "no-store");
    try response.set_header("Referrer-Policy", "no-referrer");
    try response.set_header("X-Content-Type-Options", "nosniff");
    try response.html(.ok, out.written());
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
