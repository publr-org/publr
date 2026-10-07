//! Who is making an HTTP request, and how the answer travels: the session cookie, the
//! CSRF guard for writes, and the `Ctx` a handler dispatches with.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const session_module = @import("../../store/sessions.zig");
const device_module = @import("../../store/devices.zig");
const device_model = @import("../../model/device.zig");
const user_module = @import("../../store/users.zig");
const csrf = @import("../../lib/auth.zig").csrf;
const http = @import("../../lib/http.zig");
const Project = @import("../../server/project.zig").Project;

const Error = http.Error;
const Caller = sdk.Caller;

/// The session cookie's name unless a plugin names another (`Project.session_cookie`).
pub const cookie_name = "publr_session";
/// A readable hint beside the session: no secret, only that someone signed in here, so the
/// page's toolbar script stays idle for everyone else without asking the server.
pub const hint_cookie_name = "publr_signed_in";
pub const csrf_header = "x-csrf-token";

pub const Identity = struct {
    caller: Caller = .anonymous,
    session: ?session_module.Session = null,
    token: ?[]const u8 = null,
    /// The signed-in user's name and email, for the admin's chrome; empty when anonymous.
    display_name: []const u8 = "",
    email: []const u8 = "",

    pub fn csrf_token(
        identity: *const Identity,
        project: *const Project,
        out: *[csrf.token_len]u8,
    ) ?[]const u8 {
        std.debug.assert(out.len == csrf.token_len);

        const session = identity.session orelse return null;
        std.debug.assert(session.id.len == session_module.id_len);

        return csrf.token(project.auth.secret, session.id, out);
    }
};

pub fn identify(
    request: *const http.Request,
    arena: std.mem.Allocator,
    project: *const Project,
) Identity {
    std.debug.assert(project.connection.transaction_depth == 0);

    if (request.header("authorization")) |authorization| {
        return identify_device(authorization, arena, project);
    }

    const cookie_header = request.header("cookie") orelse return .{};
    const token = cookie_value(cookie_header, project.session_cookie) orelse return .{};
    const now_ms = sdk.context.wall_clock_ms(project.io);

    std.debug.assert(now_ms > 0);

    const connection = project.connection;
    const session = session_module.validate(connection, arena, token, now_ms) catch return .{};
    const found = user_module.find_by_id(connection, arena, session.user_id) catch return .{};
    const credentials = found orelse return .{};

    return .{
        .caller = .{ .user = .{ .id = credentials.user.id, .roles = credentials.user.roles } },
        .session = session,
        .token = token,
        .display_name = credentials.user.display_name,
        .email = credentials.user.email,
    };
}

/// A device's request: `Authorization: Bearer <token>`. It carries no session, so no CSRF
/// token either: nothing sends the header on its own, as a browser sends a cookie. Anything
/// else in the header, or a token that does not work, is anonymous.
fn identify_device(
    authorization: []const u8,
    arena: std.mem.Allocator,
    project: *const Project,
) Identity {
    std.debug.assert(project.connection.transaction_depth == 0);

    const prefix = "Bearer ";
    const bearer = authorization.len > prefix.len and
        std.ascii.eqlIgnoreCase(authorization[0..prefix.len], prefix);

    if (!bearer) {
        return .{};
    }

    const token = std.mem.trim(u8, authorization[prefix.len..], " ");
    const now_ms = sdk.context.wall_clock_ms(project.io);
    const connection = project.connection;
    const device = device_module.validate(connection, arena, token, now_ms) catch return .{};
    const found = user_module.find_by_id(connection, arena, device.user_id) catch return .{};
    const credentials = found orelse return .{};
    const scope = device_model.Scope.parse(device.scope) orelse return .{};

    if (!credentials.user.active) {
        return .{};
    }

    std.debug.assert(device.revoked_at == null);

    return .{
        .caller = .{ .token = .{
            .id = device.id,
            .user_id = device.user_id,
            .roles = credentials.user.roles,
            .scope = scope,
            .name = device.name,
        } },
        .display_name = credentials.user.display_name,
        .email = credentials.user.email,
    };
}

pub fn cookie_value(header: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(header.len <= 64 << 10);

    var pairs = std.mem.splitScalar(u8, header, ';');

    while (pairs.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;

        if (std.mem.eql(u8, trimmed[0..equals], name)) {
            return trimmed[equals + 1 ..];
        }
    }

    return null;
}

pub fn origin_of(request: *const http.Request) csrf.Origin {
    std.debug.assert(request.path().len > 0);
    std.debug.assert(csrf.header_len_max > 0);

    const host = request.header("host");
    const origin = request.header("origin");

    return csrf.origin_of(host, origin, request.header("referer"));
}

pub fn guard(
    request: *const http.Request,
    response: *http.Response,
    project: *const Project,
    identity: *const Identity,
) Error!bool {
    std.debug.assert(request.method() != .get and request.method() != .head);
    std.debug.assert(project.connection.transaction_depth == 0);

    const origin = origin_of(request);

    if (origin == .foreign) {
        try response.json(.forbidden, .{ .@"error" = "cross_origin" });

        return false;
    }

    const session = identity.session orelse return true;

    if (origin == .absent) {
        try response.json(.forbidden, .{ .@"error" = "origin_required" });

        return false;
    }

    const provided = request.header(csrf_header) orelse "";

    if (!csrf.verify(project.auth.secret, session.id, provided)) {
        try response.json(.forbidden, .{ .@"error" = "csrf_token_invalid" });

        return false;
    }

    return true;
}

pub fn set_session_cookie(
    project: *const Project,
    request: *const http.Request,
    response: *http.Response,
    arena: std.mem.Allocator,
    token: []const u8,
    expires_at: i64,
    now_ms: i64,
) Error!void {
    std.debug.assert(token.len == session_module.token_len);
    std.debug.assert(expires_at > now_ms);

    const max_age = @divTrunc(expires_at - now_ms, std.time.ms_per_s);
    const template = "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}{s}{s}{s}";
    const value = std.fmt.allocPrint(arena, template, .{
        project.session_cookie,
        token,
        max_age,
        domain_label(project),
        domain_of(project),
        secure_suffix(request),
    }) catch return error.OutOfMemory;
    const hint_template = "{s}=1; Path=/; SameSite=Lax; Max-Age={d}{s}{s}{s}";
    const hint = std.fmt.allocPrint(arena, hint_template, .{
        hint_cookie_name,
        max_age,
        domain_label(project),
        domain_of(project),
        secure_suffix(request),
    }) catch return error.OutOfMemory;

    try response.set_header("Set-Cookie", value);
    try response.add_header("Set-Cookie", hint);
}

/// The signed-in hint set again when a valid session arrives without it: something outside
/// Publr removed it (an extension, cookies partly cleared), and islands fetched only for
/// signed-in visitors (`dynamic-if="signedIn"`) would show this visitor the anonymous
/// version. Best effort: a hint that cannot be added now is added on the next request.
pub fn repair_hint(
    project: *const Project,
    request: *const http.Request,
    response: *http.Response,
    arena: std.mem.Allocator,
    identity: *const Identity,
    now_ms: i64,
) void {
    std.debug.assert(now_ms > 0);

    const session = identity.session orelse return;
    const cookies = request.header("cookie") orelse "";

    if (cookie_value(cookies, hint_cookie_name) != null or session.expires_at <= now_ms) {
        return;
    }

    const max_age = @divTrunc(session.expires_at - now_ms, std.time.ms_per_s);
    const hint_template = "{s}=1; Path=/; SameSite=Lax; Max-Age={d}{s}{s}{s}";
    const hint = std.fmt.allocPrint(arena, hint_template, .{
        hint_cookie_name,
        max_age,
        domain_label(project),
        domain_of(project),
        secure_suffix(request),
    }) catch return;

    response.add_header("Set-Cookie", hint) catch return;
}

pub fn clear_session_cookie(
    project: *const Project,
    request: *const http.Request,
    response: *http.Response,
    arena: std.mem.Allocator,
) Error!void {
    std.debug.assert(project.session_cookie.len > 0);
    std.debug.assert(request.path().len > 0);

    const template = "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0{s}{s}{s}";
    const value = std.fmt.allocPrint(arena, template, .{
        project.session_cookie,
        domain_label(project),
        domain_of(project),
        secure_suffix(request),
    }) catch return error.OutOfMemory;
    const hint_template = "{s}=; Path=/; SameSite=Lax; Max-Age=0{s}{s}{s}";
    const hint = std.fmt.allocPrint(arena, hint_template, .{
        hint_cookie_name,
        domain_label(project),
        domain_of(project),
        secure_suffix(request),
    }) catch return error.OutOfMemory;

    try response.set_header("Set-Cookie", value);
    try response.add_header("Set-Cookie", hint);
}

/// `; Domain=` and the project's domain when an app answers on a subdomain: one sign-in
/// then holds on every app of the project. Nothing otherwise (`Project.cookie_domain`).
pub fn domain_label(project: *const Project) []const u8 {
    std.debug.assert(project.domain.len <= 255);
    std.debug.assert(project.apps.len <= 1024);

    return if (project.cookie_domain() == null) "" else "; Domain=";
}

pub fn domain_of(project: *const Project) []const u8 {
    std.debug.assert(project.domain.len <= 255);
    std.debug.assert(project.apps.len <= 1024);

    return project.cookie_domain() orelse "";
}

pub fn secure_suffix(request: *const http.Request) []const u8 {
    const proto = request.header("x-forwarded-proto") orelse "";
    const secure = std.ascii.eqlIgnoreCase(proto, "https");

    std.debug.assert(proto.len <= 8 << 10);
    std.debug.assert(!secure or proto.len == 5);

    return if (secure) "; Secure" else "";
}

pub fn context(project: *const Project, arena: std.mem.Allocator, caller: Caller) sdk.Ctx {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(project.auth.secret.len == csrf.secret_len);

    var ctx = sdk.Ctx.init(.{
        .caller = caller,
        .db = project.connection,
        .io = project.io,
        .arena = arena,
        .auth = project.auth,
        .now_ms = sdk.context.wall_clock_ms(project.io),
    });

    ctx.sandboxed_plugins = project.sandboxed_plugins;
    ctx.plugin_states = project.plugin_states;
    ctx.files = project.files;
    ctx.apps = if (project.apps_host) |host| host.folder() else null;
    ctx.builder = project.builder;

    return ctx;
}

test "cookie parsing" {
    const mixed = cookie_value("a=1; publr_session=abc; b=2", cookie_name).?;
    try std.testing.expectEqualStrings("abc", mixed);
    try std.testing.expectEqualStrings("abc", cookie_value("publr_session=abc", cookie_name).?);
    try std.testing.expect(cookie_value("a=1; b=2", cookie_name) == null);
    try std.testing.expect(cookie_value("", cookie_name) == null);
}

test "a device's bearer token: its account, its scope, no CSRF; revoked, anonymous" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const routes = @import("../../server/routes.zig");
    var flow: routes.testing.Flow = undefined;
    flow.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    var system = harness.ctx(.system);
    try @import("../../operations/user.zig").seed_editor(&system);

    const email = "editor@example.com";
    const editor = (try user_module.find_by_email(system.db, flow.arena, email)).?;
    const created = try device_module.create(system.db, std.testing.io, flow.arena, .{
        .user_id = editor.user.id,
        .name = "laptop",
        .scope = "drafts",
    }, 1);
    const template = "{s} /api/device/{s} HTTP/1.1\r\nHost: h\r\n" ++
        "Authorization: Bearer {s}\r\nContent-Length: 0\r\n\r\n";
    const token = created.token_text();

    const listed = try flow.call(try flow.head(template, .{ "GET", "list", token }), "");
    try std.testing.expectEqual(@as(u16, 200), listed.status.code());
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "\"current\":true") != null);

    const revoke_body = try std.fmt.allocPrint(flow.arena, "{{\"id\":\"{s}\"}}", .{
        created.device.id,
    });
    const revoke_head = try flow.head(template, .{ "POST", "revoke", token });
    const revoked = try flow.call(revoke_head, revoke_body);
    try std.testing.expectEqual(@as(u16, 200), revoked.status.code());

    const after = try flow.call(try flow.head(template, .{ "GET", "list", token }), "");
    try std.testing.expectEqual(@as(u16, 403), after.status.code());

    const malformed = "GET /api/device/list HTTP/1.1\r\nHost: h\r\n" ++
        "Authorization: Basic x\r\n\r\n";
    try std.testing.expectEqual(@as(u16, 403), (try flow.call(malformed, "")).status.code());
}
