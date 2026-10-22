//! A content record's place in the admin: `.menu = .{ .parent = &.{"checkout.orders"} }`, and
//! its default view, `.data_view = .{ .columns, .filters, .order }`, fields named from its
//! document and checked against their kinds, so a typo or a field that cannot filter or order
//! fails the build. Filters and order are where the list starts; people change them. Whether a
//! field filters or orders at all is the field's (`.fields.x = .{ .sortable = true }`).
const std = @import("std");
const listed_in = @import("define.zig").listed_in;
const content_type = @import("../../model/content_type.zig");
const field_model = @import("../../model/field.zig");
const field_filter = @import("../../model/field_filter.zig");
const filter = @import("../../model/filter.zig");
const kinds = @import("../../model/kinds.zig");
const view_model = @import("../../model/view.zig");

/// Columns of core's that a view may show besides the type's fields.
const core_columns = [_][]const u8{ "status", "updated", "created", "slug" };

pub fn menu_of(comptime Definition: type) content_type.Menu {
    comptime {
        const options = Definition.given;
        const name = Definition.type_name;

        std.debug.assert(name.len > 0);

        if (!@hasField(@TypeOf(options), "menu")) {
            return .{};
        }

        if (@TypeOf(options.menu) == @TypeOf(.enum_literal)) {
            if (options.menu != .none) {
                @compileError("record " ++ name ++ ": `.menu` is `.{ .parent, .icon }` or " ++
                    "`.none`");
            }

            return .{
                .hidden = true,
            };
        }

        if (!@hasField(@TypeOf(options.menu), "parent")) {
            return .{};
        }

        const parents: []const []const u8 = options.menu.parent;

        if (parents.len == 0 or parents.len > content_type.menu_parents_max) {
            @compileError("record " ++ name ++ ": `.menu.parent` lists 1 to 8 menu items");
        }

        for (parents) |parent| {
            if (std.mem.indexOfScalar(u8, parent, '.') == null) {
                @compileError("record " ++ name ++ ": a menu item is named " ++
                    "`<plugin>.<name>`, not `" ++ parent ++ "`");
            }
        }

        return .{
            .parents = parents,
        };
    }
}

/// The icon `.menu` gives, or null.
pub fn icon_of(comptime Definition: type) ?[]const u8 {
    comptime {
        const options = Definition.given;

        std.debug.assert(Definition.type_name.len > 0);

        if (!@hasField(@TypeOf(options), "menu")) {
            return null;
        }

        if (@TypeOf(options.menu) == @TypeOf(.enum_literal)) {
            return null;
        }

        if (@hasField(@TypeOf(options.menu), "icon")) {
            return options.menu.icon;
        }

        return null;
    }
}

pub fn view_of(
    comptime Definition: type,
    comptime status_id: anytype,
    comptime fields: []const field_model.Def,
) content_type.View {
    comptime {
        const options = Definition.given;
        const name = Definition.type_name;

        std.debug.assert(name.len > 0);

        if (!@hasField(@TypeOf(options), "data_view")) {
            return .{};
        }

        const given = options.data_view;
        const Given = @TypeOf(given);

        return .{
            .columns = if (@hasField(Given, "columns"))
                names_of(Definition, "columns", given.columns)
            else
                &.{},
            .filters = if (@hasField(Given, "filters"))
                filters_of(name, given.filters, status_id, fields)
            else
                &.{},
            .order = if (@hasField(Given, "order")) order_of(name, given.order, fields) else null,
        };
    }
}

/// Columns given as enum literals (`.total`), each core's or a field that holds a value:
/// one of the record's own (looked up by name, never by reading the list) whose kind is not
/// a tab, an accordion or a message.
fn names_of(
    comptime Definition: type,
    comptime option: []const u8,
    comptime given: anytype,
) []const []const u8 {
    comptime {
        const name = Definition.type_name;
        var names: []const []const u8 = &.{};

        std.debug.assert(name.len > 0);

        if (given.len > view_model.columns_max) {
            @compileError("record " ++ name ++ ": `.data_view." ++ option ++ "` names too many");
        }

        for (given) |literal| {
            const field = @tagName(literal);
            const own = @hasField(Definition.Doc, field) and !layout_override(Definition, field);

            if (!own and !listed_in(&core_columns, field)) {
                @compileError("record " ++ name ++ ": `.data_view." ++ option ++ "` names `" ++
                    field ++ "`, not a field that holds a value");
            }

            names = names ++ &[_][]const u8{field};
        }

        const done = names;

        return done;
    }
}

/// Whether `.fields.<field>.kind` makes it a field that holds no value.
fn layout_override(comptime Definition: type, comptime field: []const u8) bool {
    comptime {
        const given = Definition.given;

        std.debug.assert(field.len > 0);

        if (!@hasField(@TypeOf(given), "fields") or !@hasField(@TypeOf(given.fields), field)) {
            return false;
        }

        const override = @field(given.fields, field);

        if (!@hasField(@TypeOf(override), "kind")) {
            return false;
        }

        return field_model.is_layout(override.kind);
    }
}

fn field_def(comptime fields: []const field_model.Def, comptime name: []const u8) ?field_model.Def {
    std.debug.assert(name.len > 0);

    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field;
        }
    }

    return null;
}

/// The family of a field's kind; core's kinds only, a plugin's own kind does not filter yet.
fn family_of(
    comptime fields: []const field_model.Def,
    comptime name: []const u8,
) field_filter.Family {
    comptime {
        std.debug.assert(name.len > 0);

        const field = field_def(fields, name) orelse return .none;
        const kind = kinds.Core.find_kind(field.kind) orelse return .none;

        return field_filter.family_of(kind);
    }
}

/// Whether lists order by the field: its kind can, and the field asks (or its kind does).
fn sortable(comptime fields: []const field_model.Def, comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    const field = field_def(fields, name) orelse return false;
    const family = family_of(fields, name);
    const wanted = field.sortable orelse field_filter.sorts_by_default(family);

    return !field.many and field_filter.sortable(family) and wanted;
}

/// `.{ .field = .status, .is = .placed }`, `.{ .field = .total, .more = 4999 }`: one operator
/// the field's kind offers, its value as a clause's text.
fn filters_of(
    comptime name: []const u8,
    comptime given: anytype,
    comptime status_id: anytype,
    comptime fields: []const field_model.Def,
) []const filter.Clause {
    comptime {
        var clauses: []const filter.Clause = &.{};

        std.debug.assert(name.len > 0);

        for (given) |one| {
            clauses = clauses ++ &[_]filter.Clause{clause_of(name, one, status_id, fields)};
        }

        const done = clauses;

        return done;
    }
}

fn clause_of(
    comptime name: []const u8,
    comptime one: anytype,
    comptime status_id: anytype,
    comptime fields: []const field_model.Def,
) filter.Clause {
    comptime {
        const parts = std.meta.fieldNames(@TypeOf(one));
        const shape = "record " ++ name ++ ": a filter is `.{ .field = .name, .<operator> = " ++
            "value }`";

        if (parts.len != 2 or !@hasField(@TypeOf(one), "field")) {
            @compileError(shape);
        }

        const field = @tagName(one.field);
        const operator = if (std.mem.eql(u8, parts[0], "field")) parts[1] else parts[0];
        const value = @field(one, operator);

        if (std.mem.eql(u8, field, "status")) {
            if (!std.mem.eql(u8, operator, "is") and !std.mem.eql(u8, operator, "not")) {
                @compileError("record " ++ name ++ ": status filters with `.is` or `.not`");
            }

            return .{
                .key = field,
                .operator = operator,
                .value = status_id(name, @tagName(value)),
            };
        }

        const def = field_def(fields, field) orelse
            @compileError("record " ++ name ++ ": filter on `" ++ field ++ "`, not a field");

        if (!def.filterable) {
            @compileError("record " ++ name ++ ": `" ++ field ++ "` is not filterable");
        }

        const offered = field_filter.operators_of(family_of(fields, field), def.many);

        for (offered) |candidate| {
            if (std.mem.eql(u8, candidate.id, operator)) {
                return .{
                    .key = field_filter.prefix ++ field,
                    .operator = operator,
                    .value = value_text(name, operator, value),
                };
            }
        }

        @compileError("record " ++ name ++ ": `" ++ field ++ "` does not filter with `." ++
            operator ++ "`");
    }
}

/// A filter's value as a clause writes it: `placed`, `yes`, `4999`, `10..20`, `["s","m"]`.
fn value_text(
    comptime name: []const u8,
    comptime operator: []const u8,
    comptime value: anytype,
) []const u8 {
    comptime {
        const Value = @TypeOf(value);

        std.debug.assert(name.len > 0);

        if (std.mem.eql(u8, operator, "between")) {
            return one_text(value[0]) ++ ".." ++ one_text(value[1]);
        }

        const listing = std.mem.endsWith(u8, operator, "_of");
        const is_text = Value == []const u8 or
            (@typeInfo(Value) == .pointer and
                @typeInfo(@typeInfo(Value).pointer.child) == .array and
                @typeInfo(@typeInfo(Value).pointer.child).array.child == u8);

        if (!listing or is_text) {
            return one_text(value);
        }

        var text: []const u8 = "[";

        for (value, 0..) |item, index| {
            const quoted = @typeInfo(@TypeOf(item)) != .comptime_int and
                @typeInfo(@TypeOf(item)) != .int;
            const one = if (quoted) "\"" ++ one_text(item) ++ "\"" else one_text(item);

            text = text ++ (if (index == 0) "" else ",") ++ one;
        }

        return text ++ "]";
    }
}

fn one_text(comptime value: anytype) []const u8 {
    comptime {
        const text: []const u8 = switch (@typeInfo(@TypeOf(value))) {
            .enum_literal, .@"enum" => @tagName(value),
            .bool => if (value) "yes" else "no",
            .comptime_int, .int, .comptime_float, .float => std.fmt.comptimePrint("{d}", .{value}),
            else => value,
        };

        std.debug.assert(text.len > 0);

        return text;
    }
}

/// `.{ .field = .number, .direction = .desc }` as `-number`.
fn order_of(
    comptime name: []const u8,
    comptime given: anytype,
    comptime fields: []const field_model.Def,
) []const u8 {
    comptime {
        const field = @tagName(given.field);
        const descending = std.mem.eql(u8, @tagName(given.direction), "desc");

        std.debug.assert(name.len > 0);

        if (!listed_in(&view_model.core_orders, field) and !sortable(fields, field)) {
            @compileError("record " ++ name ++ ": a list does not order by `" ++ field ++ "`");
        }

        return (if (descending) "-" else "") ++ field;
    }
}

test "a record's menu and default view, named from its own fields" {
    const Order = struct {
        number: u32,
        total: u32,
    };
    const Definition = struct {
        pub const Doc = Order;
        pub const type_name = "order";
        pub const given = .{
            .name = "order",
            .menu = .{
                .parent = &.{ "checkout.orders", "products.catalog" },
                .icon = "package",
            },
            .data_view = .{
                .columns = &.{ .number, .total, .status },
                .filters = &.{
                    .{
                        .field = .status,
                        .is = .placed,
                    },
                    .{
                        .field = .total,
                        .between = .{ 100, 500 },
                    },
                    .{
                        .field = .size,
                        .any_of = .{ "s", "m" },
                    },
                    .{
                        .field = .placed,
                        .in_the_past = "7d",
                    },
                },
                .order = .{
                    .field = .number,
                    .direction = .desc,
                },
            },
        };
    };
    const fields = [_]field_model.Def{
        .{
            .name = "number",
            .label = "Number",
            .kind = "integer",
        },
        .{
            .name = "total",
            .label = "Total",
            .kind = "money",
        },
        .{
            .name = "size",
            .label = "Size",
            .kind = "select",
        },
        .{
            .name = "placed",
            .label = "Placed",
            .kind = "datetime",
        },
    };
    const Ids = struct {
        fn id(comptime handle: []const u8, comptime value: []const u8) []const u8 {
            return handle ++ "." ++ value;
        }
    };
    const menu = comptime menu_of(Definition);
    const view = comptime view_of(Definition, Ids.id, &fields);

    try std.testing.expectEqualStrings("products.catalog", menu.parents[1]);
    try std.testing.expectEqualStrings("package", comptime icon_of(Definition).?);
    try std.testing.expectEqualStrings("status", view.columns[2]);
    try std.testing.expectEqualStrings("order.placed", view.filters[0].value);
    try std.testing.expectEqualStrings("field.total", view.filters[1].key);
    try std.testing.expectEqualStrings("100..500", view.filters[1].value);
    try std.testing.expectEqualStrings("[\"s\",\"m\"]", view.filters[2].value);
    try std.testing.expectEqualStrings("7d", view.filters[3].value);
    try std.testing.expectEqualStrings("-number", view.order.?);
}

test "a record kept out of the menu" {
    const Definition = struct {
        pub const Doc = struct {
            title: []const u8,
        };
        pub const type_name = "notes_settings";
        pub const given = .{
            .name = "notes_settings",
            .menu = .none,
        };
    };

    const menu = comptime menu_of(Definition);
    const icon = comptime icon_of(Definition);

    try std.testing.expect(menu.hidden);
    try std.testing.expectEqual(0, menu.parents.len);
    try std.testing.expectEqual(null, icon);
}
