const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const embed = @import("apps/embed.zig");
const native_plugins = @import("native_plugins.zig");

pub const dir_default = "plugins";
/// The test inputs core's tests, parity and smoke build and install: not plugins of the
/// product, the modules the sandbox is tested with.
pub const fixture_dir = "src/server/sandboxed_plugins/testdata";
pub const sandboxed_plugins_max: u32 = 64;
pub const name_len_max: u32 = 32;

/// The root a plugin is built from for the sandbox: its exports, generated from its
/// declarations, and the plugin itself as `Plugin`, which the SDK checks its calls against.
pub const guest_root_source =
    \\pub const Plugin = @import("publr").plugin.Bind(@import("plugin"), @import("plugin_docs"));
    \\
    \\comptime {
    \\    @import("publr").plugin.guest.export_all(Plugin);
    \\}
    \\
;

/// Every plugin under a folder, built for the sandbox by `publr plugin build` exactly as
/// its users build it: the same source a native plugin has, its manifest in the module.
pub const SandboxedPlugins = struct {
    names: []const []const u8,
    files: []const std.Build.LazyPath,

    /// The module built from the folder called `name`.
    pub fn file_of(built: SandboxedPlugins, name: []const u8) std.Build.LazyPath {
        std.debug.assert(name.len > 0);
        std.debug.assert(built.names.len == built.files.len);

        for (built.names, built.files) |candidate, file| {
            if (std.mem.eql(u8, candidate, name)) {
                return file;
            }
        }

        @panic("no such fixture plugin");
    }
};

/// `zig build sandboxed-plugins`: the plugins under `-Dplugins` that are not compiled in,
/// built into `zig-out/sandboxed-plugins/<name>.wasm`.
pub fn add_step(
    builder: *std.Build,
    publr: *std.Build.Step.Compile,
    dir: []const u8,
    native: native_plugins.Native,
) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(dir.len > 0);

    const step = builder.step(
        "sandboxed-plugins",
        "Build the plugins under -Dplugins that are not compiled in, for the sandbox",
    );
    const built = add(builder, publr, dir);

    for (built.names, built.files) |name, file| {
        if (native_plugins.is_native(native, name)) {
            continue;
        }

        const install = builder.addInstallFileWithDir(
            file,
            .{
                .custom = "sandboxed-plugins",
            },
            builder.fmt("{s}.wasm", .{name}),
        );

        step.dependOn(&install.step);
    }
}

/// Each plugin under `dir` built by `publr plugin build --out`, with the compiler the
/// `publr` just built carries, written out into the build cache rather than the user's.
pub fn add(builder: *std.Build, publr: *std.Build.Step.Compile, dir: []const u8) SandboxedPlugins {
    std.debug.assert(dir.len > 0);
    std.debug.assert(builder.build_root.path != null);

    const names = discover(builder, dir);
    const files = builder.allocator.alloc(std.Build.LazyPath, names.len) catch @panic("OOM");
    const cache = builder.pathFromRoot(".zig-cache/publr-toolchain");

    for (names, 0..) |name, index| {
        const source = builder.pathJoin(&.{ dir, name });
        const run = builder.addRunArtifact(publr);

        run.addArgs(&.{ "plugin", "build", "--name", name, "--dir" });
        run.addDirectoryArg(builder.path(source));
        run.addArg("--out");
        files[index] = run.addOutputFileArg(builder.fmt("{s}.wasm", .{name}));
        run.setEnvironmentVariable("PUBLR_CACHE_DIR", cache);
        // What a fixture leaves out of the sandbox is a notice for plugin authors; these
        // leave it out on purpose. A failed build still fails the step, on its exit code.
        _ = run.captureStdErr(.{});

        // A folder argument is cached by its path alone: each source file is an input.
        for (embed.files_under(builder, source, ".zig")) |path| {
            run.addFileInput(builder.path(path));
        }
    }

    return .{
        .names = names,
        .files = files,
    };
}

/// The SDK a plugin is built against, as `publr plugin build` finds it: `src/` (the Zig
/// files only), `stubs/` and `guest.zig`, packed by `pack` into one archive. For a plugin's
/// views: `ws/`, the admin's views, the design system and the icons as the lowering reads
/// them; `ui/views` (the generated Zig, for the real props, and the stand-ins);
/// `ui/request.zig` and a plain `ui/class_merge.zig`; `pjsx/`, the compiler's source, for its
/// render runtime; and `tools/pjsx_gen`, the lowering, built for this binary's target.
pub fn sdk_archive(
    builder: *std.Build,
    pack: *std.Build.Step.Compile,
    limits_source: []const u8,
    parts: ViewsParts,
) std.Build.LazyPath {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(limits_source.len > 0);

    const stubs = stubs_of(builder);

    // Not a stub: a plugin built here holds what this binary's entries and types may.
    _ = stubs.add("limits_options.zig", limits_source);
    const guest = builder.addWriteFiles().add("guest.zig", guest_root_source);
    const run = builder.addRunArtifact(pack);
    const archive = run.addOutputFileArg("sdk.tar.gz");

    run.addDecoratedDirectoryArg("src/=", builder.path("src"), ":.zig");

    // A folder argument is cached by its path alone: each file is an input, so a change
    // to the SDK packs it again.
    for (embed.files_under(builder, "src", ".zig")) |path| {
        run.addFileInput(builder.path(path));
    }

    run.addPrefixedDirectoryArg("stubs/=", stubs.getDirectory());
    run.addPrefixedFileArg("guest.zig=", guest);
    add_views_parts(builder, run, parts);

    return archive;
}

/// A folder beside this repository in the workspace.
fn sibling(builder: *std.Build, path: []const u8) std.Build.LazyPath {
    std.debug.assert(std.mem.startsWith(u8, path, "../"));

    return .{
        .cwd_relative = builder.pathFromRoot(path),
    };
}

/// What installed plugins' views are lowered and built with.
pub const ViewsParts = struct {
    /// The admin's generated views and the stand-ins.
    views: std.Build.LazyPath,
    /// The lowering, an executable.
    lowering: std.Build.LazyPath,
};

/// What lowering and building an installed plugin's views takes, into the archive.
fn add_views_parts(builder: *std.Build, run: *std.Build.Step.Run, parts: ViewsParts) void {
    std.debug.assert(builder.build_root.path != null);

    const views = parts.views;
    const pjsx = builder.dependency("pjsx", .{});
    const plain = builder.addWriteFiles().add("class_merge.zig", class_merge_plain);

    run.addDecoratedDirectoryArg("ui/views/=", views, ":.zig");
    // The sources the lowering reads, laid out as in the workspace, so the imports between
    // the admin, the design system and the icons resolve as they do here.
    run.addDecoratedDirectoryArg("ws/publr/ui/=", builder.path("ui"), ":.ptsx");
    run.addDecoratedDirectoryArg("ws/ui/src/=", sibling(builder, "../ui/src"), ":.ptsx");
    run.addDecoratedDirectoryArg("ws/ui/src/=", sibling(builder, "../ui/src"), ":.ts");
    run.addDecoratedDirectoryArg("ws/icons/src/=", sibling(builder, "../icons/src"), ":.ts");
    run.addDecoratedDirectoryArg("ws/icons/icons/=", sibling(builder, "../icons/icons"), ":.svg");
    run.addPrefixedFileArg("ui/request.zig=", builder.path("ui/request.zig"));
    run.addPrefixedFileArg("ui/class_merge.zig=", plain);
    run.addPrefixedFileArg("+tools/pjsx_gen=", parts.lowering);
    run.addDecoratedDirectoryArg("pjsx/=", pjsx.path("src"), ":.zig");

    // A folder argument is cached by its path alone: each file is an input.
    const inputs = [_][2][]const u8{
        .{ "ui", ".ptsx" },
        .{ "ui", ".zig" },
        .{ "../ui/src", ".ptsx" },
        .{ "../ui/src", ".ts" },
        .{ "../icons/src", ".ts" },
        .{ "../icons/icons", ".svg" },
        .{ "../pjsx/src", ".zig" },
    };

    for (inputs) |input| {
        for (embed.files_under(builder, input[0], input[1])) |path| {
            run.addFileInput(.{
                .cwd_relative = builder.pathFromRoot(path),
            });
        }
    }
}

/// The class merge an installed plugin's views write with: the parts as they are, joined.
/// A plugin's own markup takes no classes (the lowering refuses them); what the host draws
/// is merged by the host's.
const class_merge_plain =
    \\const std = @import("std");
    \\
    \\pub fn merge_classes(
    \\    arena: std.mem.Allocator,
    \\    parts: []const []const u8,
    \\    options: anytype,
    \\) ![]const u8 {
    \\    _ = options;
    \\
    \\    return std.mem.join(arena, " ", parts);
    \\}
    \\
;

/// What the plugin SDK imports but never reaches from inside the sandbox: an empty module for
/// each, and the one declaration it does reach (the storage error names, in `sqlite`).
fn stubs_of(builder: *std.Build) *std.Build.Step.WriteFile {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(stub_imports.len > 0);

    const files = builder.addWriteFiles();

    _ = files.add("publr_sqlite.zig", "pub const Error = error{ Sqlite, Constraint, " ++
        "Busy, ReadOnly, OutOfMemory, Interrupted, TooBig };\n");

    // Not a stub: a model provider is a plugin, and builds against the contract itself.
    const publr_ai = builder.dependency("publr_ai", .{});

    _ = files.addCopyFile(publr_ai.namedLazyPath("amalgamation"), "publr_ai.zig");

    // Not a stub either: `publr.text` is the text library itself.
    const publr_text = builder.dependency("publr_text", .{});

    _ = files.addCopyFile(publr_text.namedLazyPath("amalgamation"), "publr_text.zig");

    for (stub_imports) |name| {
        _ = files.add(builder.fmt("{s}.zig", .{name}), "pub const all = .{};\n");
    }

    return files;
}

const stub_imports = [_][]const u8{
    "publr_http", "publr_auth",        "publr_deps", "publr_jit",    "native_plugins",
    "views",      "runtime",           "apps",       "apps_options", "publr_wasm",
    "publr_zig",  "toolchain_options",
};

fn discover(builder: *std.Build, dir: []const u8) []const []const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(sandboxed_plugins_max > 0);

    const io = builder.graph.io;
    var root = builder.build_root.handle.openDir(io, dir, .{
        .iterate = true,
    }) catch {
        const optional = std.mem.eql(u8, dir, dir_default) or std.mem.eql(u8, dir, fixture_dir) or
            std.mem.endsWith(u8, dir, "/" ++ dir_default);

        if (!optional) {
            diagnostic.fail("-Dplugins: no folder at {s}", .{dir});
        }

        return &.{};
    };
    defer root.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = root.iterate();

    while (iterator.next(io) catch null) |entry| {
        const folder = entry.kind == .directory or entry.kind == .sym_link;

        if (!folder or entry.name.len > name_len_max) {
            continue;
        }

        root.access(io, builder.fmt("{s}/main.zig", .{entry.name}), .{}) catch continue;

        if (names.items.len == sandboxed_plugins_max) {
            diagnostic.fail("-Dplugins: more than {d} plugins", .{sandboxed_plugins_max});
        }

        names.append(builder.allocator, builder.dupe(entry.name)) catch @panic("OOM");
    }

    std.mem.sort([]const u8, names.items, {}, less_than);

    return names.items;
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    std.debug.assert(left.len > 0);
    std.debug.assert(right.len > 0);

    return std.mem.lessThan(u8, left, right);
}
