//! `record.help`: the help under each field of a record in the editor, applied as
//! `<type>.<field>.help` for plugins to modify from the document as it stands (saved or
//! not): help that follows the field's value, or other fields'. Nothing is stored; the
//! editor asks again as its values change.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const mods = sdk.mods;
const Value = std.json.Value;

/// One field's help as the modifiers left it.
pub const Help = struct {
    field: []const u8,
    help: []const u8,
};

/// The name a field's help is applied under: `promo.body.help`.
pub fn help_name(
    arena: std.mem.Allocator,
    type_name: []const u8,
    field: []const u8,
) Error![]const u8 {
    std.debug.assert(type_name.len > 0);
    std.debug.assert(field.len > 0);

    return std.fmt.allocPrint(arena, "{s}.{s}.help", .{ type_name, field }) catch {
        return error.OutOfMemory;
    };
}

pub fn Helps(comptime Domain: type) type {
    return struct {
        pub const name = "record.help";
        pub const description = "The help under each field, for a document as is";
        pub const details =
            \\Any signed-in account. The help of each top-level field of `type` that a
            \\plugin modifies, applied as `<type>.<field>.help` (`publr.modify("*.*.help",
            \\…)`): each takes the `field`, the whole `record` and the `help` so far, and
            \\answers the help to show. Modifiers read only. A field nobody modifies is left
            \\out: its help is the type's. The document is the editor's, saved or not.
        ;
        pub const kind: sdk.operation.Kind = .read;
        pub const open = true;
        pub const In = struct {
            type: []const u8,
            document: []const u8,
        };
        pub const Out = struct {
            helps: []const Help,
        };
        pub const example_signed_in = true;
        pub const example: In = .{
            .type = "post",
            .document = "{\"title\":\"Hello\"}",
        };
        pub const example_out: Out = .{
            .helps = &.{},
        };
        pub const field_docs: sdk.operation.Docs(In) = .{
            .type = "The record's type",
            .document = "Its fields as JSON, as the editor holds them",
        };
        pub const output_docs: sdk.operation.Docs(Out) = .{
            .helps = "Each modified field's `field` and the `help` to show",
        };

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());

            if (ctx.caller.user_id() == null) {
                return error.Denied;
            }

            const row = try Domain.definition.find(ctx, in.type) orelse return error.NotFound;
            const record = @import("../../lib/json.zig").parse(Value, ctx.arena, in.document, .{
                .allocate = .alloc_always,
            }) catch return error.Invalid;

            return .{
                .helps = try helps_of(ctx, row.def, record),
            };
        }
    };
}

/// Each modified top-level field's help as the modifiers left it, in field order.
pub fn helps_of(ctx: *Ctx, type_def: model.content_type.Def, record: Value) Error![]const Help {
    std.debug.assert(type_def.fields.len <= model.field.fields_max);

    const arena = ctx.arena;
    var out: std.ArrayList(Help) = .empty;

    for (type_def.fields) |def| {
        if (model.field.is_layout(def.kind)) {
            continue;
        }

        const named = try help_name(arena, type_def.handle, def.name);

        if (!mods.valid(named, false) or !registry.SDK.modified(ctx, named)) {
            continue;
        }

        var object: std.json.ObjectMap = .empty;

        object.put(arena, "field", .{
            .string = def.name,
        }) catch return error.OutOfMemory;
        object.put(arena, "record", record) catch return error.OutOfMemory;
        object.put(arena, "help", .{
            .string = def.help,
        }) catch return error.OutOfMemory;

        var items = [_]Value{.{
            .object = object,
        }};
        var batch: mods.Batch = .{
            .items = &items,
        };

        registry.SDK.modify(ctx, named, &batch) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };

        const help = help_in(items[0], def.name) orelse continue;
        const cut = cut_at(help, model.field.help_len_max);

        out.append(arena, .{
            .field = def.name,
            .help = try mods.cleaned(arena, cut),
        }) catch return error.OutOfMemory;
    }

    return out.items;
}

/// The help a modifier left in `item`, if it left one that reads as text.
fn help_in(item: Value, field: []const u8) ?[]const u8 {
    std.debug.assert(field.len > 0);

    if (item != .object) {
        return null;
    }

    const found = item.object.get("help") orelse return null;

    return if (found == .string) found.string else null;
}

/// `text` cut to at most `limit` bytes, never inside a character.
fn cut_at(text: []const u8, limit: u32) []const u8 {
    std.debug.assert(limit > 0);

    if (text.len <= limit) {
        return text;
    }

    var end: usize = limit;

    while (end > 0 and text[end] & 0xC0 == 0x80) {
        end -= 1;
    }

    return text[0..end];
}

test "a help is cut between characters" {
    try std.testing.expectEqualStrings("ab", cut_at("ab", 4));
    try std.testing.expectEqualStrings("a", cut_at("a\xc5\x82b", 2));
    try std.testing.expectEqualStrings("a\xc5\x82", cut_at("a\xc5\x82b", 3));
}
