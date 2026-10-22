//! Which app the admin shows: everything, or what one app reaches (the types living in it
//! or shared with it). The choice is the viewer's, kept in a cookie; it narrows the admin
//! and says where a new type lives, never what anyone's roles allow.
const std = @import("std");
const admin = @import("../admin.zig");
const identity_module = @import("../rest/identity.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const record_operations = @import("../../operations/record.zig");
const App = @import("../apps/state.zig").App;

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const Node = admin.render.Node;

pub const cookie_name = "publr_admin_app";
const back_len_max: u32 = 2048;
const year_s: u32 = 365 * 24 * 60 * 60;

pub const Scope = union(enum) {
    all,
    app: *const App,

    pub fn label(scope: Scope, session: *const Session) admin.Error![]const u8 {
        std.debug.assert(scope != .app or scope.app.spec.label.len > 0);

        return switch (scope) {
            .all => session.translated("All apps", .{}),
            .app => |app| app.spec.label,
        };
    }

    /// The app a record made here belongs to; null for the project's own.
    pub fn app_name(scope: Scope) ?[]const u8 {
        std.debug.assert(scope != .app or model.app.valid_name(scope.app.spec.name));

        return switch (scope) {
            .all => null,
            .app => |app| app.spec.name,
        };
    }
};

/// What the viewer chose; everything when nothing is chosen, or the app chosen is gone.
pub fn of(session: *const Session) Scope {
    std.debug.assert(session.project.apps.len <= 1024);

    const header = session.request.header("cookie") orelse return .all;
    const value = identity_module.cookie_value(header, cookie_name) orelse return .all;

    if (value.len == 0 or !model.app.valid_name(value)) {
        return .all;
    }

    const app = session.project.find(value) orelse return .all;

    std.debug.assert(std.mem.eql(u8, app.spec.name, value));

    return .{
        .app = app,
    };
}

/// The app picker, with what plugins join after it (`after`); null where the project has no
/// apps. With one app there is nothing to pick: it is a link to that app's site. `apps` is
/// the phone's list of them (`panel`), drawn by the picker's own drawer when nothing joined
/// it took them.
pub fn switcher(session: *const Session, after: ?Node, apps: ?Node) ?Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(after == null or apps == null);

    const listed = session.project.apps;

    if (listed.len == 0) {
        return null;
    }

    const scope = of(session);
    const choices = choices_of(admin.views.AppSwitcher.ChoicesItem, session) catch return null;

    return admin.render.view(session.arena, admin.views.AppSwitcher, .{
        .current = scope.label(session) catch return null,
        .current_href = if (scope == .app) site_of(scope.app) else "",
        .choices = choices,
        .csrf = session.csrf_token(),
        .back = back_of(session),
        .after = after,
        .extended = after != null,
        .only_href = if (listed.len == 1) site_of(&listed[0]) else "",
        .apps = apps,
    }) catch null;
}

/// The apps as a phone's drawer lists them: which one the admin shows, each with its site;
/// null where the project has none.
pub fn panel(session: *const Session) ?Node {
    std.debug.assert(session.signed_in());

    const listed = session.project.apps;

    if (listed.len == 0) {
        return null;
    }

    const choices = choices_of(admin.views.AppsPanel.ChoicesItem, session) catch return null;

    std.debug.assert(choices.len == listed.len + 1);

    return admin.render.view(session.arena, admin.views.AppsPanel, .{
        .choices = choices,
        .csrf = session.csrf_token(),
        .back = back_of(session),
        .only_href = if (listed.len == 1) site_of(&listed[0]) else "",
    }) catch null;
}

/// Everything first, then each app, the one shown marked.
fn choices_of(comptime Choice: type, session: *const Session) admin.Error![]Choice {
    std.debug.assert(session.signed_in());

    const apps = session.project.apps;
    const scope = of(session);
    const choices = try session.arena.alloc(Choice, apps.len + 1);

    std.debug.assert(apps.len > 0);

    choices[0] = .{
        .value = "",
        .label = try session.translated("All apps", .{}),
        .current = scope == .all,
        .href = "",
    };

    for (apps, choices[1..]) |*app, *choice| {
        choice.* = .{
            .value = app.spec.name,
            .label = app.spec.label,
            .current = scope == .app and scope.app == app,
            .href = site_of(app),
        };
    }

    return choices;
}

/// The site of the app the admin shows: the only one, or the one chosen; empty while it
/// shows several or the project has none.
pub fn site_href(session: *const Session) []const u8 {
    std.debug.assert(session.signed_in());

    const apps = session.project.apps;

    if (apps.len == 1) {
        return site_of(&apps[0]);
    }

    return switch (of(session)) {
        .app => |app| site_of(app),
        .all => "",
    };
}

/// `GET /admin/settings/apps`: the project's apps, each with its site, and with several the
/// choice of which one the admin shows.
pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const apps = session.project.apps;
    const scope = of(&session);
    const rows = try session.arena.alloc(admin.views.Apps.AppsItem, apps.len);

    for (apps, rows) |*app, *row| {
        row.* = .{
            .label = app.spec.label,
            .name = app.spec.name,
            .url = app.url,
            .href = site_of(app),
            .shown_alone = scope == .app and scope.app == app,
        };
    }

    try admin.screen(&session, .ok, admin.views.Apps, .{
        .apps = rows,
        .narrowed = scope == .app,
        .several = apps.len > 1,
        .csrf = session.csrf_token(),
    }, .{});
}

/// Where an app's site opens: its own path on this host (the base the project is served
/// under included), or its address when it answers on a subdomain.
fn site_of(app: *const App) []const u8 {
    std.debug.assert(app.url.len > 0);

    return switch (app.spec.mount) {
        .subdomain => app.url,
        .path => if (app.base().len > 0) app.base() else "/",
    };
}

/// Where the switcher brings the viewer back: this page, when it is one a link reaches.
fn back_of(session: *const Session) []const u8 {
    std.debug.assert(session.request.path().len > 0);

    const request = session.request;

    if (request.method() != .get or !std.mem.startsWith(u8, request.path(), "/admin")) {
        return "/admin/content";
    }

    if (request.query().len == 0) {
        return request.path();
    }

    return std.fmt.allocPrint(session.arena, "{s}?{s}", .{ request.path(), request.query() }) catch
        request.path();
}

/// `POST /admin/app`: the viewer's choice kept, and back to the page it was made on.
pub fn choose(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, "/admin") orelse return;
    const session = &post.session;
    const value = post.form.get("app") orelse "";
    const known = value.len == 0 or
        (model.app.valid_name(value) and session.project.find(value) != null);

    if (!known) {
        return admin.fail(session, error.NotFound, "/admin");
    }

    const secure = identity_module.secure_suffix(request);
    const cookie = if (value.len == 0)
        try std.fmt.allocPrint(session.arena, "{s}=; Path=/admin; HttpOnly; SameSite=Lax; " ++
            "Max-Age=0{s}", .{ cookie_name, secure })
    else
        try std.fmt.allocPrint(session.arena, "{s}={s}; Path=/admin; HttpOnly; SameSite=Lax; " ++
            "Max-Age={d}{s}", .{ cookie_name, value, year_s, secure });

    try response.set_header("Set-Cookie", cookie);
    try response.redirect(.see_other, safe_back(post.form.get("back") orelse ""));
}

/// Only back into the admin, on this host: a path under `/admin`, nothing that could name
/// another host or split a header.
fn safe_back(back: []const u8) []const u8 {
    std.debug.assert(back_len_max > 0);

    const inside = std.mem.eql(u8, back, "/admin") or std.mem.startsWith(u8, back, "/admin/") or
        std.mem.startsWith(u8, back, "/admin?");

    if (!inside or back.len > back_len_max) {
        return "/admin/content";
    }

    for (back) |char| {
        if (char < 0x20 or char == 0x7f or char == '\\') {
            return "/admin/content";
        }
    }

    std.debug.assert(back[0] == '/');

    return back;
}

test "back only ever leads into the admin" {
    const listed = "/admin/content?type=post";

    try std.testing.expectEqualStrings(listed, safe_back(listed));
    try std.testing.expectEqualStrings("/admin", safe_back("/admin"));

    const refused = [_][]const u8{
        "",                            "/",                       "//evil.test",
        "/administrator",              "https://evil.test/admin", "/admin/\\evil",
        "/admin/x\r\nSet-Cookie: a=1",
    };

    for (refused) |bad| {
        try std.testing.expectEqualStrings("/admin/content", safe_back(bad));
    }
}

const Harness = @import("../apps.zig").Harness;

/// An admin request as the signed-in browser sends it, with the app it chose, if any.
fn admin_call(
    harness: *Harness,
    method: []const u8,
    path: []const u8,
    cookies: []const u8,
    body: []const u8,
) !admin.Response {
    std.debug.assert(path.len > 0);
    std.debug.assert(cookies.len > 0);

    const head = try harness.flow.head(
        "{s} {s} HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\nCookie: {s}\r\n" ++
            "Content-Length: 0\r\n\r\n",
        .{ method, path, cookies },
    );

    return harness.flow.call(head, body);
}

test "the switcher narrows the admin to what the app reaches, and places new types there" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const arena = harness.flow.arena;
    var system = harness.inner.ctx(.system);
    system.now_ms = @import("../../sdk.zig").context.wall_clock_ms(std.testing.io);
    try @import("../../operations/user.zig").seed_admin(&system);

    var note = model.content_type.test_post;
    note.handle = "note";
    note.name = "Note";
    note.app = "docs";
    _ = try registry.SDK.dispatch(&system, @import("../../operations/content_type.zig").Create, .{
        .definition = try model.content_type.encode(arena, note),
    });

    const Create = record_operations.Create;
    _ = try registry.SDK.dispatch(&system, Create, .{
        .type = "post",
        .document = "{\"title\":\"Global news\"}",
    });
    _ = try registry.SDK.dispatch(&system, Create, .{
        .type = "note",
        .document = "{\"title\":\"Docs only\"}",
    });
    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&system, Create, .{
        .type = "post",
        .document = "{\"title\":\"Told an app\"}",
        .app = "www",
    }));

    const signed = try harness.flow.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
            "Content-Length: 0\r\n\r\n",
        "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}",
    );
    const set = signed.header("Set-Cookie").?;
    const session = set[0..std.mem.indexOfScalar(u8, set, ';').?];

    const everything = try admin_call(&harness, "GET", "/admin/content", session, "");
    try std.testing.expect(std.mem.indexOf(u8, everything.body, "All apps") != null);
    try std.testing.expect(std.mem.indexOf(u8, everything.body, "Global news") != null);
    try std.testing.expect(std.mem.indexOf(u8, everything.body, "Docs only") != null);

    const marker = "name=\"csrf\" value=\"";
    const at = std.mem.indexOf(u8, everything.body, marker).? + marker.len;
    const csrf = everything.body[at .. at + @import("../../lib/auth.zig").csrf.token_len];
    const choose_body = try std.fmt.allocPrint(arena, "csrf={s}&app=www&back=%2Fadmin%2Fcontent", .{
        csrf,
    });
    const chosen = try admin_call(&harness, "POST", "/admin/app", session, choose_body);
    try std.testing.expectEqualStrings("/admin/content", chosen.header("Location").?);
    const kept = chosen.header("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, kept, cookie_name ++ "=www;"));

    const in_www = try std.fmt.allocPrint(arena, "{s}; {s}=www", .{ session, cookie_name });
    const narrowed = try admin_call(&harness, "GET", "/admin/content", in_www, "");
    try std.testing.expect(std.mem.indexOf(u8, narrowed.body, "Global news") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrowed.body, "Docs only") == null);

    const in_docs = try std.fmt.allocPrint(arena, "{s}; {s}=docs", .{ session, cookie_name });
    const own = try admin_call(&harness, "GET", "/admin/content", in_docs, "");
    try std.testing.expect(std.mem.indexOf(u8, own.body, "Global news") != null);
    try std.testing.expect(std.mem.indexOf(u8, own.body, "Docs only") != null);

    const stale = try std.fmt.allocPrint(arena, "{s}; {s}=_project", .{ session, cookie_name });
    const fallen = try admin_call(&harness, "GET", "/admin/content", stale, "");
    try std.testing.expect(std.mem.indexOf(u8, fallen.body, "Docs only") != null);

    const new_type = try admin_call(&harness, "GET", "/admin/types/new", in_docs, "");
    const placement = "data-part=\"type-placement\"";
    try std.testing.expect(std.mem.indexOf(u8, new_type.body, placement) != null);
    try std.testing.expect(std.mem.indexOf(u8, new_type.body, "value=\"docs\" selected") != null);

    const unknown = try std.fmt.allocPrint(arena, "csrf={s}&app=nope", .{csrf});
    const refused = try admin_call(&harness, "POST", "/admin/app", session, unknown);
    try std.testing.expect(refused.header("Location") == null);
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "There is no such page") != null);
}
