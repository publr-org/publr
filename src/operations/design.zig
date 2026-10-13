//! The app's design: the system types its overrides and its moodboard are records of, made
//! or brought up to date as the system whenever a database opens; its design system, written
//! into its `app.zon`; its moodboard.

const std = @import("std");
const sdk = @import("../sdk.zig");
const design = @import("../model/design.zig");
const content_type = @import("../model/content_type.zig");
const plugin_types = @import("../sdk/plugin/types.zig");
const system = @import("design/system.zig");
const read_system = @import("design/read_system.zig");
const moodboard = @import("design/moodboard.zig");

pub const SaveSystem = system.SaveSystem;
pub const System = read_system.System;
pub const Moodboard = moodboard.Moodboard;
pub const SaveMoodboard = moodboard.SaveMoodboard;
pub const Item = moodboard.Item;

pub const namespace: sdk.operation.Namespace = .{
    .name = "design",
    .summary = "An app's design system and moodboard",
    .details =
    \\An app's design system is its design tokens and fonts, kept in its `app.zon`
    \\(`.tokens`, `.fonts`), and the structure over them in its `design/system.zon` (color
    \\roles, font definitions, the type scale, icons): `design system` reads them,
    \\`design save_system` writes them and loads the apps, so every page shows them at
    \\once. Its moodboard is the references the site is designed from:
    \\notes, links, images, colors, fonts and Figma frames, each a `moodboard_item` record
    \\of the app; `design moodboard` reads it, `design save_moodboard` saves it whole.
    ,
};

pub const operations = [_]type{ System, SaveSystem, Moodboard, SaveMoodboard };

const declared = [_]plugin_types.Declared{
    .{
        .owner = content_type.core_owner,
        .def = design.template_def,
    },
    .{
        .owner = content_type.core_owner,
        .def = design.part_def,
    },
    .{
        .owner = content_type.core_owner,
        .def = design.pattern_def,
    },
    .{
        .owner = content_type.core_owner,
        .def = design.moodboard_def,
    },
};

pub fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.db.transaction_depth == 0);

    try plugin_types.apply(ctx, &declared);
}

test {
    _ = system;
    _ = read_system;
    _ = moodboard;
    _ = @import("design/item.zig");
}
