const std = @import("std");
const repository = @import("repository.zig");
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
    \\pub const Plugin = @import("p").plugin.Bind(@import("plugin"), @import("plugin_docs"));
    \\
    \\comptime {
    \\    @import("p").plugin.guest.export_all(Plugin);
    \\    @import("p").published.check(Plugin, &@import("plugin_published").all);
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
/// built into `zig-out/sandboxed-plugins/<name>.wasm`. Answers every module as built for it.
pub fn add_step(
    builder: *std.Build,
    publr: *std.Build.Step.Compile,
    dir: []const u8,
    native: native_plugins.Native,
) SandboxedPlugins {
    std.debug.assert(builder.root.sub_path.len == 0);
    std.debug.assert(dir.len > 0);

    const step = builder.step(
        "sandboxed-plugins",
        "Build the plugins under -Dplugins that are not compiled in, for the sandbox",
    );
    const built = add_built(builder, publr, dir, .llvm);

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

    return built;
}

/// Each plugin under `dir` built as the `publr` command builds one: `publr` (just built)
/// prepares it, the Zig running this build compiles it for wasm32, `publr` checks the module
/// (`plugin_compile.zig`). Zig's own backend, as the command's compiler has no other.
pub fn add(builder: *std.Build, publr: *std.Build.Step.Compile, dir: []const u8) SandboxedPlugins {
    return add_built(builder, publr, dir, .self_hosted);
}

/// Which code generator compiles a module: Zig's own, as a person's `publr plugin build`
/// has it, or LLVM optimising for speed, for the modules Publr ships (`zig build
/// sandboxed-plugins`): the same source, a few times fewer instructions in the sandbox.
pub const Backend = enum { self_hosted, llvm };

fn add_built(
    builder: *std.Build,
    publr: *std.Build.Step.Compile,
    dir: []const u8,
    backend: Backend,
) SandboxedPlugins {
    std.debug.assert(dir.len > 0);
    std.debug.assert(builder.root.sub_path.len == 0);

    const names = discover(builder, dir);
    const files = builder.allocator.alloc(std.Build.LazyPath, names.len) catch @panic("OOM");
    const cache = repository.path(builder, ".zig-cache/publr-plugins");
    const compiler = builder.addExecutable(.{
        .name = "plugin_compile",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("build/plugin_compile.zig"),
            .target = builder.graph.host,
            .optimize = .debug,
        }),
    });

    // Each after the ones it builds against (`builds_with.zon`), with their modules, at any
    // depth: a round builds every plugin whose own are built.
    const done = builder.allocator.alloc(bool, names.len) catch @panic("OOM");
    var left: u32 = @intCast(names.len);
    var rounds: u32 = 0;

    @memset(done, false);

    while (left > 0) : (rounds += 1) {
        if (rounds == names.len) {
            diagnostic.fail("builds_with.zon: the plugins under {s} build against each other " ++
                "in a loop", .{dir});
        }

        left -= add_round(builder, .{
            .publr = publr,
            .backend = backend,
            .compiler = compiler,
            .dir = dir,
            .cache = cache,
            .names = names,
            .files = files,
            .done = done,
        });
    }

    return .{
        .names = names,
        .files = files,
    };
}

const Round = struct {
    publr: *std.Build.Step.Compile,
    backend: Backend,
    compiler: *std.Build.Step.Compile,
    dir: []const u8,
    cache: []const u8,
    names: []const []const u8,
    files: []std.Build.LazyPath,
    done: []bool,
};

/// Builds every plugin not built yet whose plugins to build against are: how many.
fn add_round(builder: *std.Build, round: Round) u32 {
    const names = round.names;
    const files = round.files;
    var made: u32 = 0;

    std.debug.assert(names.len == round.done.len);

    for (names, 0..) |name, index| {
        const source = builder.pathJoin(&.{ round.dir, name });
        const with = beside(builder, names, builds_with(builder, source));

        if (round.done[index] or !all_done(names, round.done, with, name)) {
            continue;
        }

        round.done[index] = true;
        made += 1;

        const compiler = round.compiler;
        const publr = round.publr;
        const cache = round.cache;

        const run = builder.addRunArtifact(compiler);

        run.addArtifactArg(publr);
        run.addArgs(&.{ builder.graph.zig_exe, cache, name });
        run.addDirectoryArg(builder.path(source));
        files[index] = run.addOutputFileArg(builder.fmt("{s}.wasm", .{name}));

        for (with) |other| {
            run.addArg("--with");
            run.addFileArg(built_before(names, files[0..names.len], other, name));
        }

        if (round.backend == .llvm) {
            run.addArg("--llvm");
        }

        // What a fixture leaves out of the sandbox is a notice for plugin authors; these
        // leave it out on purpose. A failed build still fails the step, on its exit code.
        _ = run.captureStdErr(.{});

        // A folder argument is cached by its path alone: each source file is an input, its
        // components and interactive components too.
        for ([_][]const u8{ ".zig", ".publr", ".ptsx", ".po", ".svg" }) |extension| {
            for (embed.files_under(builder, source, extension)) |path| {
                run.addFileInput(builder.path(path));
            }
        }
    }

    return made;
}

/// Whether each plugin `name` builds against is built already.
fn all_done(
    names: []const []const u8,
    done: []const bool,
    with: []const []const u8,
    name: []const u8,
) bool {
    std.debug.assert(names.len == done.len);
    std.debug.assert(name.len > 0);

    for (with) |other| {
        const found = for (names, done) |candidate, built| {
            if (std.mem.eql(u8, candidate, other)) {
                break built;
            }
        } else diagnostic.fail("{s}/builds_with.zon names {s}, which is not beside it", .{
            name,
            other,
        });

        if (!found) {
            return false;
        }
    }

    return true;
}

/// The plugins of `with` that are beside it, among `names`: one it works with only when present
/// (`compatible_with`) is built without when absent; one it depends on and imports fails its
/// own build, naming it.
fn beside(
    builder: *std.Build,
    names: []const []const u8,
    with: []const []const u8,
) []const []const u8 {
    std.debug.assert(names.len > 0);
    std.debug.assert(with.len < 1 << 10);

    var kept: std.ArrayList([]const u8) = .empty;

    for (with) |other| {
        for (names) |candidate| {
            if (std.mem.eql(u8, candidate, other)) {
                kept.append(builder.allocator, other) catch @panic("OOM");
                break;
            }
        }
    }

    return kept.items;
}

/// The plugins `<source>/builds_with.zon` names (`.{ "parcels" }`), whose published
/// interfaces it builds against; none without one.
fn builds_with(builder: *std.Build, source: []const u8) []const []const u8 {
    std.debug.assert(source.len > 0);

    const path = builder.pathJoin(&.{ source, "builds_with.zon" });
    const io = builder.graph.io;
    const limit: std.Io.Limit = .limited(1 << 12);
    const handle = repository.dir(builder);
    const text = handle.readFileAllocOptions(io, path, builder.allocator, limit, .of(u8), 0) catch
        return &.{};

    const List = []const []const u8;

    var diagnostics: std.zon.parse.Diagnostics = undefined;

    return std.zon.parse.fromSlice(List, .{
        .gpa = builder.allocator,
        .arena = builder.allocator,
        .source = text,
        .diagnostics = &diagnostics,
    }) catch
        diagnostic.fail("{s}: a list of plugin folders, `.{{ \"parcels\" }}`", .{path});
}

/// The module built from the folder `other`, which `name` builds against.
fn built_before(
    names: []const []const u8,
    files: []const std.Build.LazyPath,
    other: []const u8,
    name: []const u8,
) std.Build.LazyPath {
    std.debug.assert(names.len == files.len);
    std.debug.assert(name.len > 0);

    for (names, files) |candidate, file| {
        if (std.mem.eql(u8, candidate, other)) {
            return file;
        }
    }

    diagnostic.fail("{s}/builds_with.zon names {s}, which is not beside it", .{ name, other });
}

/// The SDK a plugin is built against, as `publr plugin prepare` writes it: `src/` (the Zig
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
    std.debug.assert(builder.root.sub_path.len == 0);
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
        .cwd_relative = repository.path(builder, path),
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
    std.debug.assert(builder.root.sub_path.len == 0);

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
                .cwd_relative = repository.path(builder, path),
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
    std.debug.assert(builder.root.sub_path.len == 0);
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
    "publr_http",  "publr_auth", "publr_deps", "publr_jit",    "native_plugins",
    "views",       "runtime",    "apps",       "apps_options", "publr_wasm",
    "sdk_options",
};

fn discover(builder: *std.Build, dir: []const u8) []const []const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(sandboxed_plugins_max > 0);

    const io = builder.graph.io;
    var root = repository.dir(builder).openDir(io, dir, .{
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

    // A plugin's folder added or removed configures the build again.
    repository.read_under(builder, dir, .folder);

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
