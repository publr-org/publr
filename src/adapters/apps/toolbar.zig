//! `/_publr/toolbar?path=<page>`: what the toolbar a signed-in person sees on the site
//! offers for that page. The admin, always; the editor of the record the page renders, named
//! by its type ("Edit Post"), when the route reads one by its slug and the caller can
//! read it. Nobody signed in: nothing. An app's visitor (an account that cannot use the
//! admin) is signed in, so the page's `signedIn` parts keep drawing for them, and is offered
//! no admin (`admin` empty): no bar.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const content_type = @import("../../operations/content_type.zig");
const registry = @import("../../server/registry.zig");
const engine = @import("../../template.zig");
const build = @import("build.zig");
const Project = @import("../../server/project.zig").Project;
const App = @import("state.zig").App;
const model_app = @import("../../model/app.zig");
const split = @import("../../server/split.zig");

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;

pub const toolbar_path = "/_publr/toolbar";
pub const admin_path = "/admin";
pub const path_len_max: u32 = 1024;

const Answer = struct {
    signed_in: bool,
    name: []const u8 = "",
    /// Empty for an app's visitor, who is signed in to the app and shown no bar.
    admin: []const u8 = admin_path,
    /// The admin page that edits what this page shows; null when it shows no one record.
    edit: ?[]const u8 = null,
    /// What the edit link says: "Edit" and the record's type.
    edit_label: []const u8 = "",
};

const Edit = struct {
    url: []const u8,
    label: []const u8,
};

pub fn toolbar(request: *Request, response: *Response, ctx: *HttpContext) anyerror!void {
    std.debug.assert(std.mem.eql(u8, request.path(), toolbar_path));
    std.debug.assert(ctx.user_data != null);

    const from = request.header("sec-fetch-site") orelse "";

    if (std.mem.eql(u8, from, "cross-site")) {
        return response.text(.forbidden, "Forbidden");
    }

    try response.set_header("Cache-Control", "no-store");
    try response.set_header("Vary", "Cookie");

    const project = Project.of(ctx);
    const site_host = project.split() and !project.on_admin_host(request);
    // On the site's host, when the admin has its own, the bar comes only with the member pass;
    // a session there is a visitor of the site's apps: signed in, offered no admin.
    const identity = if (site_host)
        split.member_identity(project, ctx.arena, request)
    else
        identity_module.identify_on_site(request, ctx.arena, project);

    if (site_host and identity.caller.user_id() == null) {
        const visitor = identity_module.identify_on_site(request, ctx.arena, project);

        return response.json(.ok, Answer{
            .signed_in = visitor.caller.user_id() != null,
            .admin = "",
        });
    }

    if (identity.caller.user_id() == null) {
        return response.json(.ok, Answer{
            .signed_in = false,
        });
    }

    var door = identity_module.context(project, ctx.arena, identity.caller);

    // An app's visitor is signed in to the app, not to Publr: no bar, no way to the admin.
    if (!registry.SDK.reaches_admin(&door)) {
        return response.json(.ok, Answer{
            .signed_in = true,
            .admin = "",
        });
    }

    const shown = http.Form.query_param(ctx.arena, request.query(), "path") orelse "/";
    const path = model_app.without_base(project.base, shown);
    var edit: ?Edit = null;

    if (path.len > 0 and path.len <= path_len_max and path[0] == '/') {
        const host = request.header("host") orelse "";

        if (project.resolve(host, path)) |target| {
            if (target.app.program != null) {
                edit = try edit_link(project, target.app, ctx.arena, identity, target.path);
            }
        }
    }

    return response.json(.ok, Answer{
        .signed_in = true,
        .name = if (identity.display_name.len > 0) identity.display_name else identity.email,
        .admin = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{
            project.admin_origin,
            project.admin_path(),
            admin_path,
        }),
        .edit = if (edit) |found| found.url else null,
        .edit_label = if (edit) |found| found.label else "",
    });
}

/// The admin page for the record `path` renders, found the way the page finds it: the
/// route's `getEntry()` type and slug, read as the caller so the link is never to a record
/// they may not see.
fn edit_link(
    project: *const Project,
    app: *const App,
    arena: std.mem.Allocator,
    identity: identity_module.Identity,
    path: []const u8,
) !?Edit {
    std.debug.assert(identity.caller.user_id() != null);

    if (path.len == 0 or path.len > path_len_max or path[0] != '/') {
        return null;
    }

    const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    const found = app.pages().match(trimmed) orelse return null;
    const template = &app.pages().templates[found.route.template];

    if (!template.compiled) {
        return null;
    }

    var sdk_ctx = identity_module.context(project, arena, identity.caller);
    const query = entry_query_of(template) orelse return null;
    // A type's one record (settings, read off a route without a slug) needs no slug.
    const slug: ?[]const u8 = if (query.first) null else query.slug orelse found.slug orelse
        return null;
    const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
        .type = query.type_id,
        .slug = slug,
        .limit = 1,
    }) catch return null;

    if (listed.records.len == 0) {
        return null;
    }

    return .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}/admin/content/{s}", .{
            project.admin_origin,
            project.admin_path(),
            listed.records[0].id,
        }),
        .label = try label_of(&sdk_ctx, query.type_id),
    };
}

/// "Edit " and the type's name as the admin shows it; its handle when it has none.
fn label_of(sdk_ctx: *sdk.Ctx, handle: []const u8) ![]const u8 {
    std.debug.assert(handle.len > 0);

    const row = content_type.find_raw(sdk_ctx, handle) catch null;
    const name = if (row) |found| found.def.name else handle;

    return std.fmt.allocPrint(sdk_ctx.arena, "Edit {s}", .{if (name.len > 0) name else handle});
}

fn entry_query_of(template: *const engine.Template) ?engine.ast.Decl.EntryQuery {
    std.debug.assert(template.compiled);
    std.debug.assert(template.rel.len > 0);

    for (template.decls) |decl| {
        switch (decl.value) {
            .entry => |query| return query,
            else => {},
        }
    }

    return null;
}

const testing_users = @import("../../operations/user.zig");
const testing_roles = @import("../../operations/role.zig");
const Harness = @import("../apps.zig").Harness;

test "an app's visitor is signed in and offered no admin; staff get the bar; nobody nothing" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    var system = harness.inner.ctx(.system);

    _ = try registry.SDK.dispatch(&system, testing_roles.Create, .{
        .name = "shopper",
        .label = "Shopper",
    });
    _ = try registry.SDK.dispatch(&system, testing_users.Create, .{
        .email = "ada@x.test",
        .display_name = "Ada",
        .roles = &.{"shopper"},
        .password = "correct horse battery",
    });
    _ = try registry.SDK.dispatch(&system, testing_users.Create, .{
        .email = "ed@x.test",
        .display_name = "Ed",
        .roles = &.{"editor"},
        .password = "correct horse battery",
    });

    const nobody = try ask(&harness, "");

    try std.testing.expect(has(nobody.body, "\"signed_in\":false"));

    const visitor = try ask(&harness, try session(&harness, "ada@x.test"));

    try std.testing.expect(has(visitor.body, "\"signed_in\":true"));
    try std.testing.expect(has(visitor.body, "\"admin\":\"\""));

    const staff = try ask(&harness, try session(&harness, "ed@x.test"));

    try std.testing.expect(has(staff.body, "\"signed_in\":true"));
    try std.testing.expect(has(staff.body, "/admin\""));
    try std.testing.expect(!has(staff.body, "\"admin\":\"\""));
}

fn session(harness: *Harness, email: []const u8) ![]const u8 {
    std.debug.assert(email.len > 0);

    const body = try std.fmt.allocPrint(
        harness.arena_state.allocator(),
        "{{\"email\":\"{s}\",\"password\":\"correct horse battery\"}}",
        .{email},
    );
    const signed = try harness.flow.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
            "Content-Type: application/json\r\nContent-Length: 0\r\n\r\n",
        body,
    );
    const set_cookie = signed.header("Set-Cookie").?;

    return set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
}

fn ask(harness: *Harness, cookie: []const u8) !Response {
    std.debug.assert(cookie.len <= 4096);

    const head = try harness.flow.head(
        "GET " ++ toolbar_path ++ "?path=/ HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n",
        .{cookie},
    );

    return harness.flow.call(head, "");
}

fn has(text: []const u8, needle: []const u8) bool {
    std.debug.assert(needle.len > 0);

    return std.mem.indexOf(u8, text, needle) != null;
}
