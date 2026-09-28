//! The site's theme, embedded: `themes/<name>/**/*.publr` as text for the engine to read at
//! startup, `public/*` with the island loader and the PublrJS runtime as `/theme/*` assets,
//! the run-time JIT's inputs, and `interactive/*.ptsx` lowered to Zig by `pjsx_gen`.
const std = @import("std");
const diagnostic = @import("diagnostic.zig");

const publr_js_dir = "../publr-js/dist";
const loader_source = "src/adapters/site/islands.js";
const toolbar_source = "src/adapters/site/toolbar.js";
const client_files = @import("../src/ui/client_files.zig");
const tokens_fallback = ".{ .tokens = .{} }\n";
const entry_format = "    .{{ .path = \"{s}\", .data = @embedFile(\"{s}\") }},\n";

pub const Embedded = struct {
    name: []const u8,
    templates: *std.Build.Module,
    assets: *std.Build.Module,
    interactive: *std.Build.Module,
    interactive_classes: std.Build.LazyPath,
    tokens: std.Build.LazyPath,
    style: std.Build.LazyPath,
    preflight: std.Build.LazyPath,
};

pub fn add(
    builder: *std.Build,
    runtime: *std.Build.Module,
    pjsx_gen: *std.Build.Step.Compile,
    theme_dir: []const u8,
) Embedded {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(!std.fs.path.isAbsolute(theme_dir));

    const name = std.fs.path.basename(theme_dir);

    if (name.len == 0) {
        diagnostic.fail("{s}: a theme folder needs a name", .{theme_dir});
    }

    const jit = builder.dependency("publr_jit", .{ .target = builder.graph.host });
    const placeholders = builder.addWriteFiles();
    const interactive = add_interactive(builder, runtime, pjsx_gen, theme_dir, placeholders);

    return .{
        .name = name,
        .templates = templates_module(builder, theme_dir),
        .assets = assets_module(builder, theme_dir, interactive.stores),
        .interactive = interactive.module,
        .interactive_classes = interactive.classes,
        .tokens = optional_file(builder, placeholders, theme_dir, "theme.zon", tokens_fallback),
        .style = optional_file(builder, placeholders, theme_dir, "public/style.css", ""),
        .preflight = jit.path("src/preflight.css"),
    };
}

/// The theme's `middleware.zig`, compiled in: it imports `publr` and every compiled-in
/// plugin by name. A theme without one gets an empty stand-in, and nothing runs.
pub fn middleware(
    builder: *std.Build,
    library: *std.Build.Module,
    theme_dir: []const u8,
) *std.Build.Module {
    std.debug.assert(theme_dir.len > 0);
    std.debug.assert(library.root_source_file != null);

    const path = builder.pathJoin(&.{ theme_dir, "middleware.zig" });
    const root = if (builder.build_root.handle.access(builder.graph.io, path, .{})) |_|
        builder.path(path)
    else |_|
        builder.addWriteFiles().add("middleware.zig", "//! This theme has no middleware.\n");
    const module = builder.createModule(.{
        .root_source_file = root,
        .target = library.resolved_target,
        .optimize = library.optimize,
    });
    const plugins = library.import_table.get("plugins") orelse @panic("plugins not added");

    module.addImport("publr", library);

    for (plugins.import_table.keys(), plugins.import_table.values()) |name, plugin| {
        module.addImport(name, plugin);
    }

    return module;
}

/// The file at `theme_dir/rel` when the theme has it, else `fallback` written to the cache.
fn optional_file(
    builder: *std.Build,
    placeholders: *std.Build.Step.WriteFile,
    theme_dir: []const u8,
    rel: []const u8,
    fallback: []const u8,
) std.Build.LazyPath {
    std.debug.assert(rel.len > 0);
    std.debug.assert(theme_dir.len > 0);

    const path = builder.pathJoin(&.{ theme_dir, rel });

    if (builder.build_root.handle.access(builder.graph.io, path, .{})) |_| {
        return builder.path(path);
    } else |_| {
        return placeholders.add(std.fs.path.basename(rel), fallback);
    }
}

const Interactive = struct {
    module: *std.Build.Module,
    classes: std.Build.LazyPath,
    stores: std.Build.LazyPath,
};

/// `interactive/*.ptsx` through pjsx_gen: the lowered render modules, their class manifest
/// and the client stores. A theme without the folder gets all three empty.
fn add_interactive(
    builder: *std.Build,
    runtime: *std.Build.Module,
    pjsx_gen: *std.Build.Step.Compile,
    theme_dir: []const u8,
    placeholders: *std.Build.Step.WriteFile,
) Interactive {
    std.debug.assert(theme_dir.len > 0);
    std.debug.assert(runtime.root_source_file != null);

    const dir = builder.pathJoin(&.{ theme_dir, "interactive" });
    const sources = files_under(builder, dir, ".ptsx");

    if (sources.len == 0) {
        const empty = placeholders.add("interactive.zig", "");

        return .{
            .module = builder.createModule(.{ .root_source_file = empty }),
            .classes = placeholders.add("interactive-classes.txt", ""),
            .stores = placeholders.add("stores.js", ""),
        };
    }

    const run = builder.addRunArtifact(pjsx_gen);
    const components = builder.pathFromRoot("../ui/src/components");
    const icons = builder.pathFromRoot("../icons/icons");

    run.addDirectoryArg(builder.path(dir));
    run.addArg(components);
    run.addArg(icons);

    const out = run.addOutputDirectoryArg("interactive");

    for (sources) |source| {
        run.addFileInput(builder.path(source));
    }

    const module = builder.createModule(.{
        .root_source_file = out.path(builder, "views.zig"),
        .imports = &.{.{ .name = "runtime", .module = runtime }},
    });

    return .{
        .module = module,
        .classes = out.path(builder, "classes.txt"),
        .stores = out.path(builder, "stores.js"),
    };
}

/// `themes/<name>/**/*.publr` as one generated module: a `File` per template with its
/// theme-relative path and text. `public/` and `interactive/` are not templates.
fn templates_module(builder: *std.Build, theme_dir: []const u8) *std.Build.Module {
    std.debug.assert(theme_dir.len > 0);

    var source: std.Io.Writer.Allocating = .init(builder.allocator);
    const writer = &source.writer;
    const files = builder.addWriteFiles();
    var count: u32 = 0;

    write_header(writer);

    for (files_under(builder, theme_dir, ".publr")) |path| {
        const rel = path[theme_dir.len + 1 ..];
        const top = rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse 0];

        if (top.len == 0) {
            diagnostic.fail("{s} sits at the theme root; a template lives in a folder", .{rel});
        }

        if (std.mem.eql(u8, top, "public") or std.mem.eql(u8, top, "interactive")) {
            continue;
        }

        write_entry(builder, writer, files, rel, path, count);
        count += 1;
    }

    writer.writeAll("};\n") catch diagnostic.fail("build input: out of memory", .{});

    if (count == 0) {
        diagnostic.fail("{s}: no .publr templates found; choose an existing theme", .{theme_dir});
    }

    return module_of(builder, files, source.written());
}

/// Only generated client code is embedded. Public files are copied at site-build time
/// and never enter the compiler cache or the generated-artifact fingerprint.
fn assets_module(
    builder: *std.Build,
    theme_dir: []const u8,
    stores: std.Build.LazyPath,
) *std.Build.Module {
    std.debug.assert(theme_dir.len > 0);
    std.debug.assert(client_files.names.len > 0);

    var source: std.Io.Writer.Allocating = .init(builder.allocator);
    const writer = &source.writer;
    const files = builder.addWriteFiles();
    var count: u32 = 0;

    write_header(writer);
    write_entry(builder, writer, files, "islands.js", loader_source, count);
    count += 1;
    write_entry(builder, writer, files, "toolbar.js", toolbar_source, count);
    count += 1;

    inline for (client_files.names) |name| {
        const file = name ++ ".js";
        const path = builder.pathJoin(&.{ publr_js_dir, file });

        write_entry(builder, writer, files, file, path, count);
        count += 1;
    }

    const stores_name = builder.fmt("asset_{d}", .{count});

    writer.print(
        entry_format,
        .{
            "stores.js",
            stores_name,
        },
    ) catch diagnostic.fail(
        "build input: out of memory",
        .{},
    );
    _ = files.addCopyFile(stores, stores_name);
    count += 1;

    writer.writeAll("};\n") catch diagnostic.fail("build input: out of memory", .{});

    return module_of(builder, files, source.written());
}

fn write_header(writer: *std.Io.Writer) void {
    std.debug.assert(writer.end == 0);

    writer.writeAll(
        \\pub const File = struct { path: []const u8, data: []const u8 };
        \\
        \\pub const files = [_]File{
        \\
    ) catch diagnostic.fail("build input: out of memory", .{});
}

/// One `File` line: the embedded bytes come in as an anonymous import named by `index`.
fn write_entry(
    builder: *std.Build,
    writer: *std.Io.Writer,
    files: *std.Build.Step.WriteFile,
    rel: []const u8,
    path: []const u8,
    index: u32,
) void {
    std.debug.assert(rel.len > 0);
    std.debug.assert(path.len >= rel.len);

    const import_name = builder.fmt("asset_{d}", .{index});

    writer.print(
        entry_format,
        .{
            rel,
            import_name,
        },
    ) catch diagnostic.fail(
        "build input: out of memory",
        .{},
    );
    _ = files.addCopyFile(builder.path(path), import_name);
}

/// The generated table as a module: `files.zig` beside the copied assets, so every
/// `@embedFile` resolves inside the one write-files directory.
fn module_of(
    builder: *std.Build,
    files: *std.Build.Step.WriteFile,
    source: []const u8,
) *std.Build.Module {
    std.debug.assert(source.len > 0);
    std.debug.assert(std.mem.indexOf(u8, source, "pub const files") != null);

    const root = files.add("files.zig", source);

    return builder.createModule(.{ .root_source_file = root });
}

/// Every file with `extension` (any file when empty) under `dir`, as build-root-relative
/// paths with forward slashes, sorted; none when the folder does not exist.
fn files_under(builder: *std.Build, dir: []const u8, extension: []const u8) []const []const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(!std.mem.startsWith(u8, dir, "/"));

    const io = builder.graph.io;
    var handle = builder.build_root.handle.openDir(
        io,
        dir,
        .{
            .iterate = true,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => diagnostic.fail("cannot read {s}: {s}", .{ dir, @errorName(err) }),
    };
    defer handle.close(io);
    var walker = handle.walk(builder.allocator) catch diagnostic.fail(
        "build input: out of memory",
        .{},
    );
    defer walker.deinit();
    var found: std.ArrayList([]const u8) = .empty;

    while (walker.next(io) catch diagnostic.fail("cannot walk the theme", .{})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, extension)) {
            continue;
        }

        if (std.mem.startsWith(u8, entry.basename, ".")) {
            continue;
        }

        const path = builder.pathJoin(&.{ dir, builder.dupe(entry.path) });

        found.append(
            builder.allocator,
            path,
        ) catch diagnostic.fail(
            "build input: out of memory",
            .{},
        );
    }

    std.mem.sort([]const u8, found.items, {}, less_than);

    return found.items;
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
