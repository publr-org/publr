//! Which app the admin shows: every record, the project's own, or one app's. The choice is
//! the viewer's, kept in a cookie; it narrows the content list and says which app a new
//! record belongs to, never what anyone may read.
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
const ListIn = record_operations.List.In;

pub const cookie_name = "publr_admin_app";
/// What the form and the cookie say for the project's own records; never an app's name,
/// which starts with a letter.
pub const project_value = "_project";
const back_len_max: u32 = 2048;
const year_s: u32 = 365 * 24 * 60 * 60;

pub const Scope = union(enum) {
    all,
    project,
    app: *const App,

    pub fn label(scope: Scope) []const u8 {
        std.debug.assert(scope != .app or scope.app.spec.label.len > 0);

        return switch (scope) {
            .all => "All apps",
            .project => "Project only",
            .app => |app| app.spec.label,
        };
    }

    /// The app a record made here belongs to; null for the project's own.
    pub fn app_name(scope: Scope) ?[]const u8 {
        std.debug.assert(scope != .app or model.app.valid_name(scope.app.spec.name));

        return switch (scope) {
            .all, .project => null,
            .app => |app| app.spec.name,
        };
    }
};

/// What the viewer chose; everything when nothing is chosen, or the app chosen is gone.
pub fn of(session: *const Session) Scope {
    std.debug.assert(session.project.apps.len <= 1024);

    const header = session.request.header("cookie") orelse return .all;
    const value = identity_module.cookie_value(header, cookie_name) orelse return .all;

    if (std.mem.eql(u8, value, project_value)) {
        return .project;
    }

    if (value.len == 0 or !model.app.valid_name(value)) {
        return .all;
    }

    const app = session.project.find(value) orelse return .all;

    std.debug.assert(std.mem.eql(u8, app.spec.name, value));

    return .{ .app = app };
}

/// The list narrowed to the scope, unless its own filters already ask about the app.
pub fn narrow(arena: std.mem.Allocator, scope: Scope, in: ListIn) Error!ListIn {
    std.debug.assert(in.filters.len <= model.filter.filters_max);

    const clause = switch (scope) {
        .all => return in,
        .project => "app:none:",
        .app => |app| try std.fmt.allocPrint(arena, "app:is:{s}", .{app.spec.name}),
    };

    for (in.filters) |existing| {
        if (std.mem.startsWith(u8, existing, "app:")) {
            return in;
        }
    }

    if (in.filters.len == model.filter.filters_max) {
        return in;
    }

    const clauses = arena.alloc([]const u8, in.filters.len + 1) catch return error.OutOfMemory;

    @memcpy(clauses[0..in.filters.len], in.filters);
    clauses[in.filters.len] = clause;

    var narrowed = in;

    narrowed.filters = clauses;

    return narrowed;
}

/// The switcher in the top bar, for a project with apps; null for one without.
pub fn switcher(session: *const Session) ?Node {
    std.debug.assert(session.signed_in());

    const apps = session.project.apps;

    if (apps.len == 0) {
        return null;
    }

    const arena = session.arena;
    const scope = of(session);
    const Choice = admin.views.AppSwitcher.ChoicesItem;
    const choices = arena.alloc(Choice, apps.len + 2) catch return null;

    choices[0] = .{ .value = "", .label = "All apps", .current = scope == .all };
    choices[1] = .{ .value = project_value, .label = "Project only", .current = scope == .project };

    for (apps, choices[2..]) |*app, *choice| {
        const current = scope == .app and scope.app == app;

        choice.* = .{ .value = app.spec.name, .label = app.spec.label, .current = current };
    }

    return admin.render.view(arena, admin.views.AppSwitcher, .{
        .current = scope.label(),
        .choices = choices,
        .csrf = session.csrf_token(),
        .back = back_of(session),
    }) catch null;
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

/// The record's App section in the editor's aside, for a project with apps.
pub fn aside(session: *const Session, id: []const u8, app: ?[]const u8) Error!?Node {
    std.debug.assert(id.len > 0);
    std.debug.assert(session.signed_in());

    const apps = session.project.apps;

    if (apps.len == 0) {
        return null;
    }

    const arena = session.arena;
    const Choice = admin.views.RecordApp.ChoicesItem;
    const choices = arena.alloc(Choice, apps.len + 1) catch return error.OutOfMemory;

    choices[0] = .{ .value = "", .label = "Project only", .current = app == null };

    for (apps, choices[1..]) |*known, *choice| {
        const current = app != null and std.mem.eql(u8, app.?, known.spec.name);

        choice.* = .{ .value = known.spec.name, .label = known.spec.label, .current = current };
    }

    return try admin.render.view(arena, admin.views.RecordApp, .{
        .action = try std.fmt.allocPrint(arena, "/admin/content/{s}/app", .{id}),
        .csrf = session.csrf_token(),
        .choices = choices,
    });
}

/// `POST /admin/app`: the viewer's choice kept, and back to the page it was made on.
pub fn choose(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, "/admin") orelse return;
    const session = &post.session;
    const value = post.form.get("app") orelse "";
    const known = value.len == 0 or std.mem.eql(u8, value, project_value) or
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

/// `POST /admin/content/:id/app`: the record handed to the app chosen, or to the project.
pub fn move(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const back = "/admin/content";
    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;
    const app = post.form.get("app") orelse "";

    _ = registry.SDK.dispatch(&session.ctx, record_operations.SetApp, .{
        .id = id,
        .app = app,
    }) catch |err| return admin.fail(session, err, back);

    const location = try std.fmt.allocPrint(session.arena, "{s}/{s}", .{ back, id });

    try response.redirect(.see_other, location);
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

test "the switcher narrows the list, and new records belong to the app chosen" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const arena = harness.flow.arena;
    var system = harness.inner.ctx(.system);
    system.now_ms = @import("../../sdk.zig").context.wall_clock_ms(std.testing.io);
    try @import("../../operations/user.zig").seed_admin(&system);

    const Create = record_operations.Create;
    _ = try registry.SDK.dispatch(&system, Create, .{
        .type = "post",
        .document = "{\"title\":\"Site news\"}",
        .app = "www",
    });
    _ = try registry.SDK.dispatch(&system, Create, .{
        .type = "post",
        .document = "{\"title\":\"Shared note\"}",
    });

    const signed = try harness.flow.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
            "Content-Length: 0\r\n\r\n",
        "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}",
    );
    const set = signed.header("Set-Cookie").?;
    const session = set[0..std.mem.indexOfScalar(u8, set, ';').?];

    const everything = try admin_call(&harness, "GET", "/admin/content", session, "");
    try std.testing.expect(std.mem.indexOf(u8, everything.body, "All apps") != null);
    try std.testing.expect(std.mem.indexOf(u8, everything.body, "Website") != null);
    try std.testing.expect(std.mem.indexOf(u8, everything.body, "Site news") != null);
    try std.testing.expect(std.mem.indexOf(u8, everything.body, "Shared note") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, narrowed.body, "Site news") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrowed.body, "Shared note") == null);

    const own_args = .{ session, cookie_name, project_value };
    const own = try std.fmt.allocPrint(arena, "{s}; {s}={s}", own_args);
    const project_only = try admin_call(&harness, "GET", "/admin/content", own, "");
    try std.testing.expect(std.mem.indexOf(u8, project_only.body, "Site news") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_only.body, "Shared note") != null);

    const create_form = "csrf={s}&type=post&title=Made+here";
    const create_body = try std.fmt.allocPrint(arena, create_form, .{csrf});
    const created = try admin_call(&harness, "POST", "/admin/content/create", in_www, create_body);
    const location = created.header("Location").?;
    const id = location["/admin/content/".len..];
    const Get = record_operations.Get;
    try std.testing.expectEqualStrings(
        "www",
        (try registry.SDK.dispatch(&system, Get, .{ .id = id })).record.app.?,
    );

    const editor = try admin_call(&harness, "GET", location, session, "");
    try std.testing.expect(std.mem.indexOf(u8, editor.body, "data-part=\"record-app\"") != null);
    const move_path = try std.fmt.allocPrint(arena, "/admin/content/{s}/app", .{id});
    const move_body = try std.fmt.allocPrint(arena, "csrf={s}&app=", .{csrf});
    const moved = try admin_call(&harness, "POST", move_path, session, move_body);
    try std.testing.expectEqualStrings(location, moved.header("Location").?);
    const after = try registry.SDK.dispatch(&system, Get, .{ .id = id });
    try std.testing.expect(after.record.app == null);

    const unknown = try std.fmt.allocPrint(arena, "csrf={s}&app=nope", .{csrf});
    const refused = try admin_call(&harness, "POST", "/admin/app", session, unknown);
    try std.testing.expect(refused.header("Location") == null);
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "NotFound") != null);
}
