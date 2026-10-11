//! The admin's messages, by domain, embedded in the binary: what Site Health counts a
//! language's coverage against. `scripts/i18n.zig --lines` over the core's folders (domain
//! `publr`) and each compiled-in plugin's folder (its own domain).
const std = @import("std");

/// The folders the core's messages are written in, relative to this repository.
const core_dirs = [_][]const u8{
    "ui",
    "src/adapters",
    "../ui/src/components",
    "../editor/shell",
    "../editor/design",
    "../editor/moodboard",
    "../editor/blocks",
};

/// The declarations whose labels the admin draws by name.
const declared_files = [_][]const u8{
    "src/model/status.zig",
    "src/model/kinds.zig",
    "src/model/filter.zig",
    "src/model/admin_pages.zig",
    "src/model/field/options.zig",
    "src/adapters/admin/types.zig",
    "src/adapters/admin/taxonomies.zig",
    "src/adapters/admin/components.zig",
    "src/adapters/admin/setting_types.zig",
};

pub fn add(
    builder: *std.Build,
    module: *std.Build.Module,
    plugins_dir: []const u8,
    plugin_names: []const []const u8,
) void {
    std.debug.assert(plugins_dir.len > 0);
    std.debug.assert(module.root_source_file != null);

    const tool = builder.addExecutable(.{
        .name = "i18n_messages",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/i18n.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = builder.addRunArtifact(tool);

    run.setCwd(builder.path("."));
    run.addArgs(&.{ "--lines", "--domain", "publr" });

    for (core_dirs) |dir| {
        run.addArg(dir);
        declare(builder, run, dir);
    }

    run.addArg("--declared");

    for (declared_files) |file| {
        run.addArg(file);
        run.addFileInput(builder.path(file));
    }

    for (plugin_names) |name| {
        const dir = builder.pathJoin(&.{ plugins_dir, name });

        run.addArgs(&.{ "--domain", name, dir });
        declare(builder, run, dir);
    }

    const lines = run.captureStdOut(.{});
    const files = builder.addWriteFiles();

    _ = files.addCopyFile(lines, "messages.txt");

    const source = files.add("messages.zig", "pub const lines = @embedFile(\"messages.txt\");\n");

    module.addAnonymousImport("i18n_messages", .{
        .root_source_file = source,
    });
}

/// Every source under `dir` as an input, so an edit re-runs the extraction.
fn declare(builder: *std.Build, run: *std.Build.Step.Run, dir: []const u8) void {
    std.debug.assert(dir.len > 0);

    var handle = builder.build_root.handle.openDir(builder.graph.io, dir, .{
        .iterate = true,
    }) catch return;
    defer handle.close(builder.graph.io);

    var walker = handle.walk(builder.allocator) catch @panic("OOM");
    defer walker.deinit();

    while (walker.next(builder.graph.io) catch null) |entry| {
        const kind = std.mem.endsWith(u8, entry.path, ".ptsx") or
            std.mem.endsWith(u8, entry.path, ".ts") or std.mem.endsWith(u8, entry.path, ".zig");
        const skipped = std.mem.indexOf(u8, entry.path, "zig-cache") != null or
            std.mem.indexOf(u8, entry.path, "node_modules") != null or
            std.mem.indexOf(u8, entry.path, "zig-out") != null;

        if (entry.kind == .file and kind and !skipped) {
            run.addFileInput(builder.path(builder.pathJoin(&.{ dir, entry.path })));
        }
    }
}
