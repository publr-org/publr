//! The Design area: the routes' templates and the template parts of the apps' files, each
//! the file's own or overridden from the block editor, and the patterns the editor offers;
//! Reset and Remove take an override away. The editor saves through `design/override.zig`.
const std = @import("std");
const admin = @import("../admin.zig");
const http = @import("../../lib/http.zig");
const design = @import("../../model/design.zig");
const files = @import("design/files.zig");
const records = @import("design/records.zig");
const override = @import("design/override.zig");
const boards = @import("design/boards.zig");
pub const hand = @import("design/hand.zig");
const App = @import("../apps/state.zig").App;

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;

pub const routes_count: u32 = 6;
const templates_path = "/admin/design/templates";
/// Where the Design area opens: the site theme, which holds the templates and patterns too.
const home_path = "/admin/design/system";

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < router.routes.len - routes_count);

    const before = router.routes_len;

    router.get("/admin/design", &home);
    router.get(templates_path, &templates);
    router.get("/admin/design/patterns", &patterns);
    router.get("/admin/design/system", &boards.system);
    router.get("/admin/design/moodboard", &boards.moodboard);
    router.post(override.path, &override.save);

    std.debug.assert(router.routes_len == before + routes_count);
}

fn home(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    const session = try admin.require(request, response, ctx) orelse return;
    const location = try std.fmt.allocPrint(session.arena, "{s}{s}", .{
        session.project.admin_path(),
        home_path,
    });

    try response.redirect(.see_other, location);
}

const TemplateRow = views.DesignTemplates.TemplatesItem;
const PartRow = views.DesignTemplates.PartsItem;

fn templates(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    var template_rows: std.ArrayList(TemplateRow) = .empty;
    var part_rows: std.ArrayList(PartRow) = .empty;

    for (files.listed_apps(&session)) |*app| {
        list_app(&session, app, &template_rows, &part_rows) catch |err| {
            return admin.fail(&session, err, "/admin");
        };
    }

    try admin.screen(&session, .ok, views.DesignTemplates, .{
        .templates = template_rows.items,
        .parts = part_rows.items,
    }, .{});
}

fn list_app(
    session: *Session,
    app: *const App,
    template_rows: *std.ArrayList(TemplateRow),
    part_rows: *std.ArrayList(PartRow),
) !void {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const saved_templates = try records.keys(session, design.template_handle, app.spec.name);
    const saved_parts = try records.keys(session, design.part_handle, app.spec.name);

    for (try files.templated_routes(arena, app)) |rel| {
        try template_rows.append(arena, .{
            .name = rel,
            .app = app.spec.name,
            .app_label = app.spec.label,
            .overridden = holds(saved_templates, rel),
        });
    }

    for (try files.part_names(arena, app)) |name| {
        try part_rows.append(arena, .{
            .name = name,
            .app = app.spec.name,
            .app_label = app.spec.label,
            .overridden = holds(saved_parts, name),
        });
    }
}

fn holds(saved: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    for (saved) |name| {
        if (std.mem.eql(u8, name, key)) {
            std.debug.assert(name.len == key.len);

            return true;
        }
    }

    return false;
}

const PatternRow = views.DesignPatterns.PatternsItem;

fn patterns(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    var rows: std.ArrayList(PatternRow) = .empty;

    for (files.listed_apps(&session)) |*app| {
        const found = hand.patterns_of(&session, app) catch |err| {
            return admin.fail(&session, err, "/admin");
        };

        for (found) |pattern| {
            try rows.append(session.arena, .{
                .name = pattern.name,
                .label = pattern.label,
                .category = pattern.category,
                .app = app.spec.name,
                .app_label = app.spec.label,
                .source = pattern.source,
            });
        }
    }

    try admin.screen(&session, .ok, views.DesignPatterns, .{
        .patterns = rows.items,
    }, .{});
}
