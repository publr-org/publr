//! Each compiled-in plugin's `interactive/*.ptsx`, built as an installed plugin's are
//! (`pjsx_gen --script`): their render as JavaScript, the browser's stores, the classes and
//! the components a page may place, as the `native_interactive` module the registry reads.
//! One path where the site runs, whichever way the plugin came.
const std = @import("std");
const repository = @import("repository.zig");
const native_plugins = @import("native_plugins.zig");
const embed = @import("apps/embed.zig");

const components_dir = "../ui/src/components";
const icons_dir = "../icons/icons";
const parts = [_][]const u8{ "components.json", "render.js", "stores.js", "classes.txt" };
const fields = [_][]const u8{ "components", "render", "browser", "classes" };

pub fn add(
    builder: *std.Build,
    library: *std.Build.Module,
    dir: []const u8,
    native: native_plugins.Native,
    pjsx_gen: *std.Build.Step.Compile,
) void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(builder.root.sub_path.len == 0);

    const names = native_plugins.names_of(builder, dir, native);
    var source: std.ArrayList(u8) = .empty;
    const module = builder.createModule(.{
        .root_source_file = null,
        .target = library.resolved_target,
        .optimize = library.optimize,
    });

    append(builder, &source, "pub const all = [_]struct { plugin: []const u8, " ++
        "components: []const u8, render: []const u8, browser: []const u8, " ++
        "classes: []const u8 }{\n");

    for (names) |name| {
        const folder = builder.pathJoin(&.{ dir, name, "interactive" });

        if (embed.files_under(builder, folder, ".ptsx").len == 0) {
            continue;
        }

        const out = lowered(builder, pjsx_gen, folder);

        append(builder, &source, builder.fmt("    .{{ .plugin = \"{s}\"", .{name}));

        for (parts, fields) |part, field| {
            const import = builder.fmt("interactive:{s}:{s}", .{ name, part });

            module.addAnonymousImport(import, .{
                .root_source_file = out.path(builder, part),
            });
            const entry = builder.fmt(", .{s} = @embedFile(\"{s}\")", .{ field, import });

            append(builder, &source, entry);
        }

        append(builder, &source, " },\n");
    }

    append(builder, &source, "};\n");
    module.root_source_file = builder.addWriteFiles().add("interactive.zig", source.items);
    library.addImport("native_interactive", module);
}

fn lowered(
    builder: *std.Build,
    pjsx_gen: *std.Build.Step.Compile,
    folder: []const u8,
) std.Build.LazyPath {
    std.debug.assert(folder.len > 0);

    const run = builder.addRunArtifact(pjsx_gen);

    run.addArgs(&.{ "--engine", "--script" });
    run.addDirectoryArg(builder.path(folder));
    run.addArg(repository.path(builder, components_dir));
    run.addArg(repository.path(builder, icons_dir));

    const out = run.addOutputDirectoryArg("interactive");

    for (embed.files_under(builder, folder, ".ptsx")) |file| {
        run.addFileInput(builder.path(file));
    }

    return out;
}

fn append(builder: *std.Build, source: *std.ArrayList(u8), text: []const u8) void {
    std.debug.assert(text.len > 0);
    std.debug.assert(source.items.len < 1 << 20);

    source.appendSlice(builder.allocator, text) catch @panic("OOM");
}
