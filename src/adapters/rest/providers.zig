//! `/auth/<provider>` and `/auth/<provider>/callback`: the core's side of signing in with
//! a provider. The first makes `state` and a PKCE pair, keeps them in a short cookie and
//! sends the browser to the provider; the second checks the state, asks the plugin who the
//! code stands for, and turns that into a session (or a link, for someone signed in).

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const identity_operations = @import("../../operations/identity.zig");
const identity_module = @import("identity.zig");
const rest_auth = @import("auth.zig");
const ids = @import("../../lib/id.zig");
const environment = @import("../../lib/environment.zig");
const sign_on_operations = @import("../../operations/sign_on.zig");
const http = @import("../../lib/http.zig");
const Project = @import("../../server/project.zig").Project;

const Error = http.Error;
const Request = http.Request;
const Response = http.Response;
const Context = http.Context;
const SignInProvider = sdk.provider.SignInProvider;
const base64 = std.base64.url_safe_no_pad;

pub const cookie_name = "publr_auth";
pub const cookie_lifetime_s: u32 = 10 * 60;
pub const refused_path = "/admin/login?identity=refused";
pub const verifier_len: u32 = ids.len * 2;
pub const next_len_max: u32 = 1024;
/// An origin to advertise as the callback's instead of the request's own, for a machine the
/// providers cannot reach: something at that origin sends the browser on to this one.
pub const callback_origin_variable = "PUBLR_AUTH_CALLBACK_ORIGIN";
const host_len_max: u32 = 255;

/// The two routes over a provider list, so the registry's providers and a test's are the
/// same code. `register` adds `routes_count` routes.
pub fn Routes(comptime providers: []const SignInProvider) type {
    return struct {
        pub const routes_count: u32 = 2;

        pub fn register(router: *http.Router) void {
            std.debug.assert(router.routes_len < 256 - routes_count);
            const before = router.routes_len;

            router.get("/auth/:provider", &start);
            router.get("/auth/:provider/callback", &callback);

            std.debug.assert(router.routes_len == before + routes_count);
        }

        fn start(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            const arena = ctx.arena;
            const provider = offered(request) orelse return unknown(response);
            const wanted = http.Form.query_param(arena, request.query(), "next") orelse "/";
            const local = rest_auth.local_path(wanted) and wanted.len <= next_len_max;
            const next = if (local) wanted else "/";
            var state_buffer: [ids.len]u8 = undefined;
            var verifier_buffer: [verifier_len]u8 = undefined;
            const project = Project.of(ctx);
            const state = ids.random(project.io, &state_buffer);
            const verifier = fresh_verifier(project.io, &verifier_buffer);
            var challenge_buffer: [base64.Encoder.calcSize(32)]u8 = undefined;
            const location = provider.authorize_url(arena, .{
                .callback_url = try callback_url(arena, request, provider.name),
                .state = state,
                .code_challenge = challenge_of(verifier, &challenge_buffer),
            }) catch return response.redirect(.see_other, refused_path);
            const template = "{s}={s}.{s}.{s}; Path=/auth; HttpOnly; SameSite=Lax; Max-Age={d}{s}";
            const cookie = try std.fmt.allocPrint(arena, template, .{
                cookie_name,
                state,
                verifier,
                try encode(arena, next),
                cookie_lifetime_s,
                identity_module.secure_suffix(request),
            });

            try response.set_header("Set-Cookie", cookie);
            try response.set_header("Cache-Control", "no-store");
            try response.redirect(.see_other, location);
        }

        fn callback(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            const arena = ctx.arena;
            const provider = offered(request) orelse return unknown(response);
            const project = Project.of(ctx);
            const gone = "{s}=; Path=/auth; HttpOnly; SameSite=Lax; Max-Age=0{s}";
            const cleared = try std.fmt.allocPrint(arena, gone, .{
                cookie_name,
                identity_module.secure_suffix(request),
            });

            try response.set_header("Cache-Control", "no-store");

            const kept = pending(request, arena) orelse {
                return refuse(response, cleared, "no sign-in cookie came back", null);
            };
            const query = request.query();
            const state = http.Form.query_param(arena, query, "state") orelse "";
            const code = http.Form.query_param(arena, query, "code") orelse "";
            const same_state = std.mem.eql(u8, state, kept.state);
            const failed = http.Form.query_param(arena, query, "error") != null;

            if (!same_state or code.len == 0 or failed) {
                const why = if (failed)
                    "the provider answered with an error"
                else if (!same_state) "the state did not match" else "no code came back";

                return refuse(response, cleared, why, null);
            }

            const identity = provider.identity(project.io, arena, .{
                .callback_url = try callback_url(arena, request, provider.name),
                .code = code,
                .code_verifier = kept.verifier,
            }) catch |err| return refuse(response, cleared, "the provider's identity", err);
            const in: identity_operations.Input = .{
                .provider = provider.name,
                .id = identity.id,
                .email = identity.email,
                .verified = identity.verified,
                .name = identity.name,
                .avatar = identity.avatar,
            };

            try settle(request, response, project, in, kept.next, cleared);
        }

        /// The route's provider, when it is declared and offered.
        fn offered(request: *const Request) ?*const SignInProvider {
            comptime std.debug.assert(providers.len <= sdk.provider.providers_max);

            const name = request.params.get("provider") orelse return null;

            std.debug.assert(name.len > 0);

            const provider = sdk.provider.find(providers, name) orelse return null;

            return if (provider.available()) provider else null;
        }
    };
}

/// Someone signed in gains the identity; anyone else becomes the account it belongs to.
fn settle(
    request: *Request,
    response: *Response,
    project: *Project,
    in: identity_operations.Input,
    next: []const u8,
    cleared: []const u8,
) Error!void {
    std.debug.assert(next.len > 0 and next[0] == '/');
    std.debug.assert(in.provider.len > 0);

    const arena = response.arena;
    const visitor = identity_module.identify(request, arena, project);
    var system = identity_module.context(project, arena, .system);

    if (visitor.caller.user_id()) |user_id| {
        _ = registry.SDK.dispatch(&system, identity_operations.Link, .{
            .user = user_id,
            .provider = in.provider,
            .id = in.id,
            .email = in.email,
            .verified = in.verified,
            .name = in.name,
            .avatar = in.avatar,
        }) catch |err| return refuse(response, cleared, "linking the identity", err);

        try response.set_header("Set-Cookie", cleared);

        return response.redirect(.see_other, next);
    }

    const out = registry.SDK.dispatch(&system, identity_operations.SignIn, in) catch |err| {
        return refuse(response, cleared, "signing the identity in", err);
    };

    try identity_module.set_session_cookie(
        project,
        request,
        response,
        arena,
        out.token,
        out.expires_at,
        system.now_ms,
    );
    try response.add_header("Set-Cookie", cleared);
    try response.redirect(.see_other, next);
}

/// What the cookie kept between the two routes.
const Pending = struct { state: []const u8, verifier: []const u8, next: []const u8 };

fn pending(request: *const Request, arena: std.mem.Allocator) ?Pending {
    std.debug.assert(verifier_len == 48);
    std.debug.assert(ids.len == 24);

    const header = request.header("cookie") orelse return null;
    const value = identity_module.cookie_value(header, cookie_name) orelse return null;
    var parts = std.mem.splitScalar(u8, value, '.');
    const state = parts.next() orelse return null;
    const verifier = parts.next() orelse return null;
    const encoded = parts.next() orelse return null;

    if (state.len != ids.len or verifier.len != verifier_len or parts.next() != null) {
        return null;
    }

    const next = decode(arena, encoded) orelse return null;

    return .{
        .state = state,
        .verifier = verifier,
        .next = if (rest_auth.local_path(next)) next else "/",
    };
}

fn unknown(response: *Response) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(refused_path.len > 0);

    try response.text(.not_found, "no such provider");
}

/// Back to the login form; the server's log says why, as the browser is never told.
fn refuse(response: *Response, cleared: []const u8, why: []const u8, err: ?anyerror) Error!void {
    std.debug.assert(cleared.len > cookie_name.len);
    std.debug.assert(refused_path[0] == '/');

    if (err) |failure| {
        std.log.warn("sign-in with a provider refused: {s}: {t}", .{ why, failure });
    } else {
        std.log.warn("sign-in with a provider refused: {s}", .{why});
    }

    try response.set_header("Set-Cookie", cleared);
    try response.redirect(.see_other, refused_path);
}

/// `<scheme>://<host>/auth/<provider>/callback`, as the provider must send the browser back:
/// the request's own origin, unless `PUBLR_AUTH_CALLBACK_ORIGIN` names another.
fn callback_url(
    arena: std.mem.Allocator,
    request: *const Request,
    name: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len > 0);

    const advertised = environment.get(callback_origin_variable);

    return callback_url_at(arena, advertised, request, name);
}

fn callback_url_at(
    arena: std.mem.Allocator,
    advertised: ?[]const u8,
    request: *const Request,
    name: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(advertised == null or advertised.?.len > 0);

    if (advertised) |origin| {
        if (sign_on_operations.valid_issuer(origin)) {
            return std.fmt.allocPrint(arena, "{s}/auth/{s}/callback", .{ origin, name });
        }
    }

    const proto = request.header("x-forwarded-proto") orelse "";
    const scheme: []const u8 = if (std.ascii.eqlIgnoreCase(proto, "https")) "https" else "http";
    const host = request.header("host") orelse "localhost";

    if (host.len == 0 or host.len > host_len_max) {
        return error.OutOfMemory;
    }

    for (host) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or
            char == ':' or char == '[' or char == ']';

        if (!allowed) {
            return error.OutOfMemory;
        }
    }

    return std.fmt.allocPrint(arena, "{s}://{s}/auth/{s}/callback", .{ scheme, host, name });
}

/// 48 hex characters of randomness: within PKCE's 43 to 128.
fn fresh_verifier(io: std.Io, out: *[verifier_len]u8) []const u8 {
    comptime std.debug.assert(verifier_len == 2 * ids.len);
    comptime std.debug.assert(verifier_len >= 43 and verifier_len <= 128);

    _ = ids.random(io, out[0..ids.len]);
    _ = ids.random(io, out[ids.len..]);

    return out;
}

/// `base64url(sha256(verifier))`, the `S256` challenge.
fn challenge_of(verifier: []const u8, out: *[base64.Encoder.calcSize(32)]u8) []const u8 {
    std.debug.assert(verifier.len == verifier_len);
    std.debug.assert(out.len == 43);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});

    return base64.Encoder.encode(out, &digest);
}

fn encode(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    std.debug.assert(text.len <= next_len_max);

    const out = try arena.alloc(u8, base64.Encoder.calcSize(text.len));

    return base64.Encoder.encode(out, text);
}

fn decode(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    std.debug.assert(next_len_max > 0);

    if (text.len > base64.Encoder.calcSize(next_len_max)) {
        return null;
    }

    const len = base64.Decoder.calcSizeForSlice(text) catch return null;
    const out = arena.alloc(u8, len) catch return null;

    base64.Decoder.decode(out, text) catch return null;

    return out;
}

const user_operations = @import("../../operations/user.zig");

const TestRoutes = Routes(&.{ sdk.provider.testing.trusting, sdk.provider.testing.missing });

const Flow = struct {
    app: http.App,
    project: Project,
    arena: std.mem.Allocator,

    fn init(flow: *Flow, harness: *sdk.testing.Harness, arena: std.mem.Allocator) void {
        std.debug.assert(harness.fixture.connection.transaction_depth == 0);

        flow.* = .{
            .app = http.App.offline(.{}),
            .project = .{
                .connection = &harness.fixture.connection,
                .auth = &harness.auth,
                .io = std.testing.io,
            },
            .arena = arena,
        };
        flow.app.user_data = &flow.project;
        TestRoutes.register(flow.app.router());

        std.debug.assert(flow.app.routes.routes_len == TestRoutes.routes_count);
    }

    fn get(flow: *Flow, path: []const u8, cookie: []const u8) !http.Response {
        std.debug.assert(path[0] == '/');

        const head = try std.fmt.allocPrint(
            flow.arena,
            "GET {s} HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n",
            .{ path, cookie },
        );
        const parsed = try http.parse(head);
        const wire = parsed.complete;
        var request: http.Request = .{ .inner = &wire, .body = "" };

        return flow.app.handle(flow.arena, &request);
    }

    fn callback(flow: *Flow, state: []const u8, code: []const u8) ![]const u8 {
        std.debug.assert(state.len > 0);
        std.debug.assert(code.len > 0);

        return std.fmt.allocPrint(
            flow.arena,
            "/auth/trusting/callback?state={s}&code={s}",
            .{ state, code },
        );
    }

    /// The start route's cookie pair and its state.
    fn begin(flow: *Flow, path: []const u8) !struct { cookie: []const u8, state: []const u8 } {
        std.debug.assert(std.mem.startsWith(u8, path, "/auth/"));

        const started = try flow.get(path, "");
        try std.testing.expectEqual(@as(u16, 303), started.status.code());

        const set = started.header("Set-Cookie").?;
        const pair = set[0..std.mem.indexOfScalar(u8, set, ';').?];
        const state = pair[cookie_name.len + 1 ..][0..ids.len];

        return .{ .cookie = pair, .state = state };
    }
};

test "start keeps state and PKCE in a cookie and sends the browser to the provider" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: Flow = undefined;
    flow.init(&harness, arena_state.allocator());

    const started = try flow.get("/auth/trusting?next=/admin", "");
    const location = started.header("Location").?;
    const cookie = started.header("Set-Cookie").?;
    const state = cookie[cookie_name.len + 1 ..][0..ids.len];
    const verifier = cookie[cookie_name.len + 1 + ids.len + 1 ..][0..verifier_len];
    var challenge_buffer: [43]u8 = undefined;
    const challenge = challenge_of(verifier, &challenge_buffer);
    const expected = try std.fmt.allocPrint(flow.arena, "https://provider.test/authorize?" ++
        "redirect_uri=http://h/auth/trusting/callback&state={s}&code_challenge={s}", .{
        state,
        challenge,
    });

    try std.testing.expectEqualStrings(expected, location);
    const attributes = "; Path=/auth; HttpOnly; SameSite=Lax; Max-Age=600";
    try std.testing.expect(std.mem.indexOf(u8, cookie, attributes) != null);
    try std.testing.expectEqualStrings("no-store", started.header("Cache-Control").?);

    try std.testing.expectEqual(@as(u16, 404), (try flow.get("/auth/missing", "")).status.code());
    try std.testing.expectEqual(@as(u16, 404), (try flow.get("/auth/github", "")).status.code());
}

test "callback signs in with the right state, refuses everything else, and links when signed in" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: Flow = undefined;
    flow.init(&harness, arena_state.allocator());

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);

    const begun = try flow.begin("/auth/trusting?next=/admin/content");
    const good = try flow.callback(begun.state, "7:admin@example.com");

    const bare = try flow.get(good, "");
    try std.testing.expectEqualStrings(refused_path, bare.header("Location").?);

    const refused = [_][]const u8{
        try flow.callback("nope", "7:admin@example.com"),
        try flow.callback(begun.state, "refuse"),
        try flow.callback(begun.state, "down"),
        try flow.callback(begun.state, "9:eve@example.com"),
        try flow.callback(begun.state, "7:admin@example.com:unverified"),
    };

    for (refused) |path| {
        const answer = try flow.get(path, begun.cookie);
        try std.testing.expectEqualStrings(refused_path, answer.header("Location").?);
        const set = answer.header("Set-Cookie").?;
        try std.testing.expect(std.mem.indexOf(u8, set, "Max-Age=0") != null);
    }

    const signed = try flow.get(good, begun.cookie);
    try std.testing.expectEqual(@as(u16, 303), signed.status.code());
    try std.testing.expectEqualStrings("/admin/content", signed.header("Location").?);
    const session_cookie = signed.header("Set-Cookie").?;
    const session_prefix = identity_module.cookie_name ++ "=";
    try std.testing.expect(std.mem.startsWith(u8, session_cookie, session_prefix));
    const session_pair = session_cookie[0..std.mem.indexOfScalar(u8, session_cookie, ';').?];

    // Signed in already: a second provider is linked, no new session.
    const again = try flow.begin("/auth/trusting");
    const link_path = try flow.callback(again.state, "8:other@example.com");
    const both = try std.fmt.allocPrint(flow.arena, "{s}; {s}", .{ session_pair, again.cookie });
    const linked = try flow.get(link_path, both);
    try std.testing.expectEqualStrings("/", linked.header("Location").?);
    try std.testing.expect(std.mem.indexOf(u8, linked.header("Set-Cookie").?, "Max-Age=0") != null);

    const admin = (try registry.SDK.dispatch(&system, user_operations.List, .{})).users[0];
    const list = identity_operations.List;
    const mine = try registry.SDK.dispatch(&system, list, .{ .user = admin.id });
    try std.testing.expectEqual(@as(usize, 2), mine.identities.len);
    try std.testing.expectEqualStrings("8", mine.identities[1].id);
}

test "an advertised origin replaces the request's own in the callback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "GET /auth/github HTTP/1.1\r\nHost: publr.localhost:8085\r\n\r\n";
    const parsed = try http.parse(head);
    const wire = parsed.complete;
    const request: http.Request = .{ .inner = &wire, .body = "" };

    const own = try callback_url_at(arena, null, &request, "github");
    try std.testing.expectEqualStrings("http://publr.localhost:8085/auth/github/callback", own);

    const elsewhere = try callback_url_at(arena, "https://dev.publr.app", &request, "github");
    try std.testing.expectEqualStrings("https://dev.publr.app/auth/github/callback", elsewhere);

    // Not an origin: ignored, never trusted.
    const bad = try callback_url_at(arena, "https://dev.publr.app/x", &request, "github");
    try std.testing.expectEqualStrings(own, bad);
}

test "next must be a path on this site" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: Flow = undefined;
    flow.init(&harness, arena_state.allocator());

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);

    const begun = try flow.begin("/auth/trusting?next=//evil.test/");
    const path = try flow.callback(begun.state, "7:admin@example.com");
    const signed = try flow.get(path, begun.cookie);

    try std.testing.expectEqualStrings("/", signed.header("Location").?);
}
