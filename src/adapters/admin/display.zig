//! Titles as the admin shows them: each record's own (its id when it has none), then what
//! plugins modifying `<type>.title` make of it (`sdk/mods.zig`). Text, escaped where shown.

const std = @import("std");
const admin = @import("../admin.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const records = @import("../../operations/record.zig");

const shown_titles = @import("../../operations/record/shown.zig");
const Error = admin.Error;

/// One title per record, in order: `record.shown` asked only when a modifier takes a type
/// the page holds, so a page with none costs nothing.
pub fn titles(ctx: *sdk.Ctx, found: []const records.Record) Error![]const []const u8 {
    std.debug.assert(found.len <= records.list_max);

    const shown = try ctx.arena.alloc([]const u8, found.len);

    for (found, shown) |record, *title| {
        title.* = if (record.title.len > 0) record.title else record.id;
    }

    if (found.len == 0 or !try any_modified(ctx, found)) {
        return shown;
    }

    const ids = try ctx.arena.alloc([]const u8, found.len);

    for (found, ids) |record, *id| {
        id.* = record.id;
    }

    // The admin shows what its editors see: a moved draft or pending variant reads its new
    // product, not the one it is published with.
    const answered = registry.SDK.dispatch(ctx, records.Shown, .{
        .ids = ids,
        .purpose = .edit,
    }) catch {
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

fn any_modified(ctx: *sdk.Ctx, found: []const records.Record) Error!bool {
    std.debug.assert(found.len <= records.list_max);

    for (found) |record| {
        const name = shown_titles.title_name(ctx.arena, record.type) catch {
            return error.OutOfMemory;
        };

        if (registry.SDK.modified(ctx, name)) {
            return true;
        }
    }

    return false;
}

test "an installed modifier: its reads come for the batch, text back, no writes while it runs" {
    const internal = @import("../../operations/internal.zig");
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var ctx = project.ctx(.system);
    const note = "{\"note\":\"hi\"}";
    const empty = "{\"note\":\"\"}";
    const fields = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, note, .{});
    const stored = try registry.SDK.dispatch(&ctx, @import("../../operations/record.zig").Create, .{
        .type = "greeter.salutation",
        .document = note,
    });
    const blank = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, empty, .{});
    var items = [_]std.json.Value{
        try title_item(ctx.arena, stored.id, "First", fields),
        try title_item(ctx.arena, "b", "Second", blank),
    };
    var batch: sdk.mods.Batch = .{
        .items = &items,
    };

    try std.testing.expect(registry.SDK.modified(&ctx, "greeter.salutation.title"));
    try std.testing.expect(!registry.SDK.modified(&ctx, "post.title"));
    try registry.SDK.modify(&ctx, "greeter.salutation.title", &batch);

    const first = try sdk.mods.cleaned(ctx.arena, items[0].object.get("title").?.string);
    const second = try sdk.mods.cleaned(ctx.arena, items[1].object.get("title").?.string);

    try std.testing.expectEqualStrings("<script>x</script>First|hi|Denied ", first);
    try std.testing.expectEqualStrings("<script>x</script>Second|NotFound|Denied ", second);
    try std.testing.expect(!ctx.reads_only);
}

fn title_item(
    arena: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    fields: std.json.Value,
) !std.json.Value {
    var item: std.json.ObjectMap = .empty;

    try item.put(arena, "id", .{
        .string = id,
    });
    try item.put(arena, "title", .{
        .string = title,
    });
    try item.put(arena, "record", fields);

    return .{
        .object = item,
    };
}
