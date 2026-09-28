const std = @import("std");
const admin = @import("../admin.zig");
const model = @import("../../model.zig");
const conditions = model.field.conditions;

pub fn read(arena: std.mem.Allocator, form: *const admin.Form, prefix: []const u8) !conditions.Set {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(prefix.len > 0);
    const invalid: conditions.Set = &.{.{ .rules = &.{} }};
    const start = try std.fmt.allocPrint(arena, "{s}.", .{prefix});

    if (!valid_pairs(form, start)) {
        return invalid;
    }

    var groups: std.ArrayList(conditions.Group) = .empty;

    for (0..conditions.groups_max) |group_index| {
        var rules: std.ArrayList(conditions.Rule) = .empty;

        for (0..conditions.rules_max) |rule_index| {
            const base = try std.fmt.allocPrint(
                arena,
                "{s}.{d}.{d}.",
                .{
                    prefix,
                    group_index,
                    rule_index,
                },
            );
            const field = form.text(try std.fmt.allocPrint(arena, "{s}field", .{base}));
            const operator = form.text(try std.fmt.allocPrint(arena, "{s}operator", .{base}));
            const value = form.text(try std.fmt.allocPrint(arena, "{s}value", .{base}));

            if (field == null) {
                if (operator != null or value != null) {
                    return invalid;
                }

                continue;
            }

            const parsed = std.meta.stringToEnum(
                conditions.Operator,
                operator orelse "equal",
            ) orelse return invalid;

            try rules.append(arena, .{
                .field = field.?,
                .operator = parsed,
                .value = value orelse "",
            });
        }

        if (rules.items.len > 0) {
            try groups.append(arena, .{ .rules = rules.items });
        }
    }

    return groups.items;
}

fn valid_pairs(form: *const admin.Form, start: []const u8) bool {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(start.len > 0);

    for (form.pairs[0..form.len]) |pair| {
        if (!std.mem.startsWith(u8, pair.name, start)) {
            continue;
        }
        var parts = std.mem.splitScalar(u8, pair.name[start.len..], '.');
        const group = std.fmt.parseInt(
            u32,
            parts.next() orelse return false,
            10,
        ) catch return false;
        const rule = std.fmt.parseInt(
            u32,
            parts.next() orelse return false,
            10,
        ) catch return false;
        const key = parts.next() orelse return false;

        const out_of_bounds = group >= conditions.groups_max or rule >= conditions.rules_max;

        if (out_of_bounds or parts.next() != null) {
            return false;
        }

        if (!std.mem.eql(u8, key, "field") and !std.mem.eql(u8, key, "operator") and
            !std.mem.eql(u8, key, "value"))
        {
            return false;
        }

        if (std.mem.eql(
            u8,
            key,
            "operator",
        ) and std.meta.stringToEnum(
            conditions.Operator,
            pair.value,
        ) == null) {
            return false;
        }
    }

    return true;
}

pub fn node(
    arena: std.mem.Allocator,
    field: model.field.Def,
    siblings: []const model.field.Def,
) admin.Error!admin.render.Node {
    std.debug.assert(siblings.len <= model.field.fields_max);
    std.debug.assert(field.conditions.len <= conditions.groups_max);
    const view = admin.views.RuleBuilder;
    var subjects: std.ArrayList(view.SubjectsItem) = .empty;

    for (siblings) |sibling| {
        if (!std.mem.eql(
            u8,
            sibling.name,
            field.name,
        ) and model.field.is_leaf(sibling.kind) and !model.field.is_layout(sibling.kind)) {
            try subjects.append(arena, .{
                .value = sibling.name,
                .label = sibling.label,
                .choices = try choices_of(arena, sibling),
            });
        }
    }

    return render(arena, field.conditions, subjects.items, "conditions", false);
}

pub fn render(
    arena: std.mem.Allocator,
    groups: conditions.Set,
    subjects: []const admin.views.RuleBuilder.SubjectsItem,
    prefix: []const u8,
    location: bool,
) admin.Error!admin.render.Node {
    std.debug.assert(groups.len <= conditions.groups_max);
    std.debug.assert(prefix.len > 0);
    const view = admin.views.RuleBuilder;
    var rows: std.ArrayList(view.RowsItem) = .empty;

    for (groups, 0..) |group, index| {
        for (group.rules, 0..) |rule, rule_index| {
            try rows.append(arena, .{
                .group_index = @floatFromInt(index),
                .index = @floatFromInt(rule_index),
                .field = rule.field,
                .operator = @tagName(rule.operator),
                .value = rule.value,
                .first = rule_index == 0,
                .last = rule_index + 1 == group.rules.len,
            });
        }
    }

    return admin.render.view(arena, view, .{
        .prefix = prefix,
        .rows = rows.items,
        .subjects = subjects,
        .location = location,
    });
}

pub fn choices_of(arena: std.mem.Allocator, field: model.field.Def) ![]const u8 {
    std.debug.assert(field.options.choices.len <= model.field.choices_max);
    const Choice = struct { value: []const u8, label: []const u8 };

    if (std.mem.eql(u8, field.kind, "boolean")) {
        return "[{\"value\":\"true\",\"label\":\"Yes\"},{\"value\":\"false\",\"label\":\"No\"}]";
    }

    const choices = try arena.alloc(Choice, field.options.choices.len);

    for (field.options.choices, 0..) |value, index| {
        choices[index] = .{ .value = value, .label = if (index < field.options.labels.len)
            field.options.labels[index]
        else
            value };
    }

    return std.json.Stringify.valueAlloc(arena, choices, .{});
}

test "rule forms reject unknown operators, excessive indices and incomplete rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { body: []const u8, valid: bool }{
        .{ .body = "conditions.0.0.field=enabled&conditions.0.0.value=true", .valid = true },
        .{ .body = "conditions.8.0.field=enabled", .valid = false },
        .{ .body = "conditions.0.8.field=enabled", .valid = false },
        .{ .body = "conditions.0.0.operator=surprise", .valid = false },
        .{ .body = "conditions.0.0.value=true", .valid = false },
        .{ .body = "conditions.0.0.field.extra=enabled", .valid = false },
    };

    for (cases) |case| {
        const form = admin.Form.parse(arena, case.body) orelse return error.Invalid;
        const parsed = try read(arena, &form, "conditions");
        try std.testing.expectEqual(case.valid, conditions.valid(parsed));
    }
}
