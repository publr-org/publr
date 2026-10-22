//! `record.shown`: records' titles as people see them, applied as `<type>.title` for plugins
//! to modify (`sdk/mods.zig`). What is stored and what `record.list` answers stay as they are.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const mods = sdk.mods;
const list_max = store.records.list_max;

/// The name a type's titles are applied under: `variant.title`.
pub fn title_name(arena: std.mem.Allocator, type_name: []const u8) Error![]const u8 {
    std.debug.assert(type_name.len > 0);

    return std.fmt.allocPrint(arena, "{s}.title", .{type_name}) catch error.OutOfMemory;
}

pub const Purpose = @import("../document/crud.zig").Purpose;

/// The title a modifier answered, when it answered one.
fn title_of(item: std.json.Value) ?[]const u8 {
    if (item != .object) {
        return null;
    }

    const title = item.object.get("title") orelse return null;

    std.debug.assert(item.object.count() > 0);

    return if (title == .string) title.string else null;
}

pub const Title = struct {
    id: []const u8,
    title: []const u8,
};

pub fn Shown(comptime List: type, comptime example_id: []const u8) type {
    return struct {
        pub const name = "record.shown";
        pub const description = "The titles of records as people see them, modifiers applied";
        pub const details =
            \\Each record's title (its id when it has none), applied as `<type>.title` for
            \\plugins to modify (`publr.modify("variant.title", …)`): what the admin's lists,
            \\picker and reference cards show. Modifiers run once per type, read what their
            \\plugins are granted and never write; what they answer is text. Records the
            \\caller may not read are left out. Give `ids`, or a `type` for its newest.
            \\Stored values and `record list` are never changed.
        ;
        pub const kind: sdk.operation.Kind = .read;
        pub const In = struct {
            ids: []const []const u8 = &.{},
            type: ?[]const u8 = null,
            limit: u32 = 50,
            /// `edit`: from the pending copy of a record with changes, as its editor sees it.
            purpose: Purpose = .delivery,
        };
        pub const Out = struct {
            titles: []const Title,
        };
        pub const example: In = .{
            .ids = &.{example_id},
        };
        pub const example_out: Out = .{
            .titles = &.{
                .{
                    .id = example_id,
                    .title = "Hello, world",
                },
            },
        };
        pub const field_docs: sdk.operation.Docs(In) = .{
            .ids = "These records, up to 200",
            .type = "Or a type's records, newest first",
            .limit = "With `type`: how many, up to 200",
            .purpose = "`delivery` (default) or `edit`: pending copies where there are changes",
        };
        pub const output_docs: sdk.operation.Docs(Out) = .{
            .titles = "Each readable record's id and the title shown for it",
        };

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());

            const by_ids = in.ids.len > 0;

            if (by_ids == (in.type != null) or in.ids.len > list_max or in.limit > list_max) {
                return error.Invalid;
            }

            const listed = try registry.SDK.dispatch(ctx, List, .{
                .ids = in.ids,
                .type = in.type,
                .documents = true,
                .expand = false,
                .purpose = in.purpose,
                .limit = if (by_ids) @intCast(in.ids.len) else in.limit,
            });
            const titles = try ctx.arena.alloc(Title, listed.records.len);

            for (listed.records, titles) |record, *title| {
                title.* = .{
                    .id = record.id,
                    .title = if (record.title.len > 0) record.title else record.id,
                };
            }

            try apply_hooks(ctx, listed.records, listed.documents, titles);

            return .{
                .titles = titles,
            };
        }
    };
}

/// The hooks of each type on the page, once per type, over that type's records.
fn apply_hooks(
    ctx: *Ctx,
    records: []const store.records.Record,
    documents: []const []const u8,
    titles: []Title,
) Error!void {
    std.debug.assert(records.len == titles.len);
    std.debug.assert(documents.len == records.len);

    var done: std.StringHashMapUnmanaged(void) = .empty;

    for (records) |record| {
        const name = try title_name(ctx.arena, record.type);

        if (done.contains(record.type) or !registry.SDK.modified(ctx, name)) {
            continue;
        }

        done.put(ctx.arena, record.type, {}) catch return error.OutOfMemory;
        try apply_type(ctx, record.type, records, documents, titles);
    }
}

fn apply_type(
    ctx: *Ctx,
    type_name: []const u8,
    records: []const store.records.Record,
    documents: []const []const u8,
    titles: []Title,
) Error!void {
    std.debug.assert(type_name.len > 0);
    std.debug.assert(records.len == titles.len);

    const arena = ctx.arena;
    var items: std.ArrayList(std.json.Value) = .empty;
    var positions: std.ArrayList(u32) = .empty;

    for (records, documents, 0..) |record, document, index| {
        if (!std.mem.eql(u8, record.type, type_name)) {
            continue;
        }

        const fields = std.json.parseFromSliceLeaky(std.json.Value, arena, document, .{
            .allocate = .alloc_always,
        }) catch std.json.Value.null;

        var item: std.json.ObjectMap = .empty;

        item.put(arena, "id", .{
            .string = record.id,
        }) catch return error.OutOfMemory;
        item.put(arena, "title", .{
            .string = titles[index].title,
        }) catch return error.OutOfMemory;
        item.put(arena, "record", fields) catch return error.OutOfMemory;
        items.append(arena, .{
            .object = item,
        }) catch return error.OutOfMemory;
        positions.append(arena, @intCast(index)) catch return error.OutOfMemory;
    }

    var batch: mods.Batch = .{
        .items = items.items,
    };

    try registry.SDK.modify(ctx, try title_name(arena, type_name), &batch);

    for (batch.items, positions.items) |item, position| {
        titles[position].title = try mods.cleaned(arena, title_of(item) orelse continue);
    }
}
