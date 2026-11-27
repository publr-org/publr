//! An app's design: its design system, written into its `app.zon` and `design/system.zon`,
//! and its moodboard.
const operation = @import("../operation.zig");

pub const SaveSystem = @import("design/system.zig").SaveSystem;
pub const System = @import("design/read_system.zig").System;
pub const Moodboard = @import("design/moodboard.zig").Moodboard;
pub const SaveMoodboard = @import("design/moodboard.zig").SaveMoodboard;
pub const Item = @import("design/moodboard.zig").Item;

pub const namespace: operation.Namespace = .{
    .name = "design",
    .label = "Design",
    .area = .site,
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
