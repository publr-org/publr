//! Titles as the admin shows them: each record's own (its id when it has none), then
//! whatever display hooks its type has (`sdk/display.zig`). Text, escaped where shown.

const std = @import("std");
const admin = @import("../admin.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const records = @import("../../operations/record.zig");

const Item = sdk.display_hooks.Item;
const Batch = sdk.display_hooks.Batch;
const Error = admin.Error;

pub const point = @import("../../operations/record/shown.zig").point;

/// One title per record, in order: `record.shown` asked only when a hook is on a type
/// the page holds, so a page with none costs nothing.
pub fn titles(ctx: *sdk.Ctx, found: []const records.Record) Error![]const []const u8 {
    std.debug.assert(found.len <= records.list_max);

    const shown = try ctx.arena.alloc([]const u8, found.len);

    for (found, shown) |record, *title| {
        title.* = if (record.title.len > 0) record.title else record.id;
    }

    if (found.len == 0 or !any_hooked(ctx, found)) {
        return shown;
    }

    const ids = try ctx.arena.alloc([]const u8, found.len);

    for (found, ids) |record, *id| {
        id.* = record.id;
    }

    const answered = registry.SDK.dispatch(ctx, records.Shown, .{ .ids = ids }) catch {
        return shown;
    };

    for (answered.titles) |title| {
        for (found, shown) |record, *kept| {
            if (std.mem.eql(u8, record.id, title.id)) {
                kept.* = title.title;
            }
        }
    }

    return shown;
}

fn any_hooked(ctx: *sdk.Ctx, found: []const records.Record) bool {
    std.debug.assert(found.len <= records.list_max);

    for (found) |record| {
        if (registry.SDK.displayed(ctx, point, record.type)) {
            return true;
        }
    }

    return false;
}

test "an installed display hook: one call per batch, text back, no writes while it runs" {
    const internal = @import("../../operations/internal.zig");
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var ctx = project.ctx(.system);
    const note = "{\"note\":\"hi\"}";
    const fields = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, note, .{});
    var items = [_]Item{
        .{ .id = "a", .value = "First", .fields = fields },
        .{ .id = "b", .value = "Second" },
    };
    var batch: Batch = .{ .items = &items };

    try std.testing.expect(registry.SDK.displayed(&ctx, point, "salutation"));
    try std.testing.expect(!registry.SDK.displayed(&ctx, point, "post"));
    try registry.SDK.display(&ctx, point, "salutation", &batch);

    try std.testing.expectEqualStrings("<script>x</script>First|hi|Denied ", items[0].value);
    try std.testing.expectEqualStrings("<script>x</script>Second||Denied ", items[1].value);
    try std.testing.expect(!ctx.reads_only);
}
