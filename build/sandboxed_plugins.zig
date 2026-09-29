const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const dir_default = "sandboxed-plugins";
/// The plugins core's tests and smoke install.
pub const fixture_dir = "fixtures/sandboxed-plugins";
pub const sandboxed_plugins_max: u32 = 64;
pub const name_len_max: u32 = 32;
/// A plugin in the sandbox has 16 MiB in all by default: a small stack leaves it the rest.
pub const stack_bytes: u32 = 256 << 10;

const guest_root_source =
    \\comptime {
    \\    @import("publr").plugin.guest.export_all(@import("plugin"));
    \\}
    \\
;

const tool_root_source =
    \\const std = @import("std");
    \\const manifest = @import("publr").plugin.plugin_manifest;
    \\const section = @import("section");
    \\
    \\/// Copies the module and appends the plugin's manifest as its custom section.
    \\pub fn main(init: std.process.Init) !void {
    \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
    \\    const cwd = std.Io.Dir.cwd();
    \\    const module = try cwd.readFileAlloc(init.io, args[1], init.gpa, .limited(64 << 20));
    \\    defer init.gpa.free(module);
    \\
    \\    var json: std.Io.Writer.Allocating = .init(init.gpa);
    \\    defer json.deinit();
    \\    try manifest.write(@import("plugin"), &json.writer);
    \\
    \\    var out: std.Io.Writer.Allocating = .init(init.gpa);
    \\    defer out.deinit();
    \\    try out.writer.writeAll(module);
    \\    try section.write(&out.writer, manifest.section_name, json.written());
    \\    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = out.written() });
    \\}
    \\
;

/// Every plugin under `dir` built as an installed plugin: the same source a native plugin
/// has, compiled for the sandbox, its manifest in the module's `publr` section.
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
/// `sandboxed-plugins/`) built into
/// `zig-out/plugins/<name>.wasm`.
pub fn add_step(builder: *std.Build, stubs: Stubs, dir: []const u8) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(dir.len > 0);
    const step = builder.step(
        "sandboxed-plugins",
        "Build the plugins under -Dsandboxed-plugins for the sandbox",
    );
    const built = add(builder, dir, stubs);

    for (built.names, built.files) |name, file| {
        const install = builder.addInstallFileWithDir(
            file,
            .{ .custom = "sandboxed-plugins" },
            builder.fmt("{s}.wasm", .{name}),
        );

        step.dependOn(&install.step);
    }
}

pub fn add(builder: *std.Build, dir: []const u8, stubs: Stubs) SandboxedPlugins {
    std.debug.assert(dir.len > 0);
    std.debug.assert(builder.build_root.path != null);

    const names = discover(builder, dir);
    const files = builder.allocator.alloc(std.Build.LazyPath, names.len) catch @panic("OOM");
    const guest_target = builder.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const guest_publr = sdk_module(builder, guest_target, .ReleaseSmall, stubs);
    const tool_publr = sdk_module(builder, builder.graph.host, .Debug, stubs);

    for (names, 0..) |name, index| {
        const source = builder.path(builder.fmt("{s}/{s}/main.zig", .{ dir, name }));
        const module = guest_module(builder, guest_publr, source);
        const tool = manifest_tool(builder, tool_publr, source, stubs.section);
        const run = builder.addRunArtifact(tool);

        run.addFileArg(module.getEmittedBin());
        files[index] = run.addOutputFileArg(builder.fmt("{s}.wasm", .{name}));
    }

    return .{ .names = names, .files = files };
}

/// What the plugin SDK imports but never reaches from inside the sandbox: an empty module for
/// each, and the one declaration it does reach (the storage error names, in `sqlite`).
pub const Stubs = struct {
    files: *std.Build.Step.WriteFile,
    section: std.Build.LazyPath,
};

pub fn stubs_of(builder: *std.Build, wasm_dependency: *std.Build.Dependency) Stubs {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(stub_imports.len > 0);

    const files = builder.addWriteFiles();

    _ = files.add("publr_sqlite.zig", "pub const Error = error{ Sqlite, Constraint, " ++
        "Busy, ReadOnly, OutOfMemory };\n");

    for (stub_imports) |name| {
        _ = files.add(builder.fmt("{s}.zig", .{name}), "pub const all = .{};\n");
    }

    return .{ .files = files, .section = wasm_dependency.path("src/section.zig") };
}

const stub_imports = [_][]const u8{
    "publr_http", "publr_auth", "publr_deps", "publr_jit",    "native_plugins",
    "views",      "runtime",    "apps",       "apps_options", "publr_wasm",
};

fn sdk_module(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    stubs: Stubs,
) *std.Build.Module {
    std.debug.assert(stub_imports.len > 0);
    std.debug.assert(builder.build_root.path != null);

    const module = builder.createModule(.{
        .root_source_file = builder.path("src/publr.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addAnonymousImport("publr_sqlite", .{
        .root_source_file = stubs.files.getDirectory().path(builder, "publr_sqlite.zig"),
    });

    for (stub_imports) |name| {
        module.addAnonymousImport(name, .{
            .root_source_file = stubs.files.getDirectory().path(builder, builder.fmt(
                "{s}.zig",
                .{name},
            )),
        });
    }

    return module;
}

fn guest_module(
    builder: *std.Build,
    publr: *std.Build.Module,
    source: std.Build.LazyPath,
) *std.Build.Step.Compile {
    std.debug.assert(publr.resolved_target.?.result.cpu.arch == .wasm32);
    std.debug.assert(stack_bytes > 0);

    const plugin = builder.createModule(.{
        .root_source_file = source,
        .target = publr.resolved_target,
        .optimize = publr.optimize,
    });

    plugin.addImport("publr", publr);

    const root = builder.addWriteFiles().add("guest.zig", guest_root_source);
    const module = builder.addExecutable(.{
        .name = "plugin",
        .root_module = builder.createModule(.{
            .root_source_file = root,
            .target = publr.resolved_target,
            .optimize = publr.optimize,
            .imports = &.{
                .{ .name = "publr", .module = publr },
                .{ .name = "plugin", .module = plugin },
            },
        }),
    });

    module.entry = .disabled;
    module.rdynamic = true;
    module.stack_size = stack_bytes;

    return module;
}

fn manifest_tool(
    builder: *std.Build,
    publr: *std.Build.Module,
    source: std.Build.LazyPath,
    section: std.Build.LazyPath,
) *std.Build.Step.Compile {
    std.debug.assert(publr.resolved_target != null);
    std.debug.assert(tool_root_source.len > 0);

    const plugin = builder.createModule(.{
        .root_source_file = source,
        .target = publr.resolved_target,
        .optimize = publr.optimize,
    });

    plugin.addImport("publr", publr);

    const root = builder.addWriteFiles().add("manifest_tool.zig", tool_root_source);

    return builder.addExecutable(.{
        .name = "plugin-manifest",
        .root_module = builder.createModule(.{
            .root_source_file = root,
            .target = publr.resolved_target,
            .optimize = publr.optimize,
            .imports = &.{
                .{ .name = "publr", .module = publr },
                .{ .name = "plugin", .module = plugin },
                .{ .name = "section", .module = builder.createModule(.{
                    .root_source_file = section,
                }) },
            },
        }),
    });
}

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
