//! `.register_columns`: a column on a list the plugin doesn't own,
//! `.{ .list = "users", .field = "loyalty.points", .label = "Points", .kind = .number }`. The
//! field is the plugin's own: one it stores on the type (its `.register_fields` group), read
//! with the list and sortable, or one an `after` hook on the list's read adds to each row
//! (`out.extend`). The admin draws it in the host's cell style by `.kind`.
const std = @import("std");
const record_define = @import("record_define.zig");

pub const Kind = enum { number, money, date, text, status, link };

pub const Column = struct {
    plugin: []const u8,
    /// The list it sits on: a type's (`orders.order`), `users`, `media`, or a pattern
    /// (`orders.*`).
    list: []const u8,
    /// The row's field, under the plugin's name: `loyalty.points`.
    field: []const u8,
    label: []const u8,
    kind: Kind,
    /// A field the plugin stores on the type: read with the list, and the list sorts on it.
    stored: bool,

    /// Whether the column sits on the list `name`.
    pub fn on(column: Column, name: []const u8) bool {
        std.debug.assert(column.list.len > 0);
        std.debug.assert(name.len > 0);

        return @import("../mods.zig").matches(column.list, name);
    }
};

pub const columns_max: u32 = 64;

/// The plugin's columns, each checked to name a field under the plugin.
pub fn columns_of(comptime Plugin: type) []const Column {
    comptime {
        const plugin = Plugin.manifest.name;
        var list: []const Column = &.{};

        std.debug.assert(plugin.len > 0);

        // A plugin made by hand (tests) carries no `define` options.
        const given_any = @hasDecl(Plugin, "options") and
            @hasField(@TypeOf(Plugin.options), "register_columns");

        if (!given_any) {
            return list;
        }

        for (Plugin.options.register_columns) |given| {
            const field: []const u8 = given.field;
            const name: []const u8 = given.list;
            const label: []const u8 = given.label;
            const own = std.mem.startsWith(u8, field, plugin ++ ".") and
                field.len > plugin.len + 1;

            if (!own) {
                @compileError("plugin " ++ plugin ++ ": a column's field is the plugin's own, " ++
                    "`" ++ plugin ++ ".<field>`: " ++ field);
            }

            if (name.len == 0 or label.len == 0) {
                @compileError("plugin " ++ plugin ++ ": a column names its `.list` and `.label`");
            }

            list = list ++ [_]Column{.{
                .plugin = plugin,
                .list = name,
                .field = field,
                .label = label,
                .kind = given.kind,
                .stored = stored(Plugin, field),
            }};
        }

        if (list.len > columns_max) {
            @compileError("plugin " ++ plugin ++ ": too many columns");
        }

        const done = list;

        return done;
    }
}

/// Whether `field` is one of the plugin's `.register_fields` groups' (`<group>.<field>`).
fn stored(comptime Plugin: type, comptime field: []const u8) bool {
    comptime {
        std.debug.assert(field.len > 0);

        if (!@hasField(@TypeOf(Plugin.options), "register_fields")) {
            return false;
        }

        for (record_define.field_groups_of(Plugin)) |group| {
            for (group.fields) |def| {
                if (std.mem.eql(u8, field, group.handle ++ "." ++ def.name)) {
                    return true;
                }
            }
        }

        return false;
    }
}

test "a column sits on its list, or on every list its pattern names" {
    const column: Column = .{
        .plugin = "loyalty",
        .list = "orders.*",
        .field = "loyalty.points",
        .label = "Points",
        .kind = .number,
        .stored = false,
    };

    try std.testing.expect(column.on("orders.order"));
    try std.testing.expect(!column.on("users"));
}
