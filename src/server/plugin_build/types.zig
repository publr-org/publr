//! After a build, a plugin with views gets its operations as TypeScript beside them,
//! `ui/operations.d.ts`, so `call` and `query` know every name and field. A plugin with no
//! `ui/` folder gets nothing.
const std = @import("std");
const model = @import("../../model.zig");

const operation_types = model.operation_types;

pub fn write(init: std.process.Init, dir: []const u8, manifest: []const u8) !void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(manifest.len > 0);

    const arena = init.arena.allocator();
    const ui_dir = try std.fs.path.join(arena, &.{ dir, "ui" });

    std.Io.Dir.cwd().access(init.io, ui_dir, .{}) catch return;

    const Manifest = model.sandboxed_plugin.Manifest;
    const parsed = try std.json.parseFromSliceLeaky(Manifest, arena, manifest, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const operations = try arena.alloc(operation_types.Operation, parsed.operations.len);

    for (parsed.operations, operations) |declared, *operation| {
        operation.* = .{
            .name = declared.name,
            .input = declared.input,
            .output = declared.output,
        };
    }

    var out: std.Io.Writer.Allocating = .init(arena);

    try operation_types.write(&out.writer, arena, operations);

    const path = try std.fs.path.join(arena, &.{ ui_dir, "operations.d.ts" });

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.written() });
}
