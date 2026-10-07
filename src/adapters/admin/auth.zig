const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const project_operations = @import("../../operations/project.zig");
const sign_in_operations = @import("../../operations/sign_in.zig");
const sign_on_operations = @import("../../operations/sign_on.zig");
const identity_operations = @import("../../operations/identity.zig");
const identity_module = @import("../rest/identity.zig");
const rest_auth = @import("../rest/auth.zig");
const dashboard = @import("dashboard.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const Form = admin.Form;
const views = admin.views;

pub fn home(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);

    if (!try initialised(&session)) {
        return response.redirect(.see_other, "/admin/setup");
    }

    if (!session.signed_in() or !registry.SDK.reaches_admin(&session.ctx)) {
        return response.redirect(.see_other, "/admin/login");
    }

    const shortcuts = try dashboard.shortcuts_of(&session);

    try admin.screen(&session, .ok, views.Dashboard, .{ .shortcuts = shortcuts });
}

fn initialised(session: *Session) Error!bool {
    std.debug.assert(session.ctx.now_ms > 0);
    std.debug.assert(project_operations.setup_key.len > 0);

    const status = registry.SDK.dispatch(&session.ctx, project_operations.Status, .{}) catch {
        return error.OutOfMemory;
    };

    return status.initialised;
}

pub fn setup_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);

    if (try initialised(&session)) {
        return response.redirect(.see_other, "/admin/login");
    }

    try render_setup(response, ctx.arena, session.project.base, null);
}

fn render_setup(
    response: *Response,
    arena: std.mem.Allocator,
    base: []const u8,
    problem: ?[]const u8,
) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(problem == null or problem.?.len > 0);

    const request = try admin.chrome.signed_out_at(arena, base);

    try admin.render.page(response, arena, request, .ok, views.Setup, .{
        .notice = problem,
    });
}

pub fn setup(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const arena = ctx.arena;
    const form = Form.parse(arena, request.body) orelse {
        return render_setup(response, arena, session.project.base, "bad form");
    };

    if (!session.guard(&form)) {
        return render_setup(response, arena, session.project.base, "cross-origin request refused");
    }

    const email = form.text("email") orelse {
        return render_setup(response, arena, session.project.base, "email is required");
    };
    const name = form.text("display_name") orelse {
        return render_setup(response, arena, session.project.base, "name is required");
    };
    const password = form.get("password") orelse {
        return render_setup(response, arena, session.project.base, "password is required");
    };

    _ = registry.SDK.dispatch(&session.ctx, project_operations.Init, .{
        .email = email,
        .display_name = name,
        .password = password,
    }) catch |err| return render_setup(response, arena, session.project.base, @errorName(err));

    try start_session(&session, email, password, "/admin/setup");
}

pub fn login_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);

    if (session.signed_in()) {
        if (registry.SDK.reaches_admin(&session.ctx)) {
            return response.redirect(.see_other, "/admin/content");
        }

        return render_login(&session, no_access);
    }

    if (try sign_in_elsewhere(&session)) |location| {
        return response.redirect(.see_other, location);
    }

    // A site that trusts an issuer sends you there first; it sends you back signed in, or
    // with `sign_on` set when it could not, and then the form is the way in.
    if (admin.query_param(&session, "sign_on") == null) {
        if (try issuer_login(&session)) |location| {
            return response.redirect(.see_other, location);
        }
    }

    const declined = admin.query_param(&session, "sign_on") != null;
    const refused = admin.query_param(&session, "identity") != null;
    const notice: ?[]const u8 = if (declined)
        "Sign in with your password."
    else if (refused)
        "That account could not be signed in. Try your password."
    else
        null;

    try render_login(&session, notice);
}

/// Where a compiled-in plugin sends someone who must sign in, instead of the form: the
/// first that names a place. A plugin that fails is logged and passed over.
fn sign_in_elsewhere(session: *const Session) Error!?[]const u8 {
    std.debug.assert(!session.signed_in());
    comptime std.debug.assert(registry.sign_in_at.len <= 64);

    inline for (registry.sign_in_at) |Plugin| {
        const location = Plugin.sign_in_at(session) catch |err| blk: {
            std.log.warn("plugin {s}: sign-in: {t}", .{ Plugin.manifest.name, err });
            break :blk null;
        };

        if (location) |found| {
            return found;
        }
    }

    return null;
}

/// `<issuer>/sign-on?site=<audience>&return=/admin`, when an issuer is trusted.
fn issuer_login(session: *Session) Error!?[]const u8 {
    std.debug.assert(session.ctx.now_ms > 0);

    const status = registry.SDK.dispatch(&session.ctx, sign_on_operations.Status, .{}) catch {
        return error.OutOfMemory;
    };

    if (!status.configured) {
        return null;
    }

    std.debug.assert(sign_on_operations.valid_issuer(status.issuer));

    return std.fmt.allocPrint(session.arena, "{s}/sign-on?site={s}&return={s}", .{
        status.issuer,
        status.audience,
        try return_of(session),
    }) catch error.OutOfMemory;
}

/// The page to come back to after signing in, as the login was given it (`return`),
/// encoded again for the next address; `/admin` when none, or none on this site.
pub fn return_of(session: *const Session) Error![]const u8 {
    std.debug.assert(!session.signed_in());

    const wanted = admin.query_param(session, "return") orelse return "/admin";
    const local = wanted.len > 1 and wanted[0] == '/' and wanted[1] != '/' and wanted[1] != '\\';

    if (!local) {
        return "/admin";
    }

    return admin.query_value(session.arena, wanted);
}

/// What an account whose roles reach none of the admin's operations is told: an app's
/// visitor, whose own sign-in is the app's.
pub const no_access = "This account has no access to the admin.";

fn render_login(session: *const Session, problem: ?[]const u8) Error!void {
    const response = session.response;
    const arena = session.arena;
    const base = session.project.base;

    std.debug.assert(response.body.len == 0);
    std.debug.assert(problem == null or problem.?.len > 0);

    const offered = identity_operations.providers.offered(arena, registry.sign_in_providers) catch {
        return error.OutOfMemory;
    };
    const buttons = try arena.alloc(views.Login.ProvidersItem, offered.len);

    for (offered, buttons) |provider, *button| {
        button.* = .{
            .label = provider.label,
            .icon = provider.icon,
            .href = try std.fmt.allocPrint(arena, "{s}?next=/admin", .{provider.path}),
        };
    }

    const request = try admin.chrome.signed_out_at(arena, base);

    const action = if (coming_back(session)) |page|
        try std.fmt.allocPrint(arena, "/admin/login?return={s}", .{
            try admin.query_value(arena, page),
        })
    else
        "/admin/login";

    try admin.render.page(response, arena, request, .ok, views.Login, .{
        .notice = problem,
        .providers = buttons,
        .action = action,
    });
}

/// The page on this site the login was given to come back to (`return`), if any. The form
/// posts it back in its own address, so a failed attempt keeps it too.
fn coming_back(session: *const Session) ?[]const u8 {
    std.debug.assert(session.request.path().len > 0);

    const wanted = admin.query_param(session, "return") orelse return null;

    if (!rest_auth.local_path(wanted) or !std.mem.startsWith(u8, wanted, "/admin")) {
        return null;
    }

    return wanted;
}

pub fn login(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const arena = ctx.arena;
    const form = Form.parse(arena, request.body) orelse {
        return render_login(&session, "bad form");
    };

    if (!session.guard(&form)) {
        return render_login(&session, "cross-origin request refused");
    }

    const email = form.text("email") orelse {
        return render_login(&session, "email is required");
    };
    const password = form.get("password") orelse {
        return render_login(&session, "password is required");
    };

    try start_session(&session, email, password, "/admin/login");
}

/// Sign in as the anonymous caller, set the cookie and go to the admin.
fn start_session(
    session: *Session,
    email: []const u8,
    password: []const u8,
    back: []const u8,
) Error!void {
    std.debug.assert(email.len > 0);
    std.debug.assert(back.len > 0);

    var anonymous = identity_module.context(session.project, session.arena, .anonymous);
    const out = registry.SDK.dispatch(&anonymous, sign_in_operations.SignIn, .{
        .email = email,
        .password = password,
    }) catch |err| {
        const problem: []const u8 = if (err == error.BadCredentials)
            "wrong email or password"
        else
            @errorName(err);

        return if (std.mem.eql(u8, back, "/admin/login"))
            render_login(session, problem)
        else
            render_setup(session.response, session.arena, session.project.base, problem);
    };
    var signed_in = anonymous;

    signed_in.caller = .{ .user = .{ .id = out.user_id, .roles = out.roles } };

    // The admin's door: an account that may call none of its operations gets no session
    // here; the one just made is ended at once.
    if (!registry.SDK.reaches_admin(&signed_in)) {
        _ = registry.SDK.dispatch(&anonymous, sign_in_operations.SignOut, .{
            .token = out.token,
        }) catch |err| return admin.fail(session, err, back);

        return render_login(session, no_access);
    }

    try identity_module.set_session_cookie(
        session.project,
        session.request,
        session.response,
        session.arena,
        out.token,
        out.expires_at,
        anonymous.now_ms,
    );
    try session.response.redirect(.see_other, coming_back(session) orelse "/admin/content");
}

pub fn logout(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const form = Form.parse(ctx.arena, request.body) orelse Form{};

    if (!session.guard(&form)) {
        return admin.fail(&session, error.RefusedCrossSite, "/admin");
    }

    if (session.identity.token) |token| {
        const sign_out = sign_in_operations.SignOut;

        _ = registry.SDK.dispatch(&session.ctx, sign_out, .{ .token = token }) catch |err| {
            return admin.fail(&session, err, "/admin");
        };
    }

    try identity_module.clear_session_cookie(session.project, request, response, ctx.arena);
    try response.redirect(.see_other, "/admin/login");
}
