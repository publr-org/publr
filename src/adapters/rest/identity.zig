//! Who is making an HTTP request, and how the answer travels: the session cookie, the
//! CSRF guard for writes, and the `Ctx` a handler dispatches with.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const session_module = @import("../../store/sessions.zig");
const user_module = @import("../../store/users.zig");
const csrf = @import("../../lib/auth.zig").csrf;
const http = @import("../../lib/http.zig");
const Project = @import("../../server/project.zig").Project;

const Error = http.Error;
const Caller = sdk.Caller;

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

    const cookie_header = request.header("cookie") orelse return .{};
    const token = cookie_value(cookie_header, cookie_name) orelse return .{};
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
        cookie_name,
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
    std.debug.assert(cookie_name.len > 0);
    std.debug.assert(request.path().len > 0);

    const template = "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0{s}{s}{s}";
    const value = std.fmt.allocPrint(arena, template, .{
        cookie_name,
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
fn domain_label(project: *const Project) []const u8 {
    std.debug.assert(project.domain.len <= 255);
    std.debug.assert(project.apps.len <= 1024);

    return if (project.cookie_domain() == null) "" else "; Domain=";
}

fn domain_of(project: *const Project) []const u8 {
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

    return ctx;
}

test "cookie parsing" {
    const mixed = cookie_value("a=1; publr_session=abc; b=2", cookie_name).?;
    try std.testing.expectEqualStrings("abc", mixed);
    try std.testing.expectEqualStrings("abc", cookie_value("publr_session=abc", cookie_name).?);
    try std.testing.expect(cookie_value("a=1; b=2", cookie_name) == null);
    try std.testing.expect(cookie_value("", cookie_name) == null);
}
