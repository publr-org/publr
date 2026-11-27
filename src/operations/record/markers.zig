//! `record.markers`: the markers beside each field's label in the editor, worked out from the
//! document as it stands (saved or not), applied as `<type>.markers` for plugins to modify:
//! the languages plugin says a field is translated, an A/B test that it varies. Nothing is
//! stored; the editor asks again as its values change.

const std = @import("std");
const public = @import("../../publr/operations/record/markers.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const site_dimensions = @import("../dimensions.zig");
const live = @import("../../model/dimension/live.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const mods = sdk.mods;
const Value = std.json.Value;

pub const Marker = public.Marker;

pub const markers_max: u32 = 200;

/// The name a type's markers are applied under: `promo.markers`.
pub fn markers_name(arena: std.mem.Allocator, type_name: []const u8) Error![]const u8 {
    std.debug.assert(type_name.len > 0);

    return std.fmt.allocPrint(arena, "{s}.markers", .{type_name}) catch error.OutOfMemory;
}

pub fn Markers(comptime Domain: type) type {
    return struct {
        pub const shape = public.Markers;
        pub const name = shape.name;
        pub const description = shape.description;
        pub const details = shape.details;
        pub const kind = shape.kind;
        pub const open = shape.open;
        pub const In = shape.In;
        pub const Out = shape.Out;
        pub const example_signed_in = shape.example_signed_in;
        pub const example = shape.example;
        pub const example_out = shape.example_out;
        pub const field_docs = shape.field_docs;
        pub const output_docs = shape.output_docs;

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());

            if (ctx.caller.user_id() == null) {
                return error.Denied;
            }

            const row = try Domain.definition.find(ctx, in.type) orelse return error.NotFound;
            const marked = try markers_name(ctx.arena, row.def.handle);

            if (!registry.SDK.modified(ctx, marked)) {
                return .{
                    .markers = &.{},
                };
            }

            const text = in.document.text;
            const record = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{
                .allocate = .alloc_always,
            }) catch return error.Invalid;
            const held_back = if (in.id.len == 0) "" else blk: {
                const found = try Domain.access.load(ctx, in.id, granted) orelse {
                    return error.NotFound;
                };

                break :blk found.pending_held_back orelse found.held_back;
            };
            var batch: mods.Batch = .{
                .items = try items_of(ctx, row.def, record, held_back, in.id),
            };

            try registry.SDK.modify(ctx, marked, &batch);

            return .{
                .markers = try collected(ctx.arena, batch.items),
            };
        }
    };
}

/// One item per field: `{ field, varies_by, required, type, id, record, markers: [] }`,
/// `required` each value it must hold before going live (`{ dimension, code }`), but in a
/// combination the record holds back (`held_back`); `id` empty before it is saved.
fn items_of(
    ctx: *Ctx,
    type_def: @import("../../model.zig").content_type.Def,
    record: Value,
    held_back: []const u8,
    id: []const u8,
) Error![]Value {
    std.debug.assert(type_def.fields.len <= @import("../../model.zig").field.fields_max);

    const arena = ctx.arena;
    const fields = type_def.fields;
    const items = arena.alloc(Value, fields.len) catch return error.OutOfMemory;

    for (fields, items) |def, *item| {
        var object: std.json.ObjectMap = .empty;
        var varies_by = std.json.Array.init(arena);
        var required = std.json.Array.init(arena);

        for (try site_dimensions.required_of(ctx, def)) |one| {
            var buffer: [live.combination_len_max + 2]u8 = undefined;
            const combination = live.combination_of(&buffer, &.{.{
                .dimension = one.dimension,
                .code = one.code,
            }}) orelse continue;

            if (live.held(held_back, combination)) {
                continue;
            }

            var pair: std.json.ObjectMap = .empty;

            pair.put(arena, "dimension", .{
                .string = one.dimension,
            }) catch return error.OutOfMemory;
            pair.put(arena, "code", .{
                .string = one.code,
            }) catch return error.OutOfMemory;
            required.append(.{
                .object = pair,
            }) catch return error.OutOfMemory;
        }

        for (def.dimensions) |dimension| {
            varies_by.append(.{
                .string = dimension,
            }) catch return error.OutOfMemory;
        }

        object.put(arena, "field", .{
            .string = def.name,
        }) catch return error.OutOfMemory;
        object.put(arena, "varies_by", .{
            .array = varies_by,
        }) catch return error.OutOfMemory;
        object.put(arena, "required", .{
            .array = required,
        }) catch return error.OutOfMemory;
        object.put(arena, "type", .{
            .string = type_def.handle,
        }) catch return error.OutOfMemory;
        object.put(arena, "id", .{
            .string = id,
        }) catch return error.OutOfMemory;
        object.put(arena, "record", record) catch return error.OutOfMemory;
        object.put(arena, "markers", .{
            .array = std.json.Array.init(arena),
        }) catch return error.OutOfMemory;
        item.* = .{
            .object = object,
        };
    }

    return items;
}

/// Every marker the modifiers left, in field order, each label cleaned.
fn collected(arena: std.mem.Allocator, items: []const Value) Error![]const Marker {
    std.debug.assert(items.len <= mods.items_max);

    var out: std.ArrayList(Marker) = .empty;

    for (items) |item| {
        if (item != .object) {
            continue;
        }

        const field = item.object.get("field") orelse continue;
        const markers = item.object.get("markers") orelse continue;

        if (field != .string or markers != .array) {
            continue;
        }

        for (markers.array.items) |marker| {
            if (out.items.len == markers_max) {
                return out.items;
            }

            const label = text_of(marker, "label") orelse continue;

            out.append(arena, .{
                .field = field.string,
                .label = try mods.cleaned(arena, label),
                .group = try mods.cleaned(arena, text_of(marker, "group") orelse ""),
                .tone = tone_of(text_of(marker, "tone") orelse ""),
                .dimension = text_of(marker, "dimension") orelse "",
                .code = text_of(marker, "code") orelse "",
                .current = if (std.mem.eql(u8, text_of(marker, "current") orelse "", "hide"))
                    "hide"
                else
                    "show",
                .href = href_of(text_of(marker, "href") orelse ""),
            }) catch return error.OutOfMemory;
        }
    }

    return out.items;
}

/// A marker's link when it is a page of the admin's own, else none.
fn href_of(href: []const u8) []const u8 {
    std.debug.assert(href.len <= 64 << 10);

    const admin = "/admin/";
    const own = std.mem.startsWith(u8, href, admin) and href.len < 2048;

    for (href) |char| {
        if (char < 0x20 or char == 0x7f or char == '\\') {
            return "";
        }
    }

    return if (own and !std.mem.startsWith(u8, href, admin ++ "/")) href else "";
}

fn text_of(value: Value, key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    if (value != .object) {
        return null;
    }

    const found = value.object.get(key) orelse return null;

    return if (found == .string and found.string.len > 0) found.string else null;
}

/// A tone the editor draws; anything else is `outline`.
fn tone_of(asked: []const u8) []const u8 {
    std.debug.assert(asked.len <= 64 << 10);

    const known = [_][]const u8{ "outline", "neutral", "success", "danger" };

    for (known) |tone| {
        if (std.mem.eql(u8, tone, asked)) {
            return tone;
        }
    }

    return "outline";
}
