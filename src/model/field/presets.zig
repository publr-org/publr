const std = @import("std");
const field = @import("../field.zig");

pub fn children(kind: []const u8) []const field.Def {
    std.debug.assert(kind.len <= 64 << 10);

    if (std.mem.eql(u8, kind, "link")) {
        return &.{
            .{ .name = "url", .label = "URL", .kind = "url", .required = true },
            .{ .name = "label", .label = "Link text", .kind = "string" },
            .{ .name = "new_window", .label = "Open in a new tab", .kind = "boolean" },
        };
    }

    if (std.mem.eql(u8, kind, "location")) {
        return &.{
            .{ .name = "address", .label = "Address", .kind = "string" },
            .{
                .name = "latitude",
                .label = "Latitude",
                .kind = "number",
                .required = true,
                .options = .{
                    .min = -90,
                    .max = 90,
                },
            },
            .{
                .name = "longitude",
                .label = "Longitude",
                .kind = "number",
                .required = true,
                .options = .{
                    .min = -180,
                    .max = 180,
                },
            },
        };
    }

    return &.{};
}

pub fn apply(
    arena: std.mem.Allocator,
    defs: []const field.Def,
) error{OutOfMemory}![]const field.Def {
    std.debug.assert(field.depth_max < 8);

    if (defs.len > field.fields_max) {
        return defs;
    }

    if (!field.contains_kind(defs, "link") and !field.contains_kind(defs, "location")) {
        return defs;
    }

    const Frame = struct { fields: []field.Def, index: u32 = 0 };
    var frames: [field.depth_max + 1]Frame = undefined;
    const root = try arena.dupe(field.Def, defs);
    frames[0] = .{ .fields = root };
    var depth: u32 = 0;

    while (true) {
        const frame = &frames[depth];
        if (frame.index == frame.fields.len) {
            if (depth == 0) {
                return root;
            }
            depth -= 1;
            continue;
        }
        const def = &frame.fields[frame.index];
        frame.index += 1;
        if (def.fields.len == 0) {
            def.fields = children(def.kind);
        }
        if (def.fields.len > 0 and depth < field.depth_max) {
            const copy = try arena.dupe(field.Def, def.fields);
            def.fields = copy;
            depth += 1;
            frames[depth] = .{ .fields = copy };
        }
    }
}
