const std = @import("std");
pub const conditions = @import("conditions.zig");

pub const Destination = enum { content, taxonomy, settings, component, user, media };
pub const Position = enum { main, sidebar };
pub const Labels = enum { above, beside };
pub const Instructions = enum { below_label, below_input };
pub const Presentation = struct {
    position: Position = .main,
    labels: Labels = .above,
    instructions: Instructions = .below_input,
};
pub const Options = struct {
    active: bool = true,
    location: conditions.Set = &.{},
    presentation: Presentation = .{},
};

pub fn valid(options: Options) bool {
    std.debug.assert(conditions.groups_max > 0);

    if (!conditions.valid(options.location)) {
        return false;
    }

    for (options.location) |group| {
        for (group.rules) |rule| {
            // A name with a dot is a plugin's rule (`loyalty.tier`), "user" one account.
            const known = std.mem.eql(u8, rule.field, "destination") or
                std.mem.eql(u8, rule.field, "type") or
                std.mem.eql(u8, rule.field, "role") or
                std.mem.eql(u8, rule.field, "media_type") or
                std.mem.eql(u8, rule.field, "user") or
                std.mem.indexOfScalar(u8, rule.field, '.') != null;

            if (!known or (rule.operator != .equal and rule.operator != .not_equal)) {
                return false;
            }
        }
    }

    return true;
}

pub const Context = struct {
    destination: Destination,
    type: []const u8 = "",
    role: []const u8 = "",
    media_type: []const u8 = "",
    /// The account or file being edited, for the "user" rule and plugins' rules.
    id: []const u8 = "",
    /// The caller's `*sdk.Ctx`, which plugins' rules run with; without it they never match.
    reader: ?*anyopaque = null,
    rules: []const PluginRule = &.{},
};

/// What a plugin's rule decides for: the account or file being edited.
pub const Target = struct {
    destination: Destination,
    id: []const u8,
};

/// A location rule a plugin brings (`loyalty.tier`): the values the admin's dropdown offers
/// and whether a target matches. `ctx` is the caller's `*sdk.Ctx`; a rule that fails offers
/// nothing and doesn't match.
pub const PluginRule = struct {
    id: []const u8,
    label: []const u8,
    /// `id` is the rule's own, for an installed plugin's rules run by name.
    values: *const fn (ctx: *anyopaque, id: []const u8) []const []const u8,
    matches: *const fn (ctx: *anyopaque, target: Target, rule: conditions.Rule) bool,
};

pub fn find_rule(rules: []const PluginRule, id: []const u8) ?PluginRule {
    std.debug.assert(rules.len <= 1 << 10);

    for (rules) |rule| {
        if (std.mem.eql(u8, rule.id, id)) {
            return rule;
        }
    }

    return null;
}

pub fn applies(declared: Options, context: Context) bool {
    std.debug.assert(declared.location.len <= conditions.groups_max);

    if (!declared.active) {
        return false;
    }

    if (declared.location.len == 0) {
        return true;
    }

    for (declared.location) |group| {
        var matched = group.rules.len > 0;

        for (group.rules) |rule| {
            if (!rule_applies(rule, context)) {
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

/// One rule over the context: core's fields by value, a plugin's by its `matches`; a rule
/// no plugin brings (its plugin removed) never matches.
fn rule_applies(rule: conditions.Rule, context: Context) bool {
    std.debug.assert(rule.field.len > 0);

    if (std.mem.indexOfScalar(u8, rule.field, '.') != null) {
        const found = find_rule(context.rules, rule.field) orelse return false;
        const reader = context.reader orelse return false;

        if (context.id.len == 0) {
            return false;
        }

        return found.matches(reader, .{
            .destination = context.destination,
            .id = context.id,
        }, rule);
    }

    const value = if (std.mem.eql(u8, rule.field, "destination"))
        @tagName(context.destination)
    else if (std.mem.eql(u8, rule.field, "type"))
        context.type
    else if (std.mem.eql(u8, rule.field, "role"))
        context.role
    else if (std.mem.eql(u8, rule.field, "media_type"))
        context.media_type
    else if (std.mem.eql(u8, rule.field, "user"))
        context.id
    else
        "";

    return value.len > 0 and conditions.match_rule(rule, .{
        .string = value,
    });
}

/// The fields as checked: as they are while the group applies, else with nothing required
/// (a copy in `arena`).
pub fn checked_fields(
    arena: std.mem.Allocator,
    defs: []const @import("field.zig").Def,
    active: bool,
) error{OutOfMemory}![]const @import("field.zig").Def {
    std.debug.assert(defs.len <= @import("field.zig").fields_max);

    if (active) {
        return defs;
    }

    const relaxed = try arena.dupe(@import("field.zig").Def, defs);

    for (relaxed) |*field| {
        field.validation.required = false;
        field.validation.items_min = null;
    }

    std.debug.assert(relaxed.len == defs.len);

    return relaxed;
}

test "location groups combine AND and OR and absent context never matches exclusions" {
    const options: Options = .{
        .location = &.{
            .{
                .rules = &.{
                    .{
                        .field = "destination",
                        .value = "user",
                    },
                    .{
                        .field = "role",
                        .value = "admin",
                    },
                },
            },
            .{
                .rules = &.{.{
                    .field = "media_type",
                    .value = "image",
                }},
            },
        },
    };
    try std.testing.expect(valid(options));
    try std.testing.expect(applies(options, .{
        .destination = .user,
        .role = "admin",
    }));
    try std.testing.expect(!applies(options, .{
        .destination = .user,
        .role = "editor",
    }));
    try std.testing.expect(applies(options, .{
        .destination = .media,
        .media_type = "image",
    }));
    try std.testing.expect(!applies(.{
        .active = false,
    }, .{
        .destination = .content,
    }));
    const exclusion: Options = .{
        .location = &.{.{
            .rules = &.{.{
                .field = "role",
                .operator = .not_equal,
                .value = "admin",
            }},
        }},
    };
    try std.testing.expect(!applies(exclusion, .{
        .destination = .content,
    }));
    try std.testing.expect(!valid(.{
        .location = &.{.{
            .rules = &.{.{
                .field = "unknown",
                .value = "anything",
            }},
        }},
    }));
}

test "a plugin's rule decides by its matches; a rule no plugin brings never matches" {
    const Gold = struct {
        fn values(_: *anyopaque, _: []const u8) []const []const u8 {
            return &.{ "silver", "gold" };
        }

        fn matches(_: *anyopaque, target: Target, rule: conditions.Rule) bool {
            const tier = if (std.mem.eql(u8, target.id, "ada")) "gold" else "silver";

            return conditions.match_rule(rule, .{
                .string = tier,
            });
        }
    };
    const rules = [_]PluginRule{.{
        .id = "loyalty.tier",
        .label = "Loyalty tier",
        .values = Gold.values,
        .matches = Gold.matches,
    }};
    const options: Options = .{
        .location = &.{.{
            .rules = &.{.{
                .field = "loyalty.tier",
                .value = "gold",
            }},
        }},
    };
    var reader: u8 = 0;
    const ada: Context = .{
        .destination = .user,
        .id = "ada",
        .reader = &reader,
        .rules = &rules,
    };

    try std.testing.expect(valid(options));
    try std.testing.expect(applies(options, ada));
    var grace = ada;
    grace.id = "grace";
    try std.testing.expect(!applies(options, grace));
    var removed = ada;
    removed.rules = &.{};
    try std.testing.expect(!applies(options, removed));
    try std.testing.expect(applies(.{
        .location = &.{.{
            .rules = &.{.{
                .field = "user",
                .value = "ada",
            }},
        }},
    }, ada));
}
