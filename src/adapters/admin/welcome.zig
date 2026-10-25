//! A new person's first screen (`/admin/welcome`): the password when they came by
//! invitation (`?token=`, the link an administrator sends), and the language the admin
//! speaks to them, always. The admin sends anyone who never chose a language here first.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const user_operations = @import("../../operations/user.zig");
const language_operations = @import("../../operations/user/language.zig");
const language_module = @import("language.zig");
const auth = @import("auth.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const Form = admin.Form;
const views = admin.views;

pub const path = "/admin/welcome";

/// Where the admin sends a person still to be welcomed, coming back to `back`.
pub fn address_of(session: *const Session, back: []const u8) Error![]const u8 {
    std.debug.assert(back.len > 0);

    return std.fmt.allocPrint(session.arena, "{s}?back={s}", .{
        path,
        try admin.query_value(session.arena, back),
    });
}

pub fn page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const token = admin.query_param(&session, "token") orelse "";
    const back = admin.query_param(&session, "back") orelse "/admin/content";

    if (token.len == 0 and !session.signed_in()) {
        return response.redirect(.see_other, "/admin/login");
    }

    try draw(&session, token, back, null);
}

fn draw(session: *Session, token: []const u8, back: []const u8, problem: ?[]const u8) Error!void {
    std.debug.assert(back.len > 0);

    const arena = session.arena;
    const choices = language_operations.choices(&session.ctx) catch return error.OutOfMemory;
    const preferred = preferred_of(session, choices);
    const Item = views.Welcome.LanguagesItem;
    const items = try arena.alloc(Item, choices.len);

    for (choices, items) |choice, *item| {
        item.* = .{
            .locale = choice.locale,
            .label = choice.label,
            .selected = std.mem.eql(u8, choice.locale, preferred),
        };
    }

    // Written in the language it preselects, so nobody meets a page they cannot read.
    session.language = try language_module.in(session, preferred);

    const request = try arena.create(admin.render.Request);

    request.* = (try admin.chrome.signed_out_at(arena, session.project.admin_path())).*;
    request.session.csrf = if (session.signed_in()) session.csrf_token() else "";
    language_module.apply(session, request);
    try admin.render.page(session.response, arena, request, .ok, views.Welcome, .{
        .token = token,
        .languages = items,
        .back = back,
        .notice = problem,
    });
}

/// The language to start from: the person's choice once signed in, else the browser's
/// first that the admin speaks, else English.
pub fn preferred_of(session: *Session, choices: []const language_operations.Choice) []const u8 {
    std.debug.assert(choices.len > 0);

    const accepted = session.request.header("accept-language") orelse "";
    var ranges = std.mem.tokenizeAny(u8, accepted, ", ");

    while (ranges.next()) |range| {
        const tag = range[0 .. std.mem.indexOfScalar(u8, range, ';') orelse range.len];

        for (choices) |choice| {
            const exact = std.ascii.eqlIgnoreCase(tag, choice.locale);
            const prefix = tag.len > choice.locale.len and tag[choice.locale.len] == '-' and
                std.ascii.eqlIgnoreCase(tag[0..choice.locale.len], choice.locale);

            if (exact or prefix) {
                return choice.locale;
            }
        }
    }

    return "en";
}

/// `POST /admin/welcome`: the password first when invited (then signed in), the language.
pub fn save(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var session = Session.open(request, response, ctx);
    const form = Form.parse(ctx.arena, request.body) orelse {
        return response.redirect(.see_other, path);
    };
    const token = form.text("token") orelse "";
    const language = form.text("language") orelse "";
    const back_asked = form.text("back") orelse "/admin/content";
    const local = back_asked.len > 0 and back_asked[0] == '/' and
        !std.mem.startsWith(u8, back_asked, "//");
    const back = if (local) back_asked else "/admin/content";

    if (!session.guard(&form)) {
        return draw(&session, token, back, try session.translated(
            "cross-origin request refused",
            .{},
        ));
    }

    if (token.len > 0) {
        return invited(&session, &form, token, language, back);
    }

    if (!session.signed_in()) {
        return response.redirect(.see_other, "/admin/login");
    }

    _ = registry.SDK.dispatch(&session.ctx, language_operations.SetLanguage, .{
        .language = language,
    }) catch |err| return draw(&session, token, back, @errorName(err));

    try response.redirect(.see_other, back);
}

fn invited(
    session: *Session,
    form: *const Form,
    token: []const u8,
    language: []const u8,
    back: []const u8,
) Error!void {
    std.debug.assert(token.len > 0);

    const password = form.get("password") orelse "";
    const identity = @import("../rest/identity.zig");
    var anonymous = identity.context(session.project, session.arena, .anonymous);
    const set = registry.SDK.dispatch(&anonymous, user_operations.SetPassword, .{
        .token = token,
        .password = password,
    }) catch |err| {
        const problem = if (err == error.Failed and anonymous.failure != null)
            anonymous.failure.?.message
        else
            try session.translated("This invitation is used or has expired. " ++
                "Ask an administrator for a new one.", .{});

        return draw(session, token, back, problem);
    };
    var system = anonymous;

    system.caller = .system;

    const person = registry.SDK.dispatch(&system, user_operations.Get, .{
        .user = set.user_id,
    }) catch |err| return draw(session, token, back, @errorName(err));

    try auth.start_session(session, person.user.email, password, "/admin/login", .{
        .language = language,
        .then = back,
    });
}
