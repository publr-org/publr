const std = @import("std");
const json = @import("../../lib/json.zig");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const types = @import("../../operations/content_type.zig");
const record_operations = @import("../../operations/record.zig");
const snapshots = @import("../../operations/snapshot.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Form = admin.Form;
const Session = admin.Session;
const views = admin.views;

const back = "/admin/content";
const json_bytes_max: u32 = 1 << 20;

/// Every snapshot of a record, newest first, with the revision's title where it has one.
pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const full = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = id,
    }) catch |err| return admin.fail(&session, err, back);
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = full.record.type,
    }) catch |err| return admin.fail(&session, err, back);
    const listed = registry.SDK.dispatch(&session.ctx, snapshots.List, .{
        .id = id,
        .limit = 1000,
    }) catch |err| return admin.fail(&session, err, back);
    const arena = session.arena;
    const record_title = if (full.record.title.len > 0) full.record.title else full.record.id;
    var rows: std.ArrayList(views.Revisions.RowsItem) = .empty;
    var index = listed.snapshots.len;

    while (index > 0) : (index -= 1) {
        const item = listed.snapshots[index - 1];
        const href = std.fmt.allocPrint(arena, "/admin/content/{s}/revisions/{d}", .{
            full.record.id,
            item.seq,
        }) catch return error.OutOfMemory;

        rows.append(arena, .{
            .href = href,
            .seq = std.fmt.allocPrint(arena, "{d}", .{item.seq}) catch return error.OutOfMemory,
            .kind = item.kind,
            .title = title_of(arena, item.document, got.definition.title_field),
            .at = admin.time_text(arena, item.at),
            .by = item.by orelse "",
        }) catch return error.OutOfMemory;
    }

    const shell = admin.shell_of(&session);

    try admin.render.page(response, arena, .ok, views.Revisions, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .csrf = shell.csrf,
        .nav = try admin.nav_content(&session, .{
            .filters = .{ .types = &.{full.record.type}, .type_view = true },
        }),
        .title = std.fmt.allocPrint(arena, "Versions of {s}", .{record_title}) catch {
            return error.OutOfMemory;
        },
        .record_title = record_title,
        .record_href = try record_href(arena, full.record.id),
        .status = full.record.status,
        .changed = full.record.changed,
        .updated = admin.time_text(arena, full.record.updated_at),
        .updated_by = full.record.updated_by orelse "",
        .rows = rows.items,
    });
}

/// One snapshot, field by field, with a way to bring it back.
pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const seq = seq_param(&session) orelse return admin.fail(&session, error.NotFound, back);
    const full = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = id,
    }) catch |err| return admin.fail(&session, err, back);
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = full.record.type,
    }) catch |err| return admin.fail(&session, err, back);
    const item = registry.SDK.dispatch(&session.ctx, snapshots.Get, .{
        .id = id,
        .seq = seq,
    }) catch |err| return admin.fail(&session, err, back);
    const arena = session.arena;
    const document = snapshot_object(arena, item.document) catch |err| {
        return admin.fail(&session, err, back);
    };
    var fields: std.ArrayList(views.Revision.FieldsItem) = .empty;

    for (got.definition.fields) |def| {
        const value: []const u8 = if (document.get(def.name)) |present|
            std.json.Stringify.valueAlloc(arena, present, .{ .whitespace = .indent_2 }) catch {
                return error.OutOfMemory;
            }
        else
            "";

        fields.append(arena, .{ .label = def.label, .value = value }) catch {
            return error.OutOfMemory;
        };
    }

    const record_title = if (full.record.title.len > 0) full.record.title else full.record.id;
    const shell = admin.shell_of(&session);

    try admin.render.page(response, arena, .ok, views.Revision, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .csrf = shell.csrf,
        .nav = try admin.nav_content(&session, .{
            .filters = .{ .types = &.{full.record.type}, .type_view = true },
        }),
        .title = std.fmt.allocPrint(arena, "Version {d} of {s}", .{ seq, record_title }) catch {
            return error.OutOfMemory;
        },
        .versions_title = std.fmt.allocPrint(arena, "Versions of {s}", .{record_title}) catch {
            return error.OutOfMemory;
        },
        .versions_href = std.fmt.allocPrint(arena, "/admin/content/{s}/revisions", .{
            full.record.id,
        }) catch return error.OutOfMemory,
        .record_href = try record_href(arena, full.record.id),
        .kind = item.kind,
        .at = admin.time_text(arena, item.at),
        .by = item.by orelse "nobody",
        .fields = fields.items,
        .restore_action = std.fmt.allocPrint(arena, "/admin/content/{s}/restore", .{
            full.record.id,
        }) catch return error.OutOfMemory,
        .seq = std.fmt.allocPrint(arena, "{d}", .{seq}) catch return error.OutOfMemory,
        .expected_version = std.fmt.allocPrint(arena, "{d}", .{full.record.version}) catch {
            return error.OutOfMemory;
        },
    });
}

/// Restore = the snapshot's document written back through `record save`.
pub fn restore(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const id = try admin.param(session, "id", back) orelse return;

    const location = try record_href(session.arena, id);
    const seq = number_field(form, "seq") orelse {
        return admin.fail(session, error.Invalid, location);
    };
    const expected = number_field(form, "expected_version") orelse {
        return admin.fail(session, error.Invalid, location);
    };
    _ = registry.SDK.dispatch(&session.ctx, snapshots.Restore, .{
        .id = id,
        .seq = seq,
        .expected_version = expected,
    }) catch |err| return admin.fail(session, err, location);

    try response.redirect(.see_other, location);
}

fn record_href(arena: std.mem.Allocator, id: []const u8) Error![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(back.len > 0);

    return std.fmt.allocPrint(arena, "/admin/content/{s}", .{id}) catch error.OutOfMemory;
}

fn seq_param(session: *const Session) ?i64 {
    std.debug.assert(session.request.path().len > 0);
    std.debug.assert(session.ctx.now_ms > 0);

    const text = session.request.param("seq") orelse return null;

    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn number_field(form: *const Form, name: []const u8) ?i64 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    const text = form.text(name) orelse return null;

    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn title_of(arena: std.mem.Allocator, document: []const u8, title_field: []const u8) []const u8 {
    std.debug.assert(title_field.len > 0);
    std.debug.assert(json_bytes_max > 0);

    const parsed = @import("../../lib/json.zig").parse(std.json.Value, arena, document, .{}) catch {
        return "";
    };

    if (parsed != .object) {
        return "";
    }

    const title = parsed.object.get(title_field) orelse return "";

    return if (title == .string) title.string else "";
}

fn snapshot_object(arena: std.mem.Allocator, text: []const u8) error{Invalid}!std.json.ObjectMap {
    std.debug.assert(json.depth_max > 0);
    const document = json.parse(std.json.Value, arena, text, .{}) catch return error.Invalid;

    if (document != .object) {
        return error.Invalid;
    }

    return document.object;
}
