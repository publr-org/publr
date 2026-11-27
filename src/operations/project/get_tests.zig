const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const record = @import("../record.zig");
const Get = @import("get.zig").Get;
const Put = @import("put.zig").Put;

const SDK = registry.SDK;
const stored_rows = store.stored_rows;

fn get_one(ctx: *sdk.Ctx, kind: []const u8, id: []const u8) !Get.Out {
    std.debug.assert(id.len > 0);

    return SDK.dispatch(ctx, Get, .{
        .kind = kind,
        .ids = &.{id},
    });
}

test "project.get reads a unit's rows as project.put takes them: plugins and admins only" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record.fixture.post_type(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    const created = try SDK.dispatch(&admin, record.Create, .{
        .type = "post",
        .document = .{
            .text = "{\"title\":\"Hello\",\"body\":\"x\"}",
        },
    });
    const read = try get_one(&admin, "record", created.id);
    const shape = stored_rows.shape_of(.record);
    const stored = try stored_rows.read(admin.db, admin.arena, shape, created.id);

    try std.testing.expectEqual(@as(usize, 1), read.units.len);
    try std.testing.expectEqualStrings(created.id, read.units[0].id);
    try std.testing.expectEqualStrings(stored, read.units[0].rows.text);
    try std.testing.expect(std.mem.indexOf(u8, stored, "record_search") == null);
    try std.testing.expectEqual(@as(usize, 0), read.every.len);
    try std.testing.expectError(error.Denied, get_one(&editor, "record", created.id));
    try std.testing.expectError(error.Invalid, get_one(&admin, "media", created.id));
    const missing = try get_one(&admin, "record", "r_none");

    try std.testing.expectEqualStrings("{}", missing.units[0].rows.text);

    const put = try SDK.dispatch(&admin, Put, .{
        .units = &.{.{
            .kind = "record",
            .id = created.id,
            .rows = read.units[0].rows,
        }},
    });

    try std.testing.expectEqualStrings("unchanged", put.put[0].outcome);
}

test "project.get lists every unit of a kind in order, a type by its id with its handle" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record.fixture.post_type(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const types = try SDK.dispatch(&admin, Get, .{
        .kind = "content_type",
        .every = true,
    });
    var post_id: []const u8 = "";

    for (types.every) |listed| {
        if (std.mem.eql(u8, listed.handle, "post")) {
            post_id = listed.id;
        }
    }

    try std.testing.expect(post_id.len > 0);
    try std.testing.expectEqualStrings("", types.next);

    const post = try get_one(&admin, "content_type", post_id);

    try std.testing.expectEqualStrings("post", post.units[0].handle);
    try std.testing.expect(std.mem.indexOf(u8, post.units[0].rows.text, "field_groups") != null);

    const roles = try SDK.dispatch(&admin, Get, .{
        .kind = "role",
        .every = true,
    });

    try std.testing.expect(roles.every.len > 1);

    for (roles.every[1..], 0..) |listed, index| {
        try std.testing.expect(std.mem.order(u8, roles.every[index].id, listed.id) == .lt);
    }
}
