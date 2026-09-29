const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const client_files = @import("../../src/ui/client_files.zig");

const publr_js_dir = "../publr-js/dist";
const loader_source = "src/adapters/apps/islands.js";
const toolbar_source = "src/adapters/apps/toolbar.js";
const entry_format = "    .{{ .path = \"{s}\", .data = @embedFile(\"{s}\") }},\n";

pub const Interactive = struct {
    module: *std.Build.Module,
    classes: std.Build.LazyPath,
    stores: std.Build.LazyPath,
};

/// `interactive/*.ptsx` through pjsx_gen: the lowered render modules, their class manifest
/// and the client stores. An app without the folder gets all three empty.
pub fn interactive(
    builder: *std.Build,
    runtime: *std.Build.Module,
    pjsx_gen: *std.Build.Step.Compile,
    app_dir: []const u8,
    placeholders: *std.Build.Step.WriteFile,
) Interactive {
    std.debug.assert(app_dir.len > 0);
    std.debug.assert(runtime.root_source_file != null);

    const dir = builder.pathJoin(&.{ app_dir, "interactive" });
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

    run.addDirectoryArg(builder.path(dir));
    run.addArg(builder.pathFromRoot("../ui/src/components"));
    run.addArg(builder.pathFromRoot("../icons/icons"));

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

/// The file at `app_dir/rel` when the app has it, else `fallback` written to the cache.
pub fn optional_file(
    builder: *std.Build,
    placeholders: *std.Build.Step.WriteFile,
    app_dir: []const u8,
    rel: []const u8,
    fallback: []const u8,
) std.Build.LazyPath {
    std.debug.assert(rel.len > 0);
    std.debug.assert(app_dir.len > 0);

    const path = builder.pathJoin(&.{ app_dir, rel });

    if (builder.build_root.handle.access(builder.graph.io, path, .{})) |_| {
        return builder.path(path);
    } else |_| {
        return placeholders.add(std.fs.path.basename(rel), fallback);
    }
}

/// `<app>/**/*.publr` as one generated module: a `File` per template with its app-relative
/// path and text. `public/` and `interactive/` are not templates. An app with none (only
/// middleware) has an empty table.
pub fn templates(builder: *std.Build, app_dir: []const u8) *std.Build.Module {
    std.debug.assert(app_dir.len > 0);

    var source: std.Io.Writer.Allocating = .init(builder.allocator);
    const writer = &source.writer;
    const files = builder.addWriteFiles();
    var count: u32 = 0;

    write_header(writer, app_dir);

    for (files_under(builder, app_dir, ".publr")) |path| {
        const rel = path[app_dir.len + 1 ..];
        const top = rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse 0];

        if (top.len == 0) {
            diagnostic.fail("{s} sits at the app's root; a template lives in a folder", .{rel});
        }

        if (std.mem.eql(u8, top, "public") or std.mem.eql(u8, top, "interactive")) {
            continue;
        }

        write_entry(builder, writer, files, rel, path, count);
        count += 1;
    }

    writer.writeAll("};\n") catch diagnostic.fail("build input: out of memory", .{});

    return module_of(builder, files, source.written());
}

/// Only generated client code is embedded. Public files are copied at build time of the
/// site and never enter the compiler cache or the generated-artifact fingerprint.
pub fn assets(
    builder: *std.Build,
    app_dir: []const u8,
    stores: std.Build.LazyPath,
) *std.Build.Module {
    std.debug.assert(client_files.names.len > 0);
    std.debug.assert(app_dir.len > 0);

    var source: std.Io.Writer.Allocating = .init(builder.allocator);
    const writer = &source.writer;
    const files = builder.addWriteFiles();
    var count: u32 = 0;

    write_header(writer, app_dir);
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

    writer.print(entry_format, .{ "stores.js", stores_name }) catch
        diagnostic.fail("build input: out of memory", .{});
    _ = files.addCopyFile(stores, stores_name);
    writer.writeAll("};\n") catch diagnostic.fail("build input: out of memory", .{});

    return module_of(builder, files, source.written());
}

/// The table's opening, naming its app: two apps' tables are never the same file.
fn write_header(writer: *std.Io.Writer, app_dir: []const u8) void {
    std.debug.assert(writer.end == 0);
    std.debug.assert(app_dir.len > 0);

    writer.print("// {s}\n", .{app_dir}) catch diagnostic.fail("build input: out of memory", .{});
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

    writer.print(entry_format, .{ rel, import_name }) catch
        diagnostic.fail("build input: out of memory", .{});
    _ = files.addCopyFile(builder.path(path), import_name);
}

/// The generated table as a module: `files.zig` beside the copied files, so every
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

/// Every file with `extension` under `dir`, as build-root-relative paths with forward
/// slashes, sorted; none when the folder does not exist.
pub fn files_under(builder: *std.Build, dir: []const u8, extension: []const u8) []const []const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(extension.len > 0);

    const io = builder.graph.io;
    const opened = builder.build_root.handle.openDir(io, dir, .{ .iterate = true });
    var handle = opened catch |err| return missing_or_fail(dir, err);
    defer handle.close(io);
    var walker = handle.walk(builder.allocator) catch
        diagnostic.fail("build input: out of memory", .{});
    defer walker.deinit();
    var found: std.ArrayList([]const u8) = .empty;

    while (walker.next(io) catch diagnostic.fail("cannot walk {s}", .{dir})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, extension)) {
            continue;
        }

        if (std.mem.startsWith(u8, entry.basename, ".")) {
            continue;
        }

        const path = builder.pathJoin(&.{ dir, builder.dupe(entry.path) });

        found.append(builder.allocator, path) catch
            diagnostic.fail("build input: out of memory", .{});
    }

    std.mem.sort([]const u8, found.items, {}, less_than);

    return found.items;
}

/// No folder is no files; anything else stops the build.
fn missing_or_fail(dir: []const u8, err: anyerror) []const []const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    if (err == error.FileNotFound) {
        return &.{};
    }

    diagnostic.fail("cannot read {s}: {s}", .{ dir, @errorName(err) });
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
