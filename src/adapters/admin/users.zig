//! Accounts in the admin: the list under Settings, and one account's form.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../app/registry.zig");
const user_operations = @import("../../operations/user.zig");
const settings_nav = @import("settings_nav.zig");
const fields = @import("fields.zig");
const editor = @import("editor.zig");
const model = @import("../../model.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Role = @import("../../sdk.zig").caller.Role;
const Def = model.field.Def;
const Value = std.json.Value;
const Problem = views.UserForm.ProblemsItem;

pub const back = "/admin/settings/users";

/// What the form shows: the account, or what was typed for a new one.
const Shape = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    email: []const u8 = "",
    role: Role = .editor,
    is_admin: bool = false,
    invited: bool = false,
    link: []const u8 = "",
    problem: []const u8 = "",
    /// The custom fields that apply to the account, and its values; none for a new one.
    defs: []const Def = &.{},
    document: ?Value = null,
    problems: []const Problem = &.{},
};

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const listed = registry.SDK.dispatch(&session.ctx, user_operations.List, .{}) catch |err| {
        return admin.fail(&session, err, "/admin/settings");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.Users.UsersItem, listed.users.len);
    const me = session.ctx.caller.user_id() orelse "";

    for (listed.users, rows) |user, *row| {
        row.* = .{
            .href = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, user.id }),
            .name = user.display_name,
            .email = user.email,
            .role = role_label(user.role),
            .active = user.active,
            .me = std.mem.eql(u8, user.id, me),
        };
    }

    const shell = admin.shell_of(&session);

    try admin.render.page(response, arena, .ok, views.Users, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(&session, "users"),
        .users = rows,
    });
}

pub fn new_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    try render_form(&session, .ok, .{});
}

pub fn create(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back ++ "/new") orelse return;
    const session = &post.session;
    const password = post.form.text("password");
    var shape: Shape = .{
        .name = post.form.text("display_name") orelse "",
        .email = post.form.text("email") orelse "",
        .is_admin = role_of(&post.form) == .admin,
    };
    const created = registry.SDK.dispatch(&session.ctx, user_operations.Create, .{
        .email = shape.email,
        .display_name = shape.name,
        .role = role_of(&post.form),
        .password = password,
        .password_link = password == null,
    }) catch |err| {
        shape.problem = reason(err, .create) orelse return admin.fail(session, err, back);

        return render_form(session, .unprocessable_content, shape);
    };

    if (created.link) |link| {
        shape.id = created.user_id;
        shape.invited = true;
        shape.link = link.path;

        return render_form(session, .ok, shape);
    }

    try response.redirect(.see_other, try std.fmt.allocPrint(session.arena, "{s}/{s}", .{
        back,
        created.user_id,
    }));
}

pub fn edit(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const shape = try load(&session, id) orelse return;

    try render_form(&session, .ok, shape);
}

pub fn update(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const form = &post.form;
    const id = try admin.param(session, "id", back) orelse return;
    var shape = try load(session, id) orelse return;
    // The signed-in user's own role is fixed on the form, so it is not posted.
    const role = if (form.get("role") == null) shape.role else role_of(form);

    shape.name = form.text("display_name") orelse "";
    shape.is_admin = role == .admin;

    if (try reshaped(session, &shape, form)) {
        return;
    }

    const document = fields.decode.document_of(session.arena, shape.defs, form) orelse {
        return admin.fail(session, error.Invalid, back);
    };
    _ = registry.SDK.dispatch(&session.ctx, user_operations.Update, .{
        .user = id,
        .display_name = shape.name,
        .role = role,
        .document = document,
    }) catch |err| {
        shape.problem = reason(err, .update) orelse return admin.fail(session, err, back);
        shape.problems = try problems_of(session, id, document);
        shape.document = parse(session.arena, document);

        return render_form(session, .unprocessable_content, shape);
    };

    try response.redirect(.see_other, try std.fmt.allocPrint(session.arena, "{s}/{s}", .{
        back,
        id,
    }));
}

pub fn password_link(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;
    var shape = try load(session, id) orelse return;
    const issued = registry.SDK.dispatch(&session.ctx, user_operations.PasswordLink, .{
        .user = id,
    }) catch |err| return admin.fail(session, err, back);

    shape.link = issued.link.path;

    try render_form(session, .ok, shape);
}

pub fn delete(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;
    _ = registry.SDK.dispatch(&session.ctx, user_operations.Delete, .{ .user = id }) catch |err| {
        var shape = try load(session, id) orelse return;

        shape.problem = reason(err, .delete) orelse return admin.fail(session, err, back);

        return render_form(session, .unprocessable_content, shape);
    };

    try response.redirect(.see_other, back);
}

/// The account behind the route's id, with its custom fields and their values; answers
/// null after a not-found page otherwise.
fn load(session: *Session, id: []const u8) Error!?Shape {
    std.debug.assert(session.signed_in());
    std.debug.assert(id.len > 0);

    const in: user_operations.Get.In = .{ .user = id };
    const got = registry.SDK.dispatch(&session.ctx, user_operations.Get, in) catch |err| {
        try admin.fail(session, err, back);

        return null;
    };
    const user = got.user;

    return .{
        .id = user.id,
        .name = user.display_name,
        .email = user.email,
        .role = user.role,
        .is_admin = user.role == .admin,
        .invited = !user.active,
        .defs = got.fields,
        .document = parse(session.arena, got.document),
    };
}

/// A reshape post (an item added to a repeater, a value removed from a list): the form
/// drawn again with the document changed, nothing saved. True when it was one.
fn reshaped(session: *Session, shape: *Shape, form: *const admin.Form) Error!bool {
    std.debug.assert(session.signed_in());
    std.debug.assert(form.len <= admin.form_pairs_max);

    const verb = form.text("reshape") orelse return false;
    const posted = fields.decode.value_of(session.arena, shape.defs, form) catch {
        try admin.fail(session, error.Invalid, back);

        return true;
    };

    shape.document = fields.reshape.apply(session.arena, shape.defs, posted, verb, form) catch {
        try admin.fail(session, error.Invalid, back);

        return true;
    };

    try render_form(session, .ok, shape.*);

    return true;
}

/// Why the values were refused, by path, from the validate operation.
fn problems_of(session: *Session, id: []const u8, document: []const u8) Error![]const Problem {
    std.debug.assert(id.len > 0);
    std.debug.assert(document.len > 0);

    const checked = registry.SDK.dispatch(&session.ctx, user_operations.Validate, .{
        .user = id,
        .document = document,
    }) catch return &.{};
    const problems = try session.arena.alloc(Problem, checked.problems.len);

    for (checked.problems, problems) |problem, *out| {
        out.* = .{ .path = problem.path, .message = problem.message };
    }

    return problems;
}

fn parse(arena: std.mem.Allocator, text: []const u8) ?Value {
    std.debug.assert(text.len <= fields.json_bytes_max);
    std.debug.assert(text.len >= 2);

    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return null;

    return if (parsed == .object) parsed else null;
}

/// The custom field rows: the account's groups as the record editor draws them.
fn field_rows(session: *Session, shape: Shape) Error!?admin.render.Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(shape.defs.len <= model.field.fields_max);

    if (shape.id.len == 0 or shape.defs.len == 0) {
        return null;
    }

    const def = model.content_type.Def{
        .handle = "user",
        .name = "User",
        .kind = .component,
        .title_field = "",
        .fields = shape.defs,
    };
    const context: fields.Context = .{
        .arena = session.arena,
        .users = try editor.user_options(session, def.fields),
        .referenced = try editor.referenced_of(session, def, shape.document),
        .types = try editor.types_of(session, def),
        .terms = try editor.terms_of(session, def),
        .slug_prefix = "",
    };
    const rows = try fields.rows_of(context, shape.defs, shape.document);

    return try admin.render.view(session.arena, views.RecordFields, .{ .fields = rows });
}

fn render_form(session: *Session, status: admin.Status, shape: Shape) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(shape.id.len == 0 or shape.email.len > 0);

    const arena = session.arena;
    const is_new = shape.id.len == 0;
    const me = session.ctx.caller.user_id() orelse "";
    const shell = admin.shell_of(session);
    const own = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, shape.id });

    try admin.render.page(session.response, arena, status, views.UserForm, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(session, "users"),
        .title = if (is_new) "New user" else shape.name,
        .action = if (is_new) back ++ "/create" else try std.mem.concat(arena, u8, &.{
            own,
            "/update",
        }),
        .is_new = is_new,
        .is_me = !is_new and std.mem.eql(u8, shape.id, me),
        .name = shape.name,
        .email = shape.email,
        .is_admin = shape.is_admin,
        .invited = shape.invited,
        .link = shape.link,
        .link_action = try std.mem.concat(arena, u8, &.{ own, "/password-link" }),
        .delete_action = try std.mem.concat(arena, u8, &.{ own, "/delete" }),
        .problem = shape.problem,
        .fields = try field_rows(session, shape),
        .problems = shape.problems,
    });
}

const Verb = enum { create, update, delete };

/// What a refused write is told in the form's own words; null for what is not the
/// form's fault.
fn reason(err: anyerror, verb: Verb) ?[]const u8 {
    std.debug.assert(@errorName(err).len > 0);
    std.debug.assert(@typeInfo(Verb).@"enum".fields.len == 3);

    return switch (err) {
        error.Invalid => switch (verb) {
            .create => "the name or the email is not valid, or the password is shorter " ++
                "than 8 characters",
            .update => "the name is not valid, and your own role cannot be changed by you",
            .delete => "you cannot delete yourself",
        },
        error.Conflict => switch (verb) {
            .create => "an account with that email already exists",
            .update => "the last admin must stay an admin",
            .delete => "the last admin cannot be deleted",
        },
        else => null,
    };
}

fn role_of(form: *const admin.Form) Role {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(@typeInfo(Role).@"enum".fields.len == 2);

    const text = form.text("role") orelse "editor";

    return if (std.mem.eql(u8, text, "admin")) .admin else .editor;
}

fn role_label(role: Role) []const u8 {
    std.debug.assert(@typeInfo(Role).@"enum".fields.len == 2);
    std.debug.assert(@intFromEnum(role) < 2);

    return switch (role) {
        .admin => "Admin",
        .editor => "Editor",
    };
}

test "users under settings: invite by link, rename, reissue, delete; the rail signs out" {
    const sdk = @import("../../sdk.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const door = try flow.call("GET", "/admin/settings", "");
    try std.testing.expectEqualStrings("/admin/settings/system", door.header("Location").?);
    const system_page = try flow.call("GET", "/admin/settings/system", "");
    try std.testing.expectEqual(.ok, system_page.status);
    try std.testing.expect(std.mem.indexOf(u8, system_page.body, "Nothing to configure") != null);
    const users_link = "href=\"" ++ back ++ "\"";
    try std.testing.expect(std.mem.indexOf(u8, system_page.body, users_link) != null);

    const listed = try flow.call("GET", back, "");
    try std.testing.expectEqual(.ok, listed.status);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "ada@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "(you)") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "data-part=\"account\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "action=\"/admin/logout\"") != null);
    const csrf = flow.csrf_of(listed.body);

    const invite = try std.fmt.allocPrint(
        arena,
        "csrf={s}&display_name=Writer&email=writer%40example.com&role=editor&password=",
        .{csrf},
    );
    const invited = try flow.call("POST", back ++ "/create", invite);
    try std.testing.expectEqual(.ok, invited.status);
    const link_prefix = "/api/auth/set-password?token=";
    try std.testing.expect(std.mem.indexOf(u8, invited.body, link_prefix) != null);
    const own_action = "action=\"" ++ back ++ "/";
    const own_start = std.mem.indexOf(u8, invited.body, own_action).? + own_action.len;
    const own_id = invited.body[own_start..][0..24];
    const own = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, own_id });
    const twice = try flow.call("POST", back ++ "/create", invite);
    try std.testing.expectEqual(.unprocessable_content, twice.status);
    try std.testing.expect(std.mem.indexOf(u8, twice.body, "already exists") != null);

    const page = try flow.call("GET", own, "");
    try std.testing.expectEqual(.ok, page.status);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "value=\"Writer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "New set-password link") != null);
    const rename = try std.fmt.allocPrint(arena, "csrf={s}&display_name=Author&role=admin", .{
        csrf,
    });
    const update_path = try std.mem.concat(arena, u8, &.{ own, "/update" });
    const renamed = try flow.call("POST", update_path, rename);
    try std.testing.expectEqualStrings(own, renamed.header("Location").?);
    const after = try flow.call("GET", back, "");
    try std.testing.expect(std.mem.indexOf(u8, after.body, ">Author</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.body, "Invited") != null);

    const only_csrf = try std.fmt.allocPrint(arena, "csrf={s}", .{csrf});
    const link_path = try std.mem.concat(arena, u8, &.{ own, "/password-link" });
    const reissued = try flow.call("POST", link_path, only_csrf);
    try std.testing.expectEqual(.ok, reissued.status);
    try std.testing.expect(std.mem.indexOf(u8, reissued.body, "?token=") != null);

    const rows = listed.body[std.mem.indexOf(u8, listed.body, "<tbody").?..];
    const row_link = "href=\"" ++ back ++ "/";
    const me_start = std.mem.indexOf(u8, rows, row_link).? + row_link.len;
    const me = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, rows[me_start..][0..24] });
    const self_path = try std.mem.concat(arena, u8, &.{ me, "/delete" });
    const self_delete = try flow.call("POST", self_path, only_csrf);
    try std.testing.expectEqual(.unprocessable_content, self_delete.status);
    try std.testing.expect(std.mem.indexOf(u8, self_delete.body, "cannot delete yourself") != null);

    const group = try std.fmt.allocPrint(
        arena,
        "csrf={s}&name=Basic&handle=basic&active=on&" ++
            "location.0.0.field=destination&location.0.0.value=user",
        .{csrf},
    );
    _ = try flow.call("POST", "/admin/custom-fields/create", group);
    const bio = try std.fmt.allocPrint(
        arena,
        "csrf={s}&kind=email&name=mail&label=Mail&next=finish",
        .{csrf},
    );
    _ = try flow.call("POST", "/admin/custom-fields/basic/fields/create", bio);
    const with_fields = try flow.call("GET", own, "");
    const rows_part = "data-part=\"user-fields\"";
    try std.testing.expect(std.mem.indexOf(u8, with_fields.body, rows_part) != null);
    try std.testing.expect(std.mem.indexOf(u8, with_fields.body, "name=\"basic.mail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_fields.body, ">Basic<") != null);
    const filled = try std.fmt.allocPrint(
        arena,
        "csrf={s}&display_name=Author&role=admin&basic.mail=ada%40example.org",
        .{csrf},
    );
    const saved = try flow.call("POST", update_path, filled);
    try std.testing.expectEqualStrings(own, saved.header("Location").?);
    const shown = try flow.call("GET", own, "");
    try std.testing.expect(std.mem.indexOf(u8, shown.body, "value=\"ada@example.org\"") != null);
    const blank_bio = try std.fmt.allocPrint(
        arena,
        "csrf={s}&display_name=Author&role=admin&basic.mail=nope",
        .{csrf},
    );
    const refused_bio = try flow.call("POST", update_path, blank_bio);
    try std.testing.expectEqual(.unprocessable_content, refused_bio.status);
    try std.testing.expect(std.mem.indexOf(u8, refused_bio.body, "basic.mail") != null);
    const kept = try flow.call("GET", own, "");
    try std.testing.expect(std.mem.indexOf(u8, kept.body, "value=\"ada@example.org\"") != null);

    const delete_path = try std.mem.concat(arena, u8, &.{ own, "/delete" });
    const deleted = try flow.call("POST", delete_path, only_csrf);
    try std.testing.expectEqualStrings(back, deleted.header("Location").?);
    const gone = try flow.call("GET", back, "");
    try std.testing.expect(std.mem.indexOf(u8, gone.body, "writer@example.com") == null);
}
