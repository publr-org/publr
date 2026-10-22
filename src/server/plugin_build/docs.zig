//! Before a build, a plugin's doc comments become a module of their own beside the built
//! module, which the guest root binds to the plugin as the compiled-in build does.
const std = @import("std");
const doc_reader = @import("../../sdk/plugin/doc_reader.zig");
const written_secrets = @import("../../sdk/plugin/written_secrets.zig");

pub const files_max: u32 = 512;
const file_bytes_max: u32 = 1 << 20;

/// Every doc comment under `dir`, and the secrets its strings write, as Zig in `out_path`.
pub fn write(init: std.process.Init, dir: []const u8, out_path: []const u8) !void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(out_path.len > 0);

    const arena = init.arena.allocator();
    var root = try std.Io.Dir.cwd().openDir(init.io, dir, .{
        .iterate = true,
    });
    defer root.close(init.io);

    var walker = try root.walk(arena);
    defer walker.deinit();

    var entries: std.ArrayList(doc_reader.Entry) = .empty;
    var written: std.ArrayList([]const u8) = .empty;
    var files: u32 = 0;

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }

        files += 1;

        if (files > files_max) {
            return error.TooManyFiles;
        }

        const text = try root.readFileAllocOptions(
            init.io,
            entry.path,
            arena,
            .limited(file_bytes_max),
            .of(u8),
            0,
        );
        const key = try doc_reader.file_key(arena, entry.path);

        try doc_reader.read(arena, key, text, &entries);
        try written_secrets.read(arena, text, &written);
    }

    const words = try doc_reader.generated(arena, entries.items);
    const source = try std.mem.concat(arena, u8, &.{
        words,
        try written_secrets.source(arena, written.items),
    });

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(out_path) orelse ".");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = source,
    });
}
