//! `record.markers`: the markers beside each field's label in the editor, worked out from the
//! document as it stands (saved or not), applied as `<type>.markers` for plugins to modify:
//! the languages plugin says a field is translated, an A/B test that it varies. Nothing is
//! stored; the editor asks again as its values change.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const site_dimensions = @import("../dimensions.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const mods = sdk.mods;
const Value = std.json.Value;

/// One marker beside one field's label.
pub const Marker = struct {
    field: []const u8,
    label: []const u8,
    /// What the markers of its dimension are of, drawn once before them: `Hero test`.
    group: []const u8 = "",
    /// `outline` (the default), `neutral`, `success` or `danger`.
    tone: []const u8 = "outline",
    /// What clicking it shows: the field in this dimension (empty: no link) at `code`.
    dimension: []const u8 = "",
    code: []const u8 = "",
    /// `show`, or `hide` while the editor shows the field at this code.
    current: []const u8 = "show",
};

pub const markers_max: u32 = 256;

/// The name a type's markers are applied under: `promo.markers`.
pub fn markers_name(arena: std.mem.Allocator, type_name: []const u8) Error![]const u8 {
    std.debug.assert(type_name.len > 0);

    return std.fmt.allocPrint(arena, "{s}.markers", .{type_name}) catch error.OutOfMemory;
}

pub fn Markers(comptime Domain: type) type {
    return struct {
        pub const name = "record.markers";
        pub const description = "The markers beside each field's label, for a document as is";
        pub const details =
            \\Any signed-in account. One item per field of `type`, applied as `<type>.markers`
            \\for plugins to modify (`publr.modify("*.markers", …)`): each item has the
            \\`field`, the dimensions it `varies_by`, the whole `record` and the `markers` so
            \\far, and a modifier adds its own (`Translated`, `Varies in B`). Modifiers read
            \\only. The document is the editor's, saved or not; nothing is stored.
        ;
        pub const kind: sdk.operation.Kind = .read;
        pub const open = true;
        pub const In = struct {
            type: []const u8,
            document: []const u8,
        };
        pub const Out = struct {
            markers: []const Marker,
        };
        pub const example_signed_in = true;
        pub const example: In = .{
            .type = "post",
            .document = "{\"title\":\"Hello\"}",
        };
        pub const example_out: Out = .{
            .markers = &.{},
        };
        pub const field_docs: sdk.operation.Docs(In) = .{
            .type = "The record's type",
            .document = "Its fields as JSON, as the editor holds them",
        };
        pub const output_docs: sdk.operation.Docs(Out) = .{
            .markers = "Each marker: the `field`, its `label` and `tone`",
        };

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

            const record = @import("../../lib/json.zig").parse(Value, ctx.arena, in.document, .{
                .allocate = .alloc_always,
            }) catch return error.Invalid;
            var batch: mods.Batch = .{
                .items = try items_of(ctx, row.def, record),
            };

            try registry.SDK.modify(ctx, marked, &batch);

            return .{
                .markers = try collected(ctx.arena, batch.items),
            };
        }
    };
}

/// One item per field: `{ field, varies_by, required, record, markers: [] }`, `required`
/// each value it must hold before going live (`{ dimension, code }`).
fn items_of(
    ctx: *Ctx,
    type_def: @import("../../model.zig").content_type.Def,
    record: Value,
) Error![]Value {
    std.debug.assert(type_def.fields.len <= @import("../../model.zig").field.fields_max);

    const arena = ctx.arena;
    const fields = type_def.fields;
    const items = arena.alloc(Value, fields.len) catch return error.OutOfMemory;

    for (fields, items) |def, *item| {
        var object: std.json.ObjectMap = .empty;
        var varies_by = std.json.Array.init(arena);
        var required = std.json.Array.init(arena);

        for (try site_dimensions.required_of(ctx, type_def, def)) |one| {
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
            }) catch return error.OutOfMemory;
        }
    }

    return out.items;
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
