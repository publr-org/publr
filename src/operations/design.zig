const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/design.zig");
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

pub const namespace = public.namespace;

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
    _ = @import("../publr/operations/design/item.zig");
}
