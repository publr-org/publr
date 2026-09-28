const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const project_operations = @import("../../operations/project.zig");
const sign_in_operations = @import("../../operations/sign_in.zig");
const sign_on_operations = @import("../../operations/sign_on.zig");
const identity_module = @import("../rest/identity.zig");

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

    const shell = admin.shell_of(&session);

    try admin.render.page(response, session.arena, .ok, views.Dashboard, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .csrf = shell.csrf,
    });
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

    try render_setup(response, ctx.arena, null);
}

fn render_setup(response: *Response, arena: std.mem.Allocator, problem: ?[]const u8) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(problem == null or problem.?.len > 0);

    try admin.render.page(response, arena, .ok, views.Setup, .{ .notice = problem });
}

pub fn setup(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const arena = ctx.arena;
    const form = Form.parse(arena, request.body) orelse {
        return render_setup(response, arena, "bad form");
    };

    if (!session.guard(&form)) {
        return render_setup(response, arena, "cross-origin request refused");
    }

    const email = form.text("email") orelse {
        return render_setup(response, arena, "email is required");
    };
    const name = form.text("display_name") orelse {
        return render_setup(response, arena, "name is required");
    };
    const password = form.get("password") orelse {
        return render_setup(response, arena, "password is required");
    };

    _ = registry.SDK.dispatch(&session.ctx, project_operations.Init, .{
        .email = email,
        .display_name = name,
        .password = password,
    }) catch |err| return render_setup(response, arena, @errorName(err));

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

        return render_login(response, ctx.arena, no_access);
    }

    // A site that trusts an issuer sends you there first; it sends you back signed in, or
    // with `sign_on` set when it could not, and then the form is the way in.
    if (admin.query_param(&session, "sign_on") == null) {
        if (try issuer_login(&session)) |location| {
            return response.redirect(.see_other, location);
        }
    }

    const declined = admin.query_param(&session, "sign_on") != null;

    try render_login(response, ctx.arena, if (declined) "Sign in with your password." else null);
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

    return std.fmt.allocPrint(session.arena, "{s}/sign-on?site={s}&return=/admin", .{
        status.issuer,
        status.audience,
    }) catch error.OutOfMemory;
}

/// What an account whose roles reach none of the admin's operations is told: an app's
/// visitor, whose own sign-in is the app's.
pub const no_access = "This account has no access to the admin.";

fn render_login(response: *Response, arena: std.mem.Allocator, problem: ?[]const u8) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(problem == null or problem.?.len > 0);

    try admin.render.page(response, arena, .ok, views.Login, .{ .notice = problem });
}

pub fn login(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const arena = ctx.arena;
    const form = Form.parse(arena, request.body) orelse {
        return render_login(response, arena, "bad form");
    };

    if (!session.guard(&form)) {
        return render_login(response, arena, "cross-origin request refused");
    }

    const email = form.text("email") orelse {
        return render_login(response, arena, "email is required");
    };
    const password = form.get("password") orelse {
        return render_login(response, arena, "password is required");
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
            render_login(session.response, session.arena, problem)
        else
            render_setup(session.response, session.arena, problem);
    };
    var signed_in = anonymous;

    signed_in.caller = .{ .user = .{ .id = out.user_id, .roles = out.roles } };

    // The admin's door: an account that may call none of its operations gets no session
    // here; the one just made is ended at once.
    if (!registry.SDK.reaches_admin(&signed_in)) {
        _ = registry.SDK.dispatch(&anonymous, sign_in_operations.SignOut, .{
            .token = out.token,
        }) catch |err| return admin.fail(session, err, back);

        return render_login(session.response, session.arena, no_access);
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
    try session.response.redirect(.see_other, "/admin/content");
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
