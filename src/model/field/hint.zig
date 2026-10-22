//! The line beside a field's help that says its rules: one part per rule, each a standard
//! template with the rule's bounds as named values (`Up to {max_len} characters`), for the
//! admin to translate and join. A field's own `validation.hint` replaces the parts and takes
//! the same values. Required is the label's mark, not a part.
const std = @import("std");
const Def = @import("../field.zig").Def;
const validation_module = @import("validation.zig");

pub const parts_max: u32 = 16;
pub const values_max: u32 = 2;

/// A placeholder's value, as text.
pub const Value = struct {
    name: []const u8,
    value: []const u8,
};

pub const Part = struct {
    /// The template, also its translation id.
    template: []const u8,
    values: [values_max]Value = undefined,
    values_len: u32 = 0,

    pub fn named(part: *const Part) []const Value {
        std.debug.assert(part.values_len <= values_max);
        std.debug.assert(part.template.len > 0);

        return part.values[0..part.values_len];
    }
};

pub const Parts = struct {
    items: [parts_max]Part = undefined,
    len: u32 = 0,

    pub fn slice(parts: *const Parts) []const Part {
        std.debug.assert(parts.len <= parts_max);
        std.debug.assert(parts.items.len == parts_max);

        return parts.items[0..parts.len];
    }

    fn add(parts: *Parts, part: Part) void {
        std.debug.assert(part.template.len > 0);
        std.debug.assert(parts.len <= parts_max);

        if (parts.len < parts_max) {
            parts.items[parts.len] = part;
            parts.len += 1;
        }
    }
};

const Count = struct {
    name: []const u8,
    value: ?u32,
};

const Bound = struct {
    name: []const u8,
    value: ?f64,
};

const Listed = struct {
    template: []const u8,
    name: []const u8,
    values: []const []const u8,
};

/// Every bound a field has, by the names its `hint` and the templates use.
pub fn values_of(arena: std.mem.Allocator, def: Def) error{OutOfMemory}![]const Value {
    std.debug.assert(def.name.len > 0);

    const rules = def.validation;
    var list: std.ArrayList(Value) = .empty;
    const counts = [_]Count{
        .{
            .name = "min_len",
            .value = rules.min_len,
        },
        .{
            .name = "max_len",
            .value = rules.max_len,
        },
        .{
            .name = "items_min",
            .value = rules.items_min,
        },
        .{
            .name = "items_max",
            .value = rules.items_max,
        },
        .{
            .name = "words_min",
            .value = rules.words_min,
        },
        .{
            .name = "words_max",
            .value = rules.words_max,
        },
    };
    const bounds = [_]Bound{
        .{
            .name = "min",
            .value = rules.min,
        },
        .{
            .name = "max",
            .value = rules.max,
        },
    };

    for (counts) |count| {
        if (count.value) |number| {
            try list.append(arena, .{
                .name = count.name,
                .value = try std.fmt.allocPrint(arena, "{d}", .{number}),
            });
        }
    }

    for (bounds) |bound| {
        if (bound.value) |number| {
            try list.append(arena, .{
                .name = bound.name,
                .value = try std.fmt.allocPrint(arena, "{d}", .{number}),
            });
        }
    }

    std.debug.assert(list.items.len <= counts.len + 2);

    return list.items;
}

/// The standard parts for the field's rules, in a fixed order; none for a field without.
pub fn parts_of(arena: std.mem.Allocator, def: Def) error{OutOfMemory}!Parts {
    std.debug.assert(def.name.len > 0);

    const rules = def.validation;
    var parts: Parts = .{};

    try bounded(arena, &parts, "min_len", rules.min_len, "max_len", rules.max_len, .{
        "{min_len} to {max_len} characters",
        "At least {min_len} characters",
        "Up to {max_len} characters",
    });
    try bounded(arena, &parts, "words_min", rules.words_min, "words_max", rules.words_max, .{
        "{words_min} to {words_max} words",
        "At least {words_min} words",
        "Up to {words_max} words",
    });
    try bounded(arena, &parts, "items_min", rules.items_min, "items_max", rules.items_max, .{
        "{items_min} to {items_max} items",
        "At least {items_min} items",
        "Up to {items_max} items",
    });
    try ranged(arena, &parts, rules.min, rules.max);
    try shaped(&parts, rules);
    try listed(arena, &parts, rules);

    std.debug.assert(parts.len <= parts_max);

    return parts;
}

fn bounded(
    arena: std.mem.Allocator,
    parts: *Parts,
    low_name: []const u8,
    low: ?u32,
    high_name: []const u8,
    high: ?u32,
    templates: [3][]const u8,
) error{OutOfMemory}!void {
    std.debug.assert(low_name.len > 0 and high_name.len > 0);
    std.debug.assert(parts.len <= parts_max);

    var part: Part = .{
        .template = if (low != null and high != null)
            templates[0]
        else if (low != null)
            templates[1]
        else if (high != null)
            templates[2]
        else
            return,
    };

    if (low) |number| {
        part.values[part.values_len] = .{
            .name = low_name,
            .value = try std.fmt.allocPrint(arena, "{d}", .{number}),
        };
        part.values_len += 1;
    }

    if (high) |number| {
        part.values[part.values_len] = .{
            .name = high_name,
            .value = try std.fmt.allocPrint(arena, "{d}", .{number}),
        };
        part.values_len += 1;
    }

    parts.add(part);
}

fn ranged(arena: std.mem.Allocator, parts: *Parts, low: ?f64, high: ?f64) error{OutOfMemory}!void {
    std.debug.assert(parts.len <= parts_max);
    std.debug.assert(low == null or std.math.isFinite(low.?));

    var part: Part = .{
        .template = if (low != null and high != null)
            "{min} to {max}"
        else if (low != null)
            "At least {min}"
        else if (high != null)
            "At most {max}"
        else
            return,
    };

    const bounds = [_]Bound{
        .{
            .name = "min",
            .value = low,
        },
        .{
            .name = "max",
            .value = high,
        },
    };

    for (bounds) |bound| {
        if (bound.value) |number| {
            part.values[part.values_len] = .{
                .name = bound.name,
                .value = try std.fmt.allocPrint(arena, "{d}", .{number}),
            };
            part.values_len += 1;
        }
    }

    parts.add(part);
}

/// The rules on a value's shape that take no bounds.
fn shaped(parts: *Parts, rules: validation_module.Validation) error{OutOfMemory}!void {
    std.debug.assert(parts.len <= parts_max);
    std.debug.assert(rules.pattern.len <= 255);

    const preset: ?[]const u8 = switch (rules.preset) {
        .any => null,
        .digits => "Digits only",
        .letters => "Letters only",
        .alphanumeric => "Letters and digits only",
        .no_spaces => "No spaces",
        .lowercase => "Lowercase only",
        .uppercase => "Uppercase only",
        .phone => "A phone number",
    };

    if (preset) |template| {
        parts.add(.{
            .template = template,
        });
    }

    if (rules.distinct) {
        parts.add(.{
            .template = "Each one different",
        });
    }

    if (rules.unique) {
        parts.add(.{
            .template = "No two records alike",
        });
    }

    if (rules.date.from_now) {
        parts.add(.{
            .template = "Today or later",
        });
    }
}

/// The rules that name what is accepted: a pattern, domains, schemes, hosts, file types.
fn listed(
    arena: std.mem.Allocator,
    parts: *Parts,
    rules: validation_module.Validation,
) error{OutOfMemory}!void {
    std.debug.assert(parts.len <= parts_max);
    std.debug.assert(rules.email.domains.len <= 256);

    const lists = [_]Listed{
        .{
            .template = "An address at {domains}",
            .name = "domains",
            .values = rules.email.domains,
        },
        .{
            .template = "Starting with {schemes}",
            .name = "schemes",
            .values = rules.url.schemes,
        },
        .{
            .template = "On {hosts}",
            .name = "hosts",
            .values = rules.url.hosts,
        },
        .{
            .template = "Files: {types}",
            .name = "types",
            .values = rules.media.types,
        },
    };

    if (rules.pattern.len > 0) {
        var part: Part = .{
            .template = "Shaped like {pattern}",
        };

        part.values[0] = .{
            .name = "pattern",
            .value = rules.pattern,
        };
        part.values_len = 1;
        parts.add(part);
    }

    for (lists) |list| {
        if (list.values.len > 0) {
            var part: Part = .{
                .template = list.template,
            };

            part.values[0] = .{
                .name = list.name,
                .value = try std.mem.join(arena, ", ", list.values),
            };
            part.values_len = 1;
            parts.add(part);
        }
    }
}

test "a field's rules as parts, and its bounds as values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const note: Def = .{
        .name = "note",
        .label = "Note",
        .kind = "string",
        .validation = .{
            .min_len = 1,
            .max_len = 280,
            .preset = .no_spaces,
        },
    };
    const parts = try parts_of(arena, note);

    try std.testing.expectEqual(2, parts.len);
    const first = parts.items[0];

    try std.testing.expectEqualStrings("{min_len} to {max_len} characters", first.template);
    try std.testing.expectEqualStrings("280", parts.items[0].named()[1].value);
    try std.testing.expectEqualStrings("No spaces", parts.items[1].template);

    const values = try values_of(arena, note);

    try std.testing.expectEqualStrings("max_len", values[1].name);

    const plain: Def = .{
        .name = "body",
        .label = "Body",
        .kind = "text",
    };

    try std.testing.expectEqual(0, (try parts_of(arena, plain)).len);
}
