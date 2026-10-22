//! The Design pages an editor app fills: the design system builder and the moodboard. Each
//! is the element the app mounts on, carrying the app's data; they save through
//! `design.save_system` and `design.save_moodboard` themselves.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const design_operations = @import("../../../operations/design.zig");
const editor_site = @import("../editor_site.zig");
const files = @import("files.zig");
const system_page = @import("system_page.zig");
const App = @import("../../apps/state.zig").App;

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Choice = views.DesignApp.ChoicesItem;

pub fn system(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const what = try session.translated("The app's colors, type, spacing and fonts.", .{});
    const publish = try session.translated(
        "Publish writes them into its app.zon, and every page shows them.",
        .{},
    );
    const page: Page = .{
        .tab = "system",
        .title = try session.translated("Design system", .{}),
        .description = try std.fmt.allocPrint(session.arena, "{s} {s}", .{ what, publish }),
    };
    const app = files.app_of(&session, admin.query_param(&session, "app")) orelse {
        return choose(&session, page);
    };

    try system_page.screen(&session, app);
}

pub fn moodboard(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const page: Page = .{
        .tab = "moodboard",
        .title = try session.translated("Moodboard", .{}),
        .description = "What the site should feel like: notes, links, images, colors, fonts " ++
            "and Figma frames, each with why it is here.",
    };
    const app = files.app_of(&session, admin.query_param(&session, "app")) orelse {
        return choose(&session, page);
    };
    const read = registry.SDK.dispatch(&session.ctx, design_operations.Moodboard, .{
        .app = app.spec.name,
    }) catch |err| return admin.fail(&session, err, "/admin/design/templates");
    const items = try std.json.Stringify.valueAlloc(session.arena, read.items, .{});

    try admin.screen(&session, .ok, views.DesignMoodboard, .{
        .app = app.spec.name,
        .app_label = app.spec.label,
        .items = items,
    }, .{});
}

const Data = struct {
    fonts: []const u8 = "[]",
    editor_site: []const u8 = "",
};

const Page = struct {
    tab: []const u8,
    title: []const u8,
    description: []const u8,

    fn props(page: Page, app: *const App, data: Data) views.DesignApp.Props {
        std.debug.assert(app.spec.name.len > 0);
        std.debug.assert(page.tab.len > 0);

        return .{
            .tab = page.tab,
            .title = page.title,
            .description = page.description,
            .app = app.spec.name,
            .app_label = app.spec.label,
            .choices = &.{},
            .fonts = data.fonts,
            .editor_site = data.editor_site,
        };
    }
};

/// Several apps and none chosen: which one, each a link to this page for it.
fn choose(session: *Session, page: Page) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(page.tab.len > 0);

    const apps = session.project.apps;
    const choices = try session.arena.alloc(Choice, apps.len);

    for (apps, choices) |*app, *choice| {
        choice.* = .{
            .label = app.spec.label,
            .href = try std.fmt.allocPrint(session.arena, "/admin/design/{s}?app={s}", .{
                page.tab,
                app.spec.name,
            }),
        };
    }

    try admin.screen(session, .ok, views.DesignApp, .{
        .tab = page.tab,
        .title = page.title,
        .description = page.description,
        .app = "",
        .app_label = "",
        .choices = choices,
        .fonts = "[]",
        .editor_site = "",
    }, .{});
}
