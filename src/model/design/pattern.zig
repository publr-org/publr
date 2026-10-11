//! A pattern's variants and color settings: complete alternative compositions (none, or
//! two and more, one of them the default) and the color context a fresh copy wears, with
//! the contexts its copies may not wear. Checked here, kept as the pattern record's fields.

const std = @import("std");
const design = @import("../design.zig");

pub const variants_max: u32 = 16;
pub const contexts_max: u32 = 16;
pub const label_len_max: u32 = 128;
pub const description_len_max: u32 = 512;

pub const Variant = struct {
    name: []const u8 = "",
    label: []const u8 = "",
    description: []const u8 = "",
    html: []const u8 = "",
};

pub const Settings = struct {
    variants: []const Variant = &.{},
    default_variant: []const u8 = "",
    default_color_context: []const u8 = "",
    disabled_color_contexts: []const []const u8 = &.{},
};

/// Why the settings cannot be kept, or null when they can.
pub fn problem(settings: Settings) ?[]const u8 {
    std.debug.assert(variants_max >= 2);
    std.debug.assert(contexts_max > 0);

    if (variants_problem(settings)) |why| {
        return why;
    }

    if (settings.disabled_color_contexts.len > contexts_max) {
        return "too many disabled color contexts";
    }

    const default_context = if (settings.default_color_context.len > 0)
        settings.default_color_context
    else
        "default";

    if (!design.valid_name(default_context)) {
        return "a color context is letters, digits, - and _";
    }

    for (settings.disabled_color_contexts) |context| {
        if (!design.valid_name(context)) {
            return "a color context is letters, digits, - and _";
        }

        if (std.mem.eql(u8, context, default_context)) {
            return "the default color context cannot be disabled";
        }
    }

    return null;
}

fn variants_problem(settings: Settings) ?[]const u8 {
    std.debug.assert(variants_max >= 2);
    std.debug.assert(settings.default_variant.len < 1 << 20);

    const variants = settings.variants;

    if (variants.len == 0) {
        return if (settings.default_variant.len > 0) "a default variant needs variants" else null;
    }

    if (variants.len == 1) {
        return "a pattern has two variants or more, or none";
    }

    if (variants.len > variants_max) {
        return "too many variants";
    }

    var default_found = settings.default_variant.len == 0;

    for (variants, 0..) |variant, index| {
        if (!design.valid_name(variant.name)) {
            return "a variant's name is letters, digits, - and _";
        }

        const label_ok = variant.label.len > 0 and variant.label.len <= label_len_max;

        if (!label_ok or variant.description.len > description_len_max) {
            return "a variant needs a label, and a short description";
        }

        for (variants[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, variant.name)) {
                return "two variants share a name";
            }
        }

        if (std.mem.eql(u8, variant.name, settings.default_variant)) {
            default_found = true;
        }
    }

    return if (default_found) null else "the default variant is not one of the variants";
}

test "problem: no variants, or two and more with a known default" {
    const two = [_]Variant{
        .{
            .name = "light",
            .label = "Light",
            .html = "<p>a</p>",
        },
        .{
            .name = "dark",
            .label = "Dark",
            .description = "On a dark band",
            .html = "<p>b</p>",
        },
    };

    try std.testing.expectEqual(@as(?[]const u8, null), problem(.{}));
    try std.testing.expectEqual(@as(?[]const u8, null), problem(.{
        .variants = &two,
        .default_variant = "dark",
    }));
    try std.testing.expect(problem(.{
        .variants = two[0..1],
    }) != null);
    try std.testing.expect(problem(.{
        .default_variant = "dark",
    }) != null);
    try std.testing.expect(problem(.{
        .variants = &two,
        .default_variant = "gone",
    }) != null);

    const twins = [_]Variant{
        .{
            .name = "same",
            .label = "One",
        },
        .{
            .name = "same",
            .label = "Two",
        },
    };

    try std.testing.expect(problem(.{
        .variants = &twins,
    }) != null);

    const unnamed = [_]Variant{ .{
        .name = "a b",
        .label = "A",
    }, .{
        .name = "c",
        .label = "C",
    } };

    try std.testing.expect(problem(.{
        .variants = &unnamed,
    }) != null);

    const unlabelled = [_]Variant{ .{
        .name = "a",
    }, .{
        .name = "c",
        .label = "C",
    } };

    try std.testing.expect(problem(.{
        .variants = &unlabelled,
    }) != null);
}

test "problem: color contexts, the default never disabled" {
    const disabled = [_][]const u8{ "slate", "clay" };

    try std.testing.expectEqual(@as(?[]const u8, null), problem(.{
        .default_color_context = "terracotta",
        .disabled_color_contexts = &disabled,
    }));
    try std.testing.expect(problem(.{
        .default_color_context = "slate",
        .disabled_color_contexts = &disabled,
    }) != null);

    const default_off = [_][]const u8{"default"};

    try std.testing.expect(problem(.{
        .disabled_color_contexts = &default_off,
    }) != null);

    const odd = [_][]const u8{"no good"};

    try std.testing.expect(problem(.{
        .disabled_color_contexts = &odd,
    }) != null);
    try std.testing.expect(problem(.{
        .default_color_context = "x}y",
    }) != null);
}
