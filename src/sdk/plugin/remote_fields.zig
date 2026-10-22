//! A remote record's fields as the plugin reads them: `publr.remote.record(name, Fields)`
//! lists only what it uses, each field's Zig type saying which kinds it can read. Checked
//! against the other plugin's declared fields (`plugin_contracts.holds_kind`); an internal
//! record's own fields get their kinds here too.
const std = @import("std");
const plugin_contracts = @import("../../model/plugin_contracts.zig");
const words = @import("words.zig");

const Holds = plugin_contracts.Holds;
const UsedField = plugin_contracts.UsedField;
const ProvidedField = plugin_contracts.ProvidedField;

/// Every field of `Fields` with the kinds it reads.
pub fn of(comptime record_name: []const u8, comptime Fields: type) []const UsedField {
    comptime {
        const info = @typeInfo(Fields).@"struct";

        if (info.fields.len > plugin_contracts.fields_max) {
            @compileError("remote record " ++ record_name ++ " lists more than 64 fields");
        }

        var list: [info.fields.len]UsedField = undefined;

        for (info.fields, &list) |field, *used| {
            used.* = .{
                .name = field.name,
                .holds = holds_of(record_name, field.name, field.type),
            };
        }

        const done = list;

        return &done;
    }
}

/// The kinds a Zig type reads: text any text kind or a reference's id, a list several values,
/// money's JSON map money, `std.json.Value` anything.
fn holds_of(
    comptime record_name: []const u8,
    comptime name: []const u8,
    comptime Type: type,
) Holds {
    comptime {
        const Plain = if (@typeInfo(Type) == .optional) @typeInfo(Type).optional.child else Type;

        if (Plain == []const u8) {
            return .text;
        }

        if (Plain == bool) {
            return .boolean;
        }

        if (Plain == words.Time) {
            return .datetime;
        }

        if (Plain == std.json.ArrayHashMap(i64)) {
            return .money;
        }

        if (Plain == std.json.Value) {
            return .any;
        }

        if (is_reference(Plain)) {
            return .reference;
        }

        const info = @typeInfo(Plain);

        if (info == .pointer and info.pointer.size == .slice) {
            const Item = info.pointer.child;

            if (Item == []const u8) {
                return .texts;
            }

            if (is_reference(Item)) {
                return .references;
            }
        }

        return switch (info) {
            .int => .integer,
            .float => .number,
            .@"enum" => .choice,
            else => @compileError("remote record " ++ record_name ++ ": field `" ++ name ++
                "` is " ++ @typeName(Type) ++ ", which reads no field kind; use text, a number, " ++
                "bool, publr.Time, a reference, a list of these, or std.json.Value"),
        };
    }
}

fn is_reference(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "reference");
}

/// An internal record's fields, each with the kind its Zig type keeps: what another plugin's
/// remote record on it is checked against, by the same rules as a content record's.
pub fn declared_of(
    comptime record_name: []const u8,
    comptime Document: type,
) []const ProvidedField {
    comptime {
        const info = @typeInfo(Document).@"struct";

        if (info.fields.len > plugin_contracts.fields_max) {
            @compileError("record " ++ record_name ++ " has more than 64 fields");
        }

        var list: [info.fields.len]ProvidedField = undefined;

        for (info.fields, &list) |field, *declared| {
            const Plain = if (@typeInfo(field.type) == .optional)
                @typeInfo(field.type).optional.child
            else
                field.type;
            const many = is_list(Plain);

            declared.* = .{
                .name = field.name,
                .kind = kind_of(if (many) std.meta.Elem(Plain) else Plain),
                .many = many,
            };
        }

        const done = list;

        return &done;
    }
}

/// The kind a value of `Type` is kept as: text `string`, whole numbers `integer`, a choice
/// `select`; a struct of its own fields (or anything else) `group`.
fn kind_of(comptime Type: type) []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Type) != .optional);

        const plain = [_]struct {
            type,
            []const u8,
        }{
            .{ []const u8, "string" },
            .{ bool, "boolean" },
            .{ words.Time, "datetime" },
            .{ std.json.ArrayHashMap(i64), "money" },
        };

        for (plain) |pair| {
            if (Type == pair[0]) {
                return pair[1];
            }
        }

        if (is_reference(Type)) {
            return "reference";
        }

        return switch (@typeInfo(Type)) {
            .int => "integer",
            .float => "number",
            .@"enum" => "select",
            else => "group",
        };
    }
}

/// A list of values (several of a kind), never text.
fn is_list(comptime Type: type) bool {
    const info = @typeInfo(Type);

    return info == .pointer and info.pointer.size == .slice and info.pointer.child != u8;
}

test "an internal record's fields keep the kinds their types say" {
    const Stock = struct {
        variant: []const u8,
        on_hand: u32,
        open: bool = true,
        note: ?[]const u8 = null,
        tags: []const []const u8 = &.{},
        price: std.json.ArrayHashMap(i64),
        extra: struct {
            depth: u32,
        },
    };
    const declared = comptime declared_of("inventory.stock", Stock);

    try std.testing.expectEqual(@as(usize, 7), declared.len);
    try std.testing.expectEqualStrings("string", declared[0].kind);
    try std.testing.expectEqualStrings("integer", declared[1].kind);
    try std.testing.expectEqualStrings("boolean", declared[2].kind);
    try std.testing.expectEqualStrings("string", declared[3].kind);
    try std.testing.expect(!declared[3].many);
    try std.testing.expect(declared[4].many);
    try std.testing.expectEqualStrings("money", declared[5].kind);
    try std.testing.expectEqualStrings("group", declared[6].kind);
}

test "a remote record's fields read the kinds their types hold" {
    const Fields = struct {
        title: []const u8,
        sku: ?[]const u8 = null,
        stock: u32,
        price: std.json.ArrayHashMap(i64),
        images: []const []const u8,
        extra: std.json.Value,
    };
    const used = comptime of("products.variant", Fields);

    try std.testing.expectEqual(@as(usize, 6), used.len);
    try std.testing.expectEqual(Holds.text, used[1].holds);
    try std.testing.expectEqual(Holds.integer, used[2].holds);
    try std.testing.expectEqual(Holds.money, used[3].holds);
    try std.testing.expectEqual(Holds.texts, used[4].holds);
    try std.testing.expectEqual(Holds.any, used[5].holds);
}
