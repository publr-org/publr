const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const embed = @import("apps/embed.zig");

pub const dir_default = "sandboxed-plugins";
/// The plugins core's tests and smoke install.
pub const fixture_dir = "fixtures/sandboxed-plugins";
pub const sandboxed_plugins_max: u32 = 64;
pub const name_len_max: u32 = 32;

/// The root a plugin is built from for the sandbox: its exports, generated from its
/// declarations, and the plugin itself as `Plugin`, which the SDK checks its calls against.
pub const guest_root_source =
    \\pub const Plugin = @import("plugin");
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

/// `zig build sandboxed-plugins`: the plugins under `-Dsandboxed-plugins` (default
/// `sandboxed-plugins/`) built into `zig-out/sandboxed-plugins/<name>.wasm`.
pub fn add_step(builder: *std.Build, publr: *std.Build.Step.Compile, dir: []const u8) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(dir.len > 0);

    const step = builder.step(
        "sandboxed-plugins",
        "Build the plugins under -Dsandboxed-plugins for the sandbox",
    );
    const built = add(builder, publr, dir);

    for (built.names, built.files) |name, file| {
        const install = builder.addInstallFileWithDir(
            file,
            .{ .custom = "sandboxed-plugins" },
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

        // A folder argument is cached by its path alone: each source file is an input.
        for (embed.files_under(builder, source, ".zig")) |path| {
            run.addFileInput(builder.path(path));
        }
    }

    return .{ .names = names, .files = files };
}

/// The SDK a plugin is built against, as `publr plugin build` finds it: `src/` (the Zig
/// files only), `stubs/` and `guest.zig`, packed by `pack` into one archive.
pub fn sdk_archive(builder: *std.Build, pack: *std.Build.Step.Compile) std.Build.LazyPath {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(stub_imports.len > 0);

    const stubs = stubs_of(builder);
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

    return archive;
}

/// What the plugin SDK imports but never reaches from inside the sandbox: an empty module for
/// each, and the one declaration it does reach (the storage error names, in `sqlite`).
fn stubs_of(builder: *std.Build) *std.Build.Step.WriteFile {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(stub_imports.len > 0);

    const files = builder.addWriteFiles();

    _ = files.add("publr_sqlite.zig", "pub const Error = error{ Sqlite, Constraint, " ++
        "Busy, ReadOnly, OutOfMemory };\n");

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
    var root = builder.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch {
        const optional = std.mem.eql(u8, dir, dir_default) or std.mem.eql(u8, dir, fixture_dir) or
            std.mem.endsWith(u8, dir, "/" ++ dir_default);

        if (!optional) {
            diagnostic.fail("-Dsandboxed-plugins: no folder at {s}", .{dir});
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
            diagnostic.fail("-Dsandboxed-plugins: more than {d} plugins", .{sandboxed_plugins_max});
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
