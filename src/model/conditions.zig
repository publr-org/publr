const std = @import("std");

pub const groups_max: u32 = 8;
pub const rules_max: u32 = 8;
pub const name_max: u32 = 64;
pub const value_max: u32 = 255;
pub const Operator = enum { equal, not_equal, empty, not_empty, contains };
pub const Rule = struct {
    field: []const u8,
    operator: Operator = .equal,
    value: []const u8 = "",
};
pub const Group = struct { rules: []const Rule };
pub const Set = []const Group;

pub fn valid(groups: Set) bool {
    std.debug.assert(groups_max > 0);
    std.debug.assert(rules_max > 0);

    if (groups.len > groups_max) {
        return false;
    }

    for (groups) |group| {
        if (group.rules.len == 0 or group.rules.len > rules_max) {
            return false;
        }

        for (group.rules) |rule| {
            if (rule.field.len == 0 or rule.field.len > name_max or rule.value.len > value_max) {
                return false;
            }
        }
    }

    return true;
}

pub fn matches(groups: Set, values: std.json.ObjectMap) bool {
    std.debug.assert(groups.len <= groups_max);

    if (groups.len == 0) {
        return true;
    }

    for (groups) |group| {
        std.debug.assert(group.rules.len <= rules_max);
        var matched = group.rules.len > 0;

        for (group.rules) |rule| {
            if (!match_rule(rule, values.get(rule.field))) {
                matched = false;
                break;
            }
        }

        if (matched) {
            return true;
        }
    }

    return false;
}

pub fn match_rule(rule: Rule, value: ?std.json.Value) bool {
    std.debug.assert(rule.field.len > 0);
    std.debug.assert(rule.value.len <= value_max);

    const empty = value == null or switch (value.?) {
        .null => true,
        .string => |text| text.len == 0,
        .array => |array| array.items.len == 0,
        else => false,
    };

    return switch (rule.operator) {
        .empty => empty,
        .not_empty => !empty,
        .equal => if (value) |found| equal(found, rule.value) else false,
        .not_equal => if (value) |found| !equal(found, rule.value) else true,
        .contains => if (value) |found| contains(found, rule.value) else false,
    };
}

fn equal(value: std.json.Value, wanted: []const u8) bool {
    std.debug.assert(wanted.len <= value_max);

    return switch (value) {
        .string => |text| std.mem.eql(u8, text, wanted),
        .bool => |flag| std.mem.eql(u8, if (flag) "true" else "false", wanted),
        .integer => |number| number == (std.fmt.parseInt(i64, wanted, 10) catch return false),
        .float => |number| number == (std.fmt.parseFloat(f64, wanted) catch return false),
        else => false,
    };
}

fn contains(value: std.json.Value, wanted: []const u8) bool {
    std.debug.assert(wanted.len <= value_max);

    switch (value) {
        .string => |text| return std.mem.indexOf(u8, text, wanted) != null,
        .array => |array| {
            for (array.items) |item| {
                if (equal(item, wanted)) {
                    return true;
                }
            }
        },
        else => {},
    }

    return false;
}

test "conditions require every rule in any group and distinguish false from empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_state.allocator(),
        "{\"enabled\":false,\"format\":\"video\",\"tags\":[\"news\"]}",
        .{},
    );
    const groups: Set = &.{
        .{ .rules = &.{.{ .field = "format", .value = "image" }} },
        .{ .rules = &.{
            .{ .field = "format", .value = "video" },
            .{ .field = "enabled", .value = "false" },
            .{ .field = "tags", .operator = .contains, .value = "news" },
        } },
    };
    try std.testing.expect(valid(groups));
    try std.testing.expect(matches(groups, document.object));
    try std.testing.expect(!matches(&.{.{ .rules = &.{
        .{ .field = "enabled", .operator = .empty },
    } }}, document.object));
    try std.testing.expect(!valid(&.{.{ .rules = &.{} }}));
    try std.testing.expect(!valid(&.{.{ .rules = &.{.{ .field = "" }} }}));
}

pub fn validate_fields(defs: anytype, problems: anytype) void {
    std.debug.assert(defs.len <= 64);
    var edges = [_][64]bool{[_]bool{false} ** 64} ** 64;

    for (defs, 0..) |def, index| {
        if (!valid(def.conditions)) {
            problems.add(def.name, "invalid conditional logic");
            continue;
        }

        for (def.conditions) |group| {
            for (group.rules) |rule| {
                var found = false;

                for (defs, 0..) |target, target_index| {
                    if (std.mem.eql(u8, target.name, rule.field)) {
                        found = true;
                        edges[index][target_index] = true;
                    }
                }

                if (!found) {
                    problems.add(def.name, "conditional logic refers to an unknown sibling field");
                }
            }
        }
    }

    for (0..defs.len) |through| {
        for (0..defs.len) |from| {
            for (0..defs.len) |to| {
                edges[from][to] = edges[from][to] or (edges[from][through] and edges[through][to]);
            }
        }
    }

    for (defs, 0..) |def, index| {
        if (edges[index][index]) {
            problems.add(def.name, "conditional logic cannot contain a cycle");
        }
    }
}
