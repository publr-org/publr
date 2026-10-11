//! The admin on a host of its own (`serve --admin-url`): the admin never answers on the
//! site's host, and no page of the site opens as a document on the admin's, so a site's
//! scripts never share an origin with the admin's session. The admin's host keeps its
//! sandboxed frames (previews): those are not documents and pass. An administrator sent from
//! the admin to the site carries a member pass there, which shows them the toolbar and
//! opens nothing else.

const std = @import("std");
const http = @import("../lib/http.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const admin = @import("../adapters/admin.zig");
const registry = @import("registry.zig");
const Project = @import("project.zig").Project;

const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

/// `/_publr/member?pass=<pass>&path=<address>` on the site's host: the pass kept, then the
/// page.
pub const member_path = "/_publr/member";
pub const address_len_max: u32 = 2048;

/// What the admin's host answers itself; everything else there is the site's.
const admin_prefixes = [_][]const u8{ "/admin/", "/api/", "/auth/", "/media/" };

pub fn split(
    request: *Request,
    response: *Response,
    ctx: *Context,
    next: http.Router.Next,
) anyerror!void {
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const path = request.path();

    if (!project.split()) {
        return next.run(request, response, ctx);
    }

    std.debug.assert(project.site_origin.len > 0);

    if (project.on_admin_host(request)) {
        if (admin_side(path) or !document(request)) {
            return next.run(request, response, ctx);
        }

        return to_site(project, request, response, ctx.arena);
    }

    if (std.mem.eql(u8, path, member_path)) {
        return member(project, request, response, ctx.arena);
    }

    const admins = std.mem.eql(u8, path, "/admin") or std.mem.startsWith(u8, path, "/admin/") or
        std.mem.eql(u8, path, "/auth/sign-on");

    if (admins) {
        return to_admin(project, request, response, ctx.arena);
    }

    return next.run(request, response, ctx);
}

fn admin_side(path: []const u8) bool {
    std.debug.assert(path.len > 0);

    if (std.mem.eql(u8, path, "/admin")) {
        return true;
    }

    for (admin_prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) {
            return true;
        }
    }

    return false;
}

/// Opened as a page in a tab: what never runs on the admin's host. A browser that does not
/// say is taken as one.
fn document(request: *const Request) bool {
    const destination = request.header("sec-fetch-dest") orelse return true;

    std.debug.assert(destination.len <= 8 << 10);

    return std.mem.eql(u8, destination, "document");
}

/// The address asked for, the base the project is served under in front.
fn address_of(
    project: *const Project,
    arena: std.mem.Allocator,
    request: *const Request,
) ![]const u8 {
    std.debug.assert(request.path().len > 0);

    const query = request.query();
    const mark: []const u8 = if (query.len > 0) "?" else "";

    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
        project.base,
        request.path(),
        mark,
        query,
    });
}

fn to_admin(
    project: *const Project,
    request: *const Request,
    response: *Response,
    arena: std.mem.Allocator,
) !void {
    std.debug.assert(project.admin_origin.len > 0);

    const address = try address_of(project, arena, request);

    try response.redirect(.see_other, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
        project.admin_origin,
        project.admin_base,
        address,
    }));
}

/// The same address on the site's host; for an administrator, through the member pass.
fn to_site(
    project: *const Project,
    request: *const Request,
    response: *Response,
    arena: std.mem.Allocator,
) !void {
    std.debug.assert(project.site_origin.len > 0);

    if (request.method() != .get and request.method() != .head) {
        return response.text(.not_found, "Not Found");
    }

    const address = try address_of(project, arena, request);
    const identity = identity_module.identify(request, arena, project);
    var location = try std.fmt.allocPrint(arena, "{s}{s}", .{ project.site_origin, address });

    if (identity.caller.user_id()) |user_id| {
        var door = identity_module.context(project, arena, identity.caller);

        if (registry.SDK.reaches_admin(&door) and address.len <= address_len_max) {
            location = try std.fmt.allocPrint(arena, "{s}{s}{s}?pass={s}&path={s}", .{
                project.site_origin,
                project.base,
                member_path,
                try identity_module.member_pass(project, arena, user_id),
                try admin.query_value(arena, address),
            });
        }
    }

    try response.redirect(.see_other, location);
}

/// Keeps the pass on the site's host, with the readable hint the toolbar script waits for,
/// and goes on to the page. A pass that does not hold is dropped; the page opens all the same.
fn member(
    project: *const Project,
    request: *const Request,
    response: *Response,
    arena: std.mem.Allocator,
) !void {
    std.debug.assert(project.split());

    const query = request.query();
    const pass = http.Form.query_param(arena, query, "pass") orelse "";
    const shown = http.Form.query_param(arena, query, "path") orelse "/";
    const local = shown.len > 0 and shown.len <= address_len_max and shown[0] == '/' and
        !std.mem.startsWith(u8, shown, "//") and std.mem.indexOfScalar(u8, shown, '\\') == null;
    const back = if (local) shown else "/";
    const identity = identity_module.identify_member(project, arena, pass);

    if (identity.caller.user_id() != null) {
        const max_age_s = @divTrunc(identity_module.member_lifetime_ms, std.time.ms_per_s);
        const secure = identity_module.secure_suffix(request);

        try response.add_header("Set-Cookie", try std.fmt.allocPrint(
            arena,
            "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}{s}",
            .{ project.member_cookie, pass, max_age_s, secure },
        ));
        try response.add_header("Set-Cookie", try std.fmt.allocPrint(
            arena,
            "{s}=1; Path=/; SameSite=Lax; Max-Age={d}{s}",
            .{ project.hint_cookie, max_age_s, secure },
        ));
    }

    try response.set_header("Referrer-Policy", "no-referrer");
    try response.redirect(.see_other, back);
}

/// The toolbar's caller on the site's host: the member pass's account.
pub fn member_identity(
    project: *const Project,
    arena: std.mem.Allocator,
    request: *const Request,
) identity_module.Identity {
    std.debug.assert(project.split());
    std.debug.assert(!project.on_admin_host(request));

    const cookies = request.header("cookie") orelse return .{};
    const pass = identity_module.cookie_value(cookies, project.member_cookie) orelse return .{};

    return identity_module.identify_member(project, arena, pass);
}

const testing_users = @import("../operations/user.zig");
const Harness = @import("../adapters/apps.zig").Harness;

const site_host = "example.test";
const admin_host = "admin.example.test";

fn split_harness(harness: *Harness) !void {
    try harness.init(.{
        .base_url = "https://" ++ site_host,
    });
    harness.flow.project.admin_origin = "https://" ++ admin_host;
    harness.flow.project.site_origin = "https://" ++ site_host;
}

/// Signs an editor in on the admin's host and answers their `Cookie` header there.
fn sign_in(harness: *Harness) ![]const u8 {
    var system = harness.inner.ctx(.system);

    _ = try registry.SDK.dispatch(&system, testing_users.Create, .{
        .email = "ed@x.test",
        .display_name = "Ed",
        .password = "correct horse battery",
    });

    const signed = try harness.flow.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: " ++ admin_host ++ "\r\n" ++
            "Origin: https://" ++ admin_host ++ "\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 0\r\n\r\n",
        "{\"email\":\"ed@x.test\",\"password\":\"correct horse battery\"}",
    );
    const set_cookie = signed.header("Set-Cookie").?;

    std.debug.assert(std.mem.indexOf(u8, set_cookie, "Domain=") == null);

    return std.fmt.allocPrint(harness.arena_state.allocator(), "{s}; {s}=1", .{
        set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?],
        harness.flow.project.hint_cookie,
    });
}

fn get(harness: *Harness, host: []const u8, target: []const u8, extra: []const u8) !Response {
    std.debug.assert(target.len > 0 and target[0] == '/');

    const lines = std.mem.trimEnd(u8, extra, "\r\n");
    const separator: []const u8 = if (lines.len > 0) "\r\n" else "";
    const head = try harness.flow.head("GET {s} HTTP/1.1\r\nHost: {s}{s}{s}\r\n\r\n", .{
        target,
        host,
        separator,
        lines,
    });

    return harness.flow.call(head, "");
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "the site's host sends the admin to the admin's; the admin's sends pages to the site" {
    var harness: Harness = undefined;
    try split_harness(&harness);
    defer harness.deinit();

    const admin_page = try get(&harness, site_host, "/admin/content?type=post", "");

    try std.testing.expectEqual(http.Status.see_other, admin_page.status);
    try std.testing.expectEqualStrings(
        "https://" ++ admin_host ++ "/admin/content?type=post",
        admin_page.header("Location").?,
    );

    const sign_on = try get(&harness, site_host, "/auth/sign-on?token=abc", "");

    try std.testing.expectEqualStrings(
        "https://" ++ admin_host ++ "/auth/sign-on?token=abc",
        sign_on.header("Location").?,
    );

    const page = try get(&harness, admin_host, "/?a=1", "Sec-Fetch-Dest: document\r\n");

    try std.testing.expectEqual(http.Status.see_other, page.status);
    const site_page = "https://" ++ site_host ++ "/?a=1";

    try std.testing.expectEqualStrings(site_page, page.header("Location").?);

    // The admin's own pages stay; so does the site's page as a frame's (the preview).
    const login = try get(&harness, admin_host, "/admin/login", "Sec-Fetch-Dest: document\r\n");

    try std.testing.expectEqual(http.Status.ok, login.status);
}

test "an administrator reaches the site with a pass that shows the toolbar and nothing else" {
    var harness: Harness = undefined;
    try split_harness(&harness);
    defer harness.deinit();

    const arena = harness.arena_state.allocator();
    const cookie = try sign_in(&harness);
    const cookie_line = try std.fmt.allocPrint(arena, "Cookie: {s}\r\n", .{cookie});
    const framed = try get(&harness, admin_host, "/", try std.mem.concat(
        arena,
        u8,
        &.{ "Sec-Fetch-Dest: iframe\r\n", cookie_line },
    ));

    // In a frame on the admin's host, the page is sandboxed as ever.
    try std.testing.expect(framed.header("Content-Security-Policy") != null);

    const sent = try get(&harness, admin_host, "/", try std.mem.concat(
        arena,
        u8,
        &.{ "Sec-Fetch-Dest: document\r\n", cookie_line },
    ));
    const location = sent.header("Location").?;

    try std.testing.expect(std.mem.startsWith(u8, location, "https://" ++ site_host ++
        member_path ++ "?pass="));

    const kept = try get(&harness, site_host, location["https://".len + site_host.len ..], "");

    try std.testing.expectEqualStrings("/", kept.header("Location").?);

    var member_cookie: []const u8 = "";

    for (kept.headers[0..kept.headers_len]) |header| {
        if (std.mem.startsWith(u8, header.value, harness.flow.project.member_cookie)) {
            member_cookie = header.value[0..std.mem.indexOfScalar(u8, header.value, ';').?];
        }
    }

    try std.testing.expect(member_cookie.len > 0);

    const with_pass = try std.fmt.allocPrint(arena, "Cookie: {s}\r\n", .{member_cookie});
    const bar = try get(&harness, site_host, "/_publr/toolbar?path=/", with_pass);

    try std.testing.expect(has(bar.body, "\"signed_in\":true"));
    try std.testing.expect(has(bar.body, "\"admin\":\"https://" ++ admin_host ++ "/admin\""));

    // The pass is no session: the site's host answers it as nobody.
    const session = try get(&harness, site_host, "/api/auth/session", with_pass);

    try std.testing.expect(!has(session.body, "ed@x.test"));

    // The admin's session, reaching the site's host (two ports on one name), opens no shell.
    const page = try get(&harness, site_host, "/", try std.mem.concat(
        arena,
        u8,
        &.{ "Sec-Fetch-Dest: document\r\n", cookie_line },
    ));

    try std.testing.expect(!has(page.body, "data-publr-shell"));
    try std.testing.expect(page.header("Content-Security-Policy") == null);
}

test "a forged pass keeps nothing" {
    var harness: Harness = undefined;
    try split_harness(&harness);
    defer harness.deinit();

    const kept = try get(&harness, site_host, member_path ++ "?pass=toolbar.u1.9999999999999.00" ++
        "&path=//evil.test", "");

    try std.testing.expectEqualStrings("/", kept.header("Location").?);
    try std.testing.expect(kept.header("Set-Cookie") == null);
}

test "an admin on a shared host answers under its own path, its cookies kept there" {
    var harness: Harness = undefined;
    try split_harness(&harness);
    defer harness.deinit();

    // Publr Cloud: every project's admin on the dashboard's host, each under its own path.
    harness.flow.project.admin_base = "/spaces/ada/shop";

    const admin_page = try get(&harness, site_host, "/admin/content", "");

    try std.testing.expectEqualStrings(
        "https://" ++ admin_host ++ "/spaces/ada/shop/admin/content",
        admin_page.header("Location").?,
    );

    // The proxy in front takes the path off; what the admin sends back carries it again.
    var system = harness.inner.ctx(.system);

    _ = try registry.SDK.dispatch(&system, testing_users.Create, .{
        .email = "ed@x.test",
        .display_name = "Ed",
        .password = "correct horse battery",
    });

    const signed = try harness.flow.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: " ++ admin_host ++ "\r\n" ++
            "Origin: https://" ++ admin_host ++ "\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 0\r\n\r\n",
        "{\"email\":\"ed@x.test\",\"password\":\"correct horse battery\"}",
    );

    for (signed.headers[0..signed.headers_len]) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Set-Cookie")) {
            try std.testing.expect(has(header.value, "Path=/spaces/ada/shop;"));
        }
    }

    const login = try get(&harness, admin_host, "/admin", "Sec-Fetch-Dest: document\r\n");
    const location = login.header("Location") orelse "";

    try std.testing.expect(std.mem.startsWith(u8, location, "/spaces/ada/shop/admin"));
}
