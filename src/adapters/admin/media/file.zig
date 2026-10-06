//! `/admin/media/:id`: one file, its form saved by a POST to the same address and deleted
//! by one to `/delete` under it.

const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const media = @import("../../../operations/media.zig");
const explorer = @import("explorer.zig");
const library = @import("../media.zig");

const views = admin.views;
const back = "/admin/media";
const tags_max: u32 = 64;

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const detail = registry.SDK.dispatch(&session.ctx, media.Get, .{ .id = id }) catch |err| {
        return admin.fail(&session, err, back);
    };
    const listed = registry.SDK.dispatch(&session.ctx, media.List, .{ .limit = 1 }) catch |err| {
        return admin.fail(&session, err, back);
    };
    const arena = session.arena;
    const sides = try library.sides_of(views.MediaFile, arena, .{}, listed);
    const item = detail.media;
    const image = std.mem.eql(u8, item.family, "image");
    var names: std.ArrayList([]const u8) = .empty;

    for (detail.tags) |tag| {
        try names.append(arena, tag.name);
    }

    try admin.screen(&session, .ok, views.MediaFile, .{
        .id = item.id,
        .title = item.title,
        .filename = item.filename,
        .facts = try explorer.facts_of(arena, item),
        .uploaded = admin.time_text(arena, item.created_at),
        .url = try std.fmt.allocPrint(arena, "/media/{s}", .{item.key}),
        .preview = if (image) try preview_of(arena, item) else "",
        .image = image,
        .shown = shown_of(item),
        .kind = try explorer.kind_of(arena, item.filename),
        .alt = detail.alt,
        .caption = detail.caption,
        .credit = detail.credit,
        .focal_x = @floatFromInt(detail.focal_x),
        .focal_y = @floatFromInt(detail.focal_y),
        .folder = detail.folder orelse "",
        .tags = try std.mem.join(arena, ", ", names.items),
        .restricted = item.private,
        .saved = admin.query_param(&session, "saved") != null,
        .folders = sides.folders,
        .tag_list = sides.tags,
        .periods = sides.periods,
        .years = sides.years,
        .months = sides.months,
        .all = @floatFromInt(listed.all),
        .unsorted = @floatFromInt(listed.unsorted),
    });
}

fn shown_of(item: media.Item) @FieldType(views.MediaFile.Props, "shown") {
    std.debug.assert(item.family.len > 0);

    if (std.mem.eql(u8, item.family, "video")) {
        return .video;
    }

    if (std.mem.eql(u8, item.family, "audio")) {
        return .audio;
    }

    return if (std.mem.eql(u8, item.family, "pdf")) .pdf else .other;
}

/// A copy wide enough for the page, the whole picture: no crop, so the focal point is
/// placed on the image as it is.
fn preview_of(arena: std.mem.Allocator, item: media.Item) admin.Error![]const u8 {
    std.debug.assert(item.key.len > 0);
    std.debug.assert(std.mem.eql(u8, item.family, "image"));

    const resized = std.mem.eql(u8, item.mime_type, "image/jpeg") or
        std.mem.eql(u8, item.mime_type, "image/png");

    if (!resized) {
        return std.fmt.allocPrint(arena, "/media/{s}", .{item.key});
    }

    return std.fmt.allocPrint(arena, "/media/{s}?w=1200", .{item.key});
}

pub fn save(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const form = &post.form;
    const id = try admin.param(session, "id", back) orelse return;
    const tags = try tags_of(session.arena, form.get("tags") orelse "");

    _ = registry.SDK.dispatch(&session.ctx, media.Update, .{
        .id = id,
        .title = form.get("title") orelse "",
        .alt = form.get("alt") orelse "",
        .caption = form.get("caption") orelse "",
        .credit = form.get("credit") orelse "",
        .focal_x = percent_of(form.get("focal_x")),
        .focal_y = percent_of(form.get("focal_y")),
        .folder = form.get("folder") orelse "",
        .tags = tags,
        .private = form.get("private") != null,
    }) catch |err| return admin.fail(session, err, back);

    try response.redirect(.see_other, try std.fmt.allocPrint(
        session.arena,
        "/admin/media/{s}?saved=1",
        .{id},
    ));
}

fn percent_of(text: ?[]const u8) ?u8 {
    std.debug.assert(text == null or text.?.len <= 64 << 10);

    const given = text orelse return null;
    const value = std.fmt.parseInt(u8, given, 10) catch return null;

    return if (value <= 100) value else null;
}

/// `harbour, boats ,` is `harbour` and `boats`.
fn tags_of(arena: std.mem.Allocator, text: []const u8) admin.Error![]const []const u8 {
    std.debug.assert(text.len <= 64 << 10);
    std.debug.assert(tags_max > 0);

    var names: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');

    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");

        if (name.len > 0 and names.items.len < tags_max) {
            try names.append(arena, name);
        }
    }

    return names.items;
}

pub fn remove(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, media.Delete, .{ .ids = &.{id} }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back);
}

test "tags_of: comma-separated names, trimmed, empties dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const names = try tags_of(arena_state.allocator(), " harbour, boats ,, ");

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("boats", names[1]);
}

test "percent_of: 0 to 100 or nothing" {
    try std.testing.expectEqual(@as(?u8, 30), percent_of("30"));
    try std.testing.expectEqual(@as(?u8, null), percent_of("130"));
    try std.testing.expectEqual(@as(?u8, null), percent_of(null));
}
