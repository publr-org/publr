//! What a signed-in administrator is served of an app on the admin's own host: the page never
//! runs as them. The admin always has an origin of its own (`serve --admin-url`, by default
//! `admin.<host>`), so a site's scripts never share it: on the site's host everyone gets the
//! page as it is. On the admin's host, a page the browser opens as a document goes to the site
//! (`server/split.zig`); one loaded as anything else (a preview, the editor's canvas) comes with
//! a `sandbox` policy that gives it an opaque origin, where the session cookie is never sent.

const std = @import("std");
const http = @import("../../lib/http.zig");
const html = @import("../../lib/html.zig");
const identity_module = @import("../rest/identity.zig");
const registry = @import("../../server/registry.zig");
const model_app = @import("../../model/app.zig");
const context = @import("context.zig");
const Project = @import("../../server/project.zig").Project;
const App = @import("state.zig").App;

const Request = http.Request;
const Response = http.Response;

/// What a framed page may do: everything a site needs except share the admin's origin.
/// Its popups and `target="_top"` links leave the sandbox, and land on the site.
pub const sandbox = "allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox " ++
    "allow-modals allow-downloads allow-pointer-lock allow-presentation " ++
    "allow-orientation-lock allow-top-navigation-by-user-activation";

pub const policy = "sandbox " ++ sandbox ++ "; frame-ancestors 'self'";

pub const Outcome = enum {
    /// Not an administrator on the admin's host: the page as it is.
    plain,
    /// An administrator loading the page on the admin's host (in a frame, as anything but a
    /// document): the page, sandboxed and kept out of every cache.
    sandboxed,
};

/// Decides. A `sandboxed` answer's response already carries the policy; the caller serves the
/// page and calls `seal` after. Without an admin host of its own (tests, the browser build),
/// the page as it is.
pub fn answer(
    project: *const Project,
    app: *const App,
    arena: std.mem.Allocator,
    request: *const Request,
    response: *Response,
) !Outcome {
    std.debug.assert(request.path().len > 0);
    std.debug.assert(app.spec.name.len > 0);

    if (request.method() != .get and request.method() != .head) {
        return .plain;
    }

    if (!project.split() or !project.on_admin_host(request)) {
        return .plain;
    }

    if (!administrator(project, arena, request)) {
        return .plain;
    }

    try response.set_header("Content-Security-Policy", policy);

    return .sandboxed;
}

/// After a sandboxed page is written, whatever cache policy the page set: nobody else may
/// be served a copy made for an administrator.
pub fn seal(response: *Response) !void {
    const sandboxed = response.header("Content-Security-Policy").?;

    std.debug.assert(std.mem.eql(u8, sandboxed, policy));
    std.debug.assert(response.header("Access-Control-Allow-Origin") == null);

    try response.set_header("Cache-Control", "private, no-store");
    try response.set_header("CDN-Cache-Control", "no-store");
    try response.set_header("Vary", "Cookie, Sec-Fetch-Dest");
}

/// Puts the guard (`frame.js`) first in a sandboxed page, before any of the page's own
/// scripts: it sees every frame the page adds and every storage read that throws.
pub fn guard(app: *const App, visitor_id: ?[]const u8, response: *Response) !void {
    std.debug.assert(app.version.len == 16);
    std.debug.assert(response.header("Content-Security-Policy") != null);

    const kind = response.header("Content-Type") orelse return;

    if (!std.mem.startsWith(u8, kind, "text/html") or response.body.len == 0) {
        return;
    }

    const body = try without_credentialed_preloads(response.arena, response.body);
    const at = guard_place(body);
    const tag = try std.fmt.allocPrint(response.arena, "<script src=\"{s}{s}frame.js?v={s}\" " ++
        "data-publr-visitor=\"{s}\"></script>", .{
        app.base(),
        context.assets_prefix,
        &app.version,
        visitor_id orelse "",
    });

    response.body = try std.mem.concat(response.arena, u8, &.{
        body[0..at],
        tag,
        body[at..],
    });
}

/// A dynamic island's preload: the frame's fetch of it carries the frame's visitor, so it
/// could never use one, and the browser would fetch twice.
const credentialed_preload = "<link rel=\"preload\" as=\"fetch\" crossorigin=\"use-credentials\"";

fn without_credentialed_preloads(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    std.debug.assert(body.len > 0);
    std.debug.assert(credentialed_preload.len > 0);

    if (std.mem.indexOf(u8, body, credentialed_preload) == null) {
        return body;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var rest = body;

    while (std.mem.indexOf(u8, rest, credentialed_preload)) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start, '>') orelse break;

        try out.writer.writeAll(rest[0..start]);
        rest = rest[end + 1 ..];
    }

    try out.writer.writeAll(rest);

    return out.written();
}

/// Just inside `<head>`, else `<html>`, else after the doctype: never before it, which
/// would put the page in quirks mode.
fn guard_place(body: []const u8) u32 {
    std.debug.assert(body.len > 0);
    std.debug.assert(body.len <= std.math.maxInt(u32));

    for ([_][]const u8{ "<head", "<html", "<!doctype" }) |opening| {
        var from: usize = 0;

        while (std.ascii.indexOfIgnoreCasePos(body, from, opening)) |start| {
            const after = start + opening.len;

            from = after;

            if (after < body.len and (body[after] == '>' or std.ascii.isWhitespace(body[after]))) {
                const end = std.mem.indexOfScalarPos(u8, body, after, '>') orelse break;

                return @intCast(end + 1);
            }
        }
    }

    return 0;
}

/// Signed in, with roles that reach the admin. The readable hint cookie comes first, so a
/// visitor costs one header scan and no session lookup.
fn administrator(project: *const Project, arena: std.mem.Allocator, request: *const Request) bool {
    std.debug.assert(project.session_cookie.len > 0);

    const cookies = request.header("cookie") orelse return false;

    if (identity_module.cookie_value(cookies, project.hint_cookie) == null) {
        return false;
    }

    const identity = identity_module.identify(request, arena, project);

    if (identity.caller.user_id() == null) {
        return false;
    }

    var door = identity_module.context(project, arena, identity.caller);

    return registry.SDK.reaches_admin(&door);
}

const testing_users = @import("../../operations/user.zig");
const Harness = @import("../apps.zig").Harness;

/// Signs an editor in and answers the `Cookie` header their browser would send.
fn sign_in(harness: *Harness) ![]const u8 {
    std.debug.assert(harness.flow.project.session_cookie.len > 0);

    var system = harness.inner.ctx(.system);

    _ = try registry.SDK.dispatch(&system, testing_users.Create, .{
        .email = "ed@x.test",
        .display_name = "Ed",
        .password = "correct horse battery",
    });

    const signed = try harness.flow.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: http://example.test\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 0\r\n\r\n",
        "{\"email\":\"ed@x.test\",\"password\":\"correct horse battery\"}",
    );
    const set_cookie = signed.header("Set-Cookie").?;
    const session = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];

    std.debug.assert(std.mem.startsWith(u8, session, harness.flow.project.session_cookie));

    return std.fmt.allocPrint(harness.arena_state.allocator(), "{s}; {s}=1", .{
        session,
        identity_module.hint_cookie_name,
    });
}

const site_host = "example.test";
const admin_host = "admin.example.test";

/// The admin on a host of its own, as `serve` always gives it.
fn split_harness(harness: *Harness) !void {
    try harness.init(.{
        .base_url = "https://" ++ site_host,
    });
    harness.flow.project.admin_origin = "https://" ++ admin_host;
    harness.flow.project.site_origin = "https://" ++ site_host;
}

fn page(
    harness: *Harness,
    host: []const u8,
    cookie: []const u8,
    destination: []const u8,
) !http.Response {
    std.debug.assert(destination.len < 64);

    const head = try harness.flow.head("GET /?a=1&b=2 HTTP/1.1\r\nHost: {s}\r\n" ++
        "{s}Cookie: {s}\r\n\r\n", .{ host, destination, cookie });

    return harness.flow.call(head, "");
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "a visitor gets the page itself, unframed and unsandboxed" {
    var harness: Harness = undefined;
    try harness.init(.{
        .base_url = "https://example.test",
    });
    defer harness.deinit();

    const plain = try page(&harness, site_host, "theme=dark", "Sec-Fetch-Dest: document\r\n");

    try std.testing.expectEqual(http.Status.ok, plain.status);
    try std.testing.expect(plain.header("Content-Security-Policy") == null);
    try std.testing.expect(!has(plain.body, "data-publr-shell"));
}

test "on the admin's host, an administrator's frame gets the page sandboxed, the guard first" {
    var harness: Harness = undefined;
    try split_harness(&harness);
    defer harness.deinit();

    const cookie = try sign_in(&harness);
    const framed = try page(&harness, admin_host, cookie, "Sec-Fetch-Dest: iframe\r\n");

    try std.testing.expectEqualStrings(policy, framed.header("Content-Security-Policy").?);
    try std.testing.expect(!has(sandbox, "allow-same-origin"));

    // The guard comes first in the head, before anything of the page's own.
    const head_at = std.ascii.indexOfIgnoreCase(framed.body, "<head").?;
    const first_script = std.mem.indexOfPos(u8, framed.body, head_at, "<script").?;

    try std.testing.expect(std.mem.startsWith(u8, framed.body[first_script..], "<script " ++
        "src=\"/_app/frame.js?v="));
    try std.testing.expectEqualStrings("private, no-store", framed.header("Cache-Control").?);
    try std.testing.expectEqualStrings("no-store", framed.header("CDN-Cache-Control").?);

    // On the site's host, the administrator gets the page as it is: no frame, no sandbox.
    const opened = try page(&harness, site_host, cookie, "Sec-Fetch-Dest: document\r\n");

    try std.testing.expectEqual(http.Status.ok, opened.status);
    try std.testing.expect(opened.header("Content-Security-Policy") == null);
    try std.testing.expect(!has(opened.body, "frame.js"));
}

test "the guard goes inside the head, never before the doctype" {
    const cases = [_]struct {
        body: []const u8,
        place: u32,
    }{
        .{
            .body = "<!doctype html><html lang=\"pl\"><HEAD><title>",
            .place = 37,
        },
        .{
            .body = "<!doctype html><html><header>x</header>",
            .place = 21,
        },
        .{
            .body = "<!DOCTYPE html><p>no head",
            .place = 15,
        },
        .{
            .body = "<p>bare",
            .place = 0,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.place, guard_place(case.body));
    }
}

test "a hint cookie without a session is a visitor" {
    var harness: Harness = undefined;
    try harness.init(.{
        .base_url = "https://example.test",
    });
    defer harness.deinit();

    const stale = try page(
        &harness,
        site_host,
        "publr_signed_in=1",
        "Sec-Fetch-Dest: document\r\n",
    );

    try std.testing.expect(stale.header("Content-Security-Policy") == null);
    try std.testing.expect(!has(stale.body, "data-publr-shell"));
}

test "the frame gets visitors' answers, never the administrator's, and may read them" {
    var harness: Harness = undefined;
    try harness.init(.{
        .base_url = "https://example.test",
    });
    defer harness.deinit();

    const cookie = try sign_in(&harness);
    const anonymous = try harness.flow.call(
        "GET / HTTP/1.1\r\nHost: example.test\r\nOrigin: null\r\n\r\n",
        "",
    );

    try std.testing.expectEqualStrings("null", anonymous.header("Access-Control-Allow-Origin").?);
    try std.testing.expect(has(anonymous.header("Vary").?, "Origin"));

    // With the session sent along, still a visitor: not sandboxed, as nobody is.
    const head = try harness.flow.head("GET / HTTP/1.1\r\nHost: example.test\r\n" ++
        "Origin: null\r\nCookie: {s}\r\n\r\n", .{cookie});
    const with_session = try harness.flow.call(head, "");

    const opened_with_session = with_session.header("Access-Control-Allow-Origin").?;

    try std.testing.expectEqualStrings("null", opened_with_session);
    try std.testing.expect(with_session.header("Content-Security-Policy") == null);

    const visitor = try harness.flow.call("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n", "");

    try std.testing.expect(visitor.header("Access-Control-Allow-Origin") == null);

    // Any public route opens, a missing file too; the admin's doors never do.
    for ([_][]const u8{ "/media/none.woff2", "/admin", "/api/health" }, 0..) |path, index| {
        const asked = try harness.flow.head("GET {s} HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: null\r\nCookie: {s}\r\n\r\n", .{ path, cookie });
        const reply = try harness.flow.call(asked, "");
        const opened = reply.header("Access-Control-Allow-Origin") != null;

        try std.testing.expectEqual(index == 0, opened);
    }

    // The session, asked from the frame, names nobody.
    const whoami = try harness.flow.head("GET /api/auth/session HTTP/1.1\r\n" ++
        "Host: example.test\r\nOrigin: null\r\nCookie: {s}\r\n\r\n", .{cookie});
    const session = try harness.flow.call(whoami, "");

    try std.testing.expect(!has(session.body, "ed@x.test"));
}

test "from the frame, islands and `_api` calls work, as the frame's visitor, never as the admin" {
    var harness: Harness = undefined;
    try split_harness(&harness);
    defer harness.deinit();

    const cookie = try sign_in(&harness);

    // Opened by the administrator, the island names them; asked from the frame, nobody.
    const own = try harness.flow.head("GET /_islands/signed-in HTTP/1.1\r\n" ++
        "Host: example.test\r\nCookie: {s}\r\n\r\n", .{cookie});

    try std.testing.expect(has((try harness.flow.call(own, "")).body, "ed@x.test"));

    const asked = try harness.flow.head("GET /_islands/signed-in HTTP/1.1\r\n" ++
        "Host: example.test\r\nOrigin: null\r\nSec-Fetch-Site: cross-site\r\n" ++
        "Cookie: {s}\r\n\r\n", .{cookie});
    const island = try harness.flow.call(asked, "");

    try std.testing.expectEqual(http.Status.ok, island.status);
    try std.testing.expect(!has(island.body, "ed@x.test"));
    try std.testing.expect(has(island.body, "Sign in"));
    try std.testing.expectEqualStrings("null", island.header("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("true", island.header("Access-Control-Allow-Credentials").?);
    // The frame's visitor, derived from the session: nothing new to set.
    try std.testing.expect(island.header("Set-Cookie") == null);

    // The page the frame loads names the same visitor for its guard to send.
    const framed_page = try page(&harness, admin_host, cookie, "Sec-Fetch-Dest: iframe\r\n");
    const named_at = std.mem.indexOf(u8, framed_page.body, "data-publr-visitor=\"").? + 20;
    const named = framed_page.body[named_at..][0..24];

    try std.testing.expect(std.ascii.isHex(named[0]) and std.ascii.isHex(named[23]));
    try std.testing.expect(!has(framed_page.body, "ed@x.test"));

    // The browser asks before the frame's `_api` call; the call is not refused as foreign.
    const ask = try harness.flow.call("OPTIONS /_api/greeter/wave HTTP/1.1\r\n" ++
        "Host: example.test\r\nOrigin: null\r\n\r\n", "");

    try std.testing.expectEqual(http.Status.no_content, ask.status);
    try std.testing.expect(has(ask.header("Access-Control-Allow-Headers").?, "publr-visitor"));

    const call_head = try harness.flow.head("POST /_api/greeter/wave HTTP/1.1\r\n" ++
        "Host: example.test\r\nOrigin: null\r\nContent-Type: application/json\r\n" ++
        "Content-Length: 2\r\nPublr-Request: 1\r\nPublr-Visitor: {s}\r\n\r\n", .{named});
    const called = try harness.flow.call(call_head, "{}");

    try std.testing.expect(!has(called.body, "cross_origin"));
    try std.testing.expect(called.header("Set-Cookie") == null);

    // The admin's doors are not opened to it.
    const admin_ask = try harness.flow.call("OPTIONS /admin HTTP/1.1\r\n" ++
        "Host: example.test\r\nOrigin: null\r\n\r\n", "");

    try std.testing.expect(admin_ask.status != .no_content);
}
