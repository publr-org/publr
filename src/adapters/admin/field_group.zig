const std = @import("std");
const admin = @import("../admin.zig");
const schemas = @import("schema_fields.zig");
const spaces = @import("schema_space.zig");
const rules = @import("field_conditions.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    var session = try admin.require(request, response, ctx) orelse return;
    const handle = try admin.param(&session, "handle", "/admin/structure") orelse return;
    const got = schemas.load(&session, handle) catch |err| {
        return admin.fail(&session, err, "/admin/structure");
    };
    const fragment = request.header("publr-fragment") orelse "";

    if (std.mem.eql(u8, fragment, "columns")) {
        return @import("type_fields/levels.zig").page(&session, handle, got.definition, null);
    }

    try render(&session, response, got.definition, false);
}

pub fn render(
    session: *admin.Session,
    response: *admin.Response,
    def: model.content_type.Def,
    fresh: bool,
) admin.Error!void {
    std.debug.assert(session.signed_in());
    const shell = admin.shell_of(session);
    const subjects = try subjects_of(session);
    const hub = try std.fmt.allocPrint(session.arena, "/admin/custom-fields/{s}", .{def.handle});
    try admin.render.page(response, session.arena, .ok, admin.views.FieldGroup, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .title = if (fresh) "New field group" else def.name,
        .name = def.name,
        .handle = def.handle,
        .fresh = fresh,
        .back = "/admin/custom-fields",
        .action = if (fresh) "/admin/custom-fields/create" else try std.fmt.allocPrint(
            session.arena,
            "{s}/update",
            .{
                hub,
            },
        ),
        .delete_action = try std.fmt.allocPrint(session.arena, "{s}/delete", .{hub}),
        .active = def.group.active,
        .position = @tagName(def.group.presentation.position),
        .labels = @tagName(def.group.presentation.labels),
        .instructions = @tagName(def.group.presentation.instructions),
        .rules = try rules.render(session.arena, def.group.location, subjects, "location", true),
        .fields = if (fresh) .{
            .raw = "",
        } else try @import("type_fields/columns.zig").list_node(
            session,
            def.handle,
            def,
        ),
    });
}

pub fn save(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    var post = try admin.accept(request, response, ctx, "/admin/structure") orelse return;
    const session = &post.session;
    const handle = try admin.param(session, "handle", "/admin/structure") orelse return;
    const got = schemas.load(session, handle) catch |err| {
        return admin.fail(session, err, "/admin/structure");
    };
    const back = try spaces.hub(session, handle);
    var def = got.definition;
    def.name = post.form.text("name") orelse def.name;
    def.group = options(session, &post.form) catch |err| {
        return admin.fail(session, err, back);
    };
    const encoded = model.content_type.encode(session.arena, def) catch |err| {
        return admin.fail(session, err, back);
    };
    schemas.update(session, handle, encoded, false) catch |err| {
        return admin.fail(session, err, back);
    };
    try response.redirect(.see_other, back);
}

pub fn options(session: *admin.Session, form: *const admin.Form) !model.field_group.Options {
    std.debug.assert(session.signed_in());
    return .{
        .active = form.get("active") != null,
        .location = try rules.read(session.arena, form, "location"),
        .presentation = .{
            .position = std.meta.stringToEnum(
                model.field_group.Position,
                form.text("position") orelse "main",
            ) orelse return error.Invalid,
            .labels = std.meta.stringToEnum(
                model.field_group.Labels,
                form.text("labels") orelse "above",
            ) orelse return error.Invalid,
            .instructions = std.meta.stringToEnum(
                model.field_group.Instructions,
                form.text("instructions") orelse "below_input",
            ) orelse return error.Invalid,
        },
    };
}

fn subjects_of(session: *admin.Session) ![]const admin.views.RuleBuilder.SubjectsItem {
    std.debug.assert(session.signed_in());
    const media = model.field.options.media_types;
    const values = try session.arena.alloc([]const u8, media.len);
    const labels = try session.arena.alloc([]const u8, media.len);

    for (media, 0..) |kind, index| {
        values[index] = kind.id;
        labels[index] = kind.label;
    }

    const roles = registry.Roles.all;
    const role_names = try session.arena.alloc([]const u8, roles.len);
    const role_labels = try session.arena.alloc([]const u8, roles.len);

    for (roles, 0..) |role, index| {
        role_names[index] = role.name;
        role_labels[index] = role.label;
    }

    const defs = [_]model.field.Def{
        .{ .name = "destination", .label = "Location", .kind = "select", .options = .{
            .choices = &.{ "user", "media" },
            .labels = &.{ "User", "Media" },
        } },
        .{ .name = "role", .label = "User role", .kind = "select", .options = .{
            .choices = role_names,
            .labels = role_labels,
        } },
        .{ .name = "media_type", .label = "Media type", .kind = "select", .options = .{
            .choices = values,
            .labels = labels,
        } },
    };
    const subjects = try session.arena.alloc(admin.views.RuleBuilder.SubjectsItem, defs.len);

    for (defs, 0..) |def, index| {
        subjects[index] = .{
            .value = def.name,
            .label = def.label,
            .choices = try rules.choices_of(
                session.arena,
                def,
            ),
        };
    }

    return subjects;
}
