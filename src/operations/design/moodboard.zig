const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/design/moodboard.zig");
const registry = @import("../../server/registry.zig");
const record = @import("../record.zig");
const model_app = @import("../../model/app.zig");
const design = @import("../../model/design.zig");
const json = @import("../../lib/json.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// The cards one board holds: one page of records.
pub const items_max: u32 = record.list_max;

pub const Item = public.Item;

pub const Moodboard = struct {
    pub const shape = public.Moodboard;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        if (!model_app.valid_name(in.app)) {
            return error.Invalid;
        }

        const saved = try board(ctx, in.app);
        const items = try ctx.arena.alloc(Item, saved.len);

        for (saved, items) |card, *out| {
            out.* = card.item;
        }

        std.debug.assert(items.len <= items_max);

        return .{
            .items = items,
        };
    }
};

pub const SaveMoodboard = struct {
    pub const shape = public.SaveMoodboard;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!model_app.valid_name(in.app) or in.items.len > items_max) {
            return error.Invalid;
        }

        for (in.items) |item| {
            try check(item);
        }

        const saved = try board(ctx, in.app);
        const kept = try ctx.arena.alloc(bool, saved.len);
        const items = try ctx.arena.alloc(Item, in.items.len);

        @memset(kept, false);

        for (in.items, items) |item, *out| {
            out.* = item;
            out.id = try keep(ctx, in.app, item, saved, kept);
        }

        for (saved, kept) |card, was_kept| {
            if (!was_kept) {
                _ = try registry.SDK.dispatch(ctx, record.Delete, .{
                    .id = card.item.id,
                });
            }
        }

        return .{
            .items = items,
        };
    }
};

fn check(item: Item) Error!void {
    std.debug.assert(design.moodboard_kinds.len > 0);

    const known = for (design.moodboard_kinds) |known_kind| {
        if (std.mem.eql(u8, known_kind, item.kind)) {
            break true;
        }
    } else false;
    const placed = std.math.isFinite(item.across) and std.math.isFinite(item.down) and
        std.math.isFinite(item.width) and
        (item.height == null or std.math.isFinite(item.height.?));
    const weighed = (item.weight == null or std.math.isFinite(item.weight.?)) and
        (item.weight_max == null or std.math.isFinite(item.weight_max.?));

    if (!known or !placed or !weighed or item.id.len > 64) {
        return error.Invalid;
    }
}

/// The card written where it belongs: into its own record when it has one the board
/// still holds (and it changed), else into a new record of the app. Its record's id.
fn keep(
    ctx: *Ctx,
    app: []const u8,
    item: Item,
    saved: []const Card,
    kept: []bool,
) Error![]const u8 {
    std.debug.assert(saved.len == kept.len);
    std.debug.assert(app.len > 0);

    const document = try document_of(ctx.arena, item);

    for (saved, kept) |card, *was_kept| {
        if (was_kept.* or !std.mem.eql(u8, card.item.id, item.id)) {
            continue;
        }

        was_kept.* = true;

        if (!std.mem.eql(u8, try document_of(ctx.arena, card.item), document)) {
            _ = try registry.SDK.dispatch(ctx, record.Save, .{
                .id = card.item.id,
                .document = .{
                    .text = document,
                },
            });
        }

        return card.item.id;
    }

    const created = try registry.SDK.dispatch(ctx, record.Create, .{
        .type = design.moodboard_handle,
        .document = .{
            .text = document,
        },
        .app = app,
    });

    return created.id;
}

/// What a card's record holds: its fields, none for what the card leaves out.
fn document_of(arena: std.mem.Allocator, item: Item) Error![]const u8 {
    std.debug.assert(item.kind.len > 0);

    var fields = item;

    fields.id = "";

    const text = std.json.Stringify.valueAlloc(arena, fields, .{}) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(std.mem.startsWith(u8, text, "{\"kind\":"));

    return text;
}

const Card = struct {
    item: Item,
};

/// The app's moodboard records not in the trash, in the order they were made.
fn board(ctx: *Ctx, app: []const u8) Error![]const Card {
    std.debug.assert(app.len > 0);

    const arena = ctx.arena;
    const app_clause = std.fmt.allocPrint(arena, "app:is:{s}", .{app}) catch {
        return error.OutOfMemory;
    };
    const filters = [_][]const u8{ "status:not:trashed", app_clause };
    const listed = try registry.SDK.dispatch(ctx, record.List, .{
        .type = design.moodboard_handle,
        .filters = &filters,
        .order = .created_desc,
        .limit = items_max,
        .documents = true,
        .purpose = .edit,
    });
    var cards: std.ArrayList(Card) = .empty;

    for (listed.records, listed.documents) |found, text| {
        const options: std.json.ParseOptions = .{
            .ignore_unknown_fields = true,
        };
        const read = json.parse(Item, arena, text.text, options) catch continue;
        var item = read;

        item.id = found.id;
        cards.append(arena, .{
            .item = item,
        }) catch return error.OutOfMemory;
    }

    // Cards made in one save share their moment; ids rise in the order they were made.
    std.mem.sort(Card, cards.items, {}, earlier);

    return cards.items;
}

fn earlier(_: void, left: Card, right: Card) bool {
    return std.mem.lessThan(u8, left.item.id, right.item.id);
}

test "a card's document holds its own fields and never its id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try document_of(arena, .{
        .id = "m_1",
        .kind = "color",
        .across = 1,
        .down = 2,
        .width = 120,
        .value = "#fff",
        .colors = &.{"#000"},
    });

    try std.testing.expect(std.mem.indexOf(u8, text, "m_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"note\"") == null);
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"kind\":\"color\""));
    try std.testing.expectError(error.Invalid, check(.{
        .kind = "poster",
    }));
    const lost: Item = .{
        .kind = "note",
        .across = std.math.nan(f64),
    };

    try std.testing.expectError(error.Invalid, check(lost));
    try check(.{
        .kind = "figma",
        .status = "pending",
    });
}
