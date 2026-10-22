//! What a query's hints ask of a read: the types, ids and field value they name.

const std = @import("std");
const records = @import("../../record.zig");
const groq = @import("../../../lib/groq.zig");

const Value = groq.Value;

pub fn hint_values(hints: []const groq.Hint, attribute: []const u8) ?[]const Value {
    std.debug.assert(attribute.len > 0);

    for (hints) |hint| {
        if (std.mem.eql(u8, hint.attribute, attribute)) {
            return hint.values;
        }
    }

    return null;
}

pub fn holds_string(values: []const Value, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);

    for (values) |held| {
        if (held == .string and std.mem.eql(u8, held.string, wanted)) {
            return true;
        }
    }

    return false;
}

pub fn id_list(
    arena: std.mem.Allocator,
    hints: []const groq.Hint,
) error{OutOfMemory}!?[]const []const u8 {
    const values = hint_values(hints, "_id") orelse return null;
    var ids: std.ArrayList([]const u8) = .empty;

    for (values) |held| {
        if (held == .string and held.string.len <= 64) {
            try ids.append(arena, held.string);
        }
    }

    if (ids.items.len == 0 or ids.items.len > records.list_max) {
        return null;
    }

    return ids.items;
}

/// The first hint on one of the record's own fields with a single value.
pub fn field_hint(hints: []const groq.Hint) ?groq.Hint {
    std.debug.assert(hints.len <= 64);

    for (hints) |hint| {
        // A record's `status` is its own column, not one of its fields: the keep finds it.
        const own = hint.attribute.len > 0 and hint.attribute[0] != '_' and
            !std.mem.eql(u8, hint.attribute, "status");

        if (own and hint.values.len == 1) {
            return hint;
        }
    }

    return null;
}

/// A value as `filter_value` takes it: text as it is, numbers and booleans written out.
pub fn text_of(arena: std.mem.Allocator, value: Value) ![]const u8 {
    std.debug.assert(value != .number or std.math.isFinite(value.number));

    return switch (value) {
        .string => |text| text,
        .boolean => |truth| if (truth) "true" else "false",
        .number => |number| blk: {
            var out: std.Io.Writer.Allocating = .init(arena);

            groq.values.write_number(&out.writer, number) catch return error.OutOfMemory;

            break :blk out.written();
        },
        else => error.OutOfMemory,
    };
}
