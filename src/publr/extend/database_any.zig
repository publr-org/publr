//! A column read as whatever it holds (`publr.Host.Any`), and the row shape core reads it in.
const std = @import("std");
const db = @import("../../lib/db.zig");

/// A column's value as SQLite holds it, for a column of no one type (a pragma's `dflt_value`,
/// a generic copy of rows): `switch (value) { .integer => |number| …, .text => |text| … }`.
pub const Any = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

/// `Row` with every `Any` field as core's own, which the database reads.
pub fn CoreRow(comptime Row: type) type {
    comptime {
        const names = std.meta.fieldNames(Row);
        var types: [names.len]type = undefined;

        std.debug.assert(names.len > 0);

        for (names, &types) |name, *field_type| {
            field_type.* = core_of(@FieldType(Row, name));
        }

        const done_types = types;

        return @Struct(.auto, null, names, &done_types, &@splat(.{}));
    }
}

fn core_of(comptime Field: type) type {
    if (Field == Any) {
        return db.Any;
    }

    return Field;
}

/// The row core read, with each of its `Any` fields as the public one.
pub fn row_of(comptime Row: type, read: CoreRow(Row)) Row {
    comptime std.debug.assert(holds_any(Row));

    var row: Row = undefined;

    inline for (comptime std.meta.fieldNames(Row)) |name| {
        const Field = @FieldType(Row, name);
        const value = @field(read, name);

        @field(row, name) = if (Field == Any) any_of(value) else value;
    }

    return row;
}

fn any_of(value: db.Any) Any {
    std.debug.assert(value != .text or value.text.len < 1 << 31);

    return switch (value) {
        .null => .null,
        .integer => |number| .{
            .integer = number,
        },
        .real => |number| .{
            .real = number,
        },
        .text => |text| .{
            .text = text,
        },
        .blob => |bytes| .{
            .blob = bytes,
        },
    };
}

/// Whether `Row` has a field read as `Any`.
pub fn holds_any(comptime Row: type) bool {
    comptime {
        std.debug.assert(std.meta.fieldNames(Row).len > 0);

        for (std.meta.fieldNames(Row)) |name| {
            const Field = @FieldType(Row, name);

            if (Field == Any) {
                return true;
            }
        }

        return false;
    }
}
