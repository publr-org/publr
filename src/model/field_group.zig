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
            const known = std.mem.eql(u8, rule.field, "destination") or
                std.mem.eql(u8, rule.field, "type") or
                std.mem.eql(u8, rule.field, "role") or
                std.mem.eql(u8, rule.field, "media_type");

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
};

pub fn applies(options: Options, context: Context) bool {
    std.debug.assert(options.location.len <= conditions.groups_max);

    if (!options.active) {
        return false;
    }

    if (options.location.len == 0) {
        return true;
    }

    for (options.location) |group| {
        var matched = group.rules.len > 0;

        for (group.rules) |rule| {
            const value = if (std.mem.eql(u8, rule.field, "destination"))
                @tagName(context.destination)
            else if (std.mem.eql(
                u8,
                rule.field,
                "type",
            )) context.type else if (std.mem.eql(
                u8,
                rule.field,
                "role",
            )) context.role else if (std.mem.eql(
                u8,
                rule.field,
                "media_type",
            )) context.media_type else "";

            if (value.len == 0 or !conditions.match_rule(rule, .{ .string = value })) {
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

pub fn checked_fields(
    defs: []const @import("field.zig").Def,
    active: bool,
    buffer: *[@import("field.zig").fields_max]@import("field.zig").Def,
) []const @import("field.zig").Def {
    std.debug.assert(defs.len <= buffer.len);

    if (active) {
        return defs;
    }

    @memcpy(buffer[0..defs.len], defs);

    for (buffer[0..defs.len]) |*field| {
        field.required = false;
        field.options.items_min = null;
    }

    return buffer[0..defs.len];
}

test "location groups combine AND and OR and absent context never matches exclusions" {
    const options: Options = .{ .location = &.{
        .{ .rules = &.{
            .{ .field = "destination", .value = "user" },
            .{ .field = "role", .value = "admin" },
        } },
        .{ .rules = &.{.{ .field = "media_type", .value = "image" }} },
    } };
    try std.testing.expect(valid(options));
    try std.testing.expect(applies(options, .{ .destination = .user, .role = "admin" }));
    try std.testing.expect(!applies(options, .{ .destination = .user, .role = "editor" }));
    try std.testing.expect(applies(options, .{ .destination = .media, .media_type = "image" }));
    try std.testing.expect(!applies(.{ .active = false }, .{ .destination = .content }));
    const exclusion: Options = .{ .location = &.{.{ .rules = &.{.{
        .field = "role",
        .operator = .not_equal,
        .value = "admin",
    }} }} };
    try std.testing.expect(!applies(exclusion, .{ .destination = .content }));
    try std.testing.expect(!valid(.{ .location = &.{.{ .rules = &.{.{
        .field = "unknown",
        .value = "anything",
    }} }} }));
}
