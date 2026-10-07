//! `publr plugin build`: a sandboxed plugin's source built into its module by the compiler
//! the binary carries, its manifest read from the module itself and written into its
//! `publr` section, then added through the plugin operations: enabled when new, applied as
//! the next version when it is already there. What it asks for is granted by tier, as when
//! an administrator adds it; high requests wait for approval.
const std = @import("std");
const wasm = @import("publr_wasm");
const toolchain = @import("toolchain.zig");
const invoke = @import("sandboxed_plugins/invoke.zig");
const wire = @import("../sdk/plugin/wire.zig");
const plugin_manifest = @import("../sdk/plugin/manifest.zig");
const report = @import("../lib/report.zig");
const operator = @import("operator.zig");

const module_bytes_max: u32 = 16 << 20;
const heap_bytes: u32 = 32 << 20;
const manifest_instructions_max: u64 = 400_000_000;
const stubs_max: u32 = 32;

const Request = struct {
    name: []const u8,
    dir: []const u8,
    /// Only build, into this file: nothing is installed.
    out: ?[]const u8 = null,
};

pub fn run(init: std.process.Init, db_path: [:0]const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);

    const request = parse(init.arena.allocator(), args) orelse {
        report.err("usage: publr plugin build --name <name> [--dir <folder>] [--out <file>]", .{});
        return 2;
    };
    const tools = toolchain.unpack(init) catch |err| {
        const message = "publr plugin build: the compiler is not available";

        report.err_reason(@errorName(err), message, .{});
        return 1;
    };
    const data_dir = std.fs.path.dirname(db_path) orelse ".";
    const built = request.out orelse try std.fmt.allocPrint(
        init.arena.allocator(),
        "{s}/builds/{s}.wasm",
        .{ data_dir, request.name },
    );

    std.debug.assert(tools.sdk.len > 0);

    const main_path = try std.fs.path.join(init.arena.allocator(), &.{ request.dir, "main.zig" });

    std.Io.Dir.cwd().access(init.io, main_path, .{}) catch {
        report.err("publr plugin build: no plugin at {s}", .{main_path});
        return 1;
    };

    if (try compile(init, tools, request, built) != 0) {
        return 1;
    }

    const manifest = try write_manifest(init, built);

    try warn_left_out(init, request.name, manifest);

    if (request.out != null) {
        return 0;
    }

    return install(init, db_path, request.name, built);
}

/// `--name <name>`, `--dir <folder>` (default `plugins/<name>`), whose `main.zig`
/// is the plugin, and `--out <file>` to only build it.
fn parse(arena: std.mem.Allocator, args: []const []const u8) ?Request {
    std.debug.assert(args.len < 1 << 16);

    var name: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var index: u32 = 0;

    while (index + 1 < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--name")) {
            name = args[index + 1];
        } else if (std.mem.eql(u8, args[index], "--dir")) {
            dir = args[index + 1];
        } else if (std.mem.eql(u8, args[index], "--out")) {
            out = args[index + 1];
        } else {
            return null;
        }
    }

    if (index != args.len or name == null or name.?.len == 0) {
        return null;
    }

    const folder = dir orelse std.fmt.allocPrint(arena, "plugins/{s}", .{name.?}) catch {
        return null;
    };

    std.debug.assert(folder.len > 0);

    return .{ .name = name.?, .dir = folder, .out = out };
}

/// Runs the compiler on the plugin, its messages going to this process's stderr as they are;
/// its exit code.
fn compile(
    init: std.process.Init,
    tools: toolchain.Toolchain,
    request: Request,
    out_path: []const u8,
) !u8 {
    std.debug.assert(out_path.len > 0);
    std.debug.assert(request.dir.len > 0);

    const argv = try compile_argv(init, tools, request, out_path);

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(out_path) orelse ".");

    var child = try std.process.spawn(init.io, .{ .argv = argv });

    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => |term| {
            report.err("publr plugin build: the compiler stopped: {any}", .{term});
            return 1;
        },
    };
}

/// The plugin built for the sandbox against the SDK: its root (`guest.zig`, the exports),
/// `publr` (the SDK's source) with a stub for each module only the host has, and the plugin.
fn compile_argv(
    init: std.process.Init,
    tools: toolchain.Toolchain,
    request: Request,
    out_path: []const u8,
) ![]const []const u8 {
    const arena = init.arena.allocator();
    const stubs = try stub_names(init, tools.sdk);
    const cache = try std.fs.path.join(arena, &.{ std.fs.path.dirname(tools.sdk).?, "zig-cache" });
    // `bulk_memory`: without it, Zig 0.16's wasm backend lowers `@memmove` to a forward
    // byte loop, wrong when the regions overlap upwards (an `ArrayList.insert`); with it,
    // to `memory.copy`, which is right. The sandbox runs bulk memory.
    const target = [_][]const u8{
        "-OReleaseSmall",
        "-target",
        "wasm32-freestanding",
        "-mcpu=baseline+bulk_memory",
    };
    var argv: std.ArrayList([]const u8) = .empty;

    std.debug.assert(stubs.len > 0);

    try argv.appendSlice(arena, &.{ tools.compiler, "build-exe", "--stack", "262144" });
    try argv.appendSlice(arena, &target);
    try argv.appendSlice(arena, &.{ "--dep", "publr", "--dep", "plugin" });
    try argv.append(arena, try std.fmt.allocPrint(arena, "-Mroot={s}/guest.zig", .{tools.sdk}));
    try argv.appendSlice(arena, &target);

    for (stubs) |stub| {
        try argv.appendSlice(arena, &.{ "--dep", stub });
    }

    const publr_module = try std.fmt.allocPrint(arena, "-Mpublr={s}/src/publr.zig", .{tools.sdk});

    try argv.append(arena, publr_module);

    // The plugin's own `interface.zig`, under its own name, for its own files: another
    // plugin's is never wired in (it declares the contract it uses instead).
    const interface = try std.fmt.allocPrint(arena, "{s}/interface.zig", .{request.dir});
    const has_interface = if (std.Io.Dir.cwd().access(init.io, interface, .{})) true else |_| false;

    if (has_interface) {
        try argv.appendSlice(arena, &target);
        try argv.appendSlice(arena, &.{ "--dep", "publr" });
        const module = try std.fmt.allocPrint(arena, "-M{s}={s}", .{ request.name, interface });

        try argv.append(arena, module);
    }

    try argv.appendSlice(arena, &target);
    try argv.appendSlice(arena, &.{ "--dep", "publr" });

    if (has_interface) {
        try argv.appendSlice(arena, &.{ "--dep", request.name });
    }

    try argv.append(arena, try std.fmt.allocPrint(arena, "-Mplugin={s}/main.zig", .{request.dir}));

    for (stubs) |stub| {
        const path = try std.fmt.allocPrint(arena, "-M{s}={s}/stubs/{s}.zig", .{
            stub,
            tools.sdk,
            stub,
        });

        try argv.append(arena, path);
    }

    try argv.appendSlice(arena, &.{ "--name", request.name, "-rdynamic", tools.compiler_rt });
    try argv.appendSlice(arena, &toolchain.wasm_flags);
    try argv.appendSlice(arena, &.{ "--cache-dir", cache, "--global-cache-dir", cache });
    try argv.append(arena, try std.fmt.allocPrint(arena, "-femit-bin={s}", .{out_path}));

    return argv.items;
}

/// The modules the SDK imports that only the host has, each a stub in `<sdk>/stubs/`.
fn stub_names(init: std.process.Init, sdk_dir: []const u8) ![]const []const u8 {
    const arena = init.arena.allocator();
    const stubs_path = try std.fs.path.join(arena, &.{ sdk_dir, "stubs" });
    var dir = try std.Io.Dir.cwd().openDir(init.io, stubs_path, .{ .iterate = true });
    defer dir.close(init.io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(init.io)) |entry| {
        if (names.items.len == stubs_max) {
            return error.TooManyStubs;
        }

        if (std.mem.endsWith(u8, entry.name, ".zig")) {
            try names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - 4]));
        }
    }

    std.debug.assert(names.items.len <= stubs_max);

    return names.items;
}

/// Reads the manifest by running the module's `publr_manifest` in the sandbox, with no
/// grants and nothing it could call, and writes it into the module's `publr` section.
fn write_manifest(init: std.process.Init, path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0);

    const cwd = std.Io.Dir.cwd();
    const arena = init.arena.allocator();
    const module = try cwd.readFileAlloc(init.io, path, arena, .limited(module_bytes_max));
    // WAMR rewrites the bytes it loads, so it gets a copy of its own.
    const manifest = try manifest_of(init.gpa, arena, try arena.dupe(u8, module));
    var output: std.Io.Writer.Allocating = .init(arena);

    std.debug.assert(manifest.len > 0);

    try output.writer.writeAll(module);
    try wasm.section.write(&output.writer, plugin_manifest.section_name, manifest);
    try cwd.writeFile(init.io, .{ .sub_path = path, .data = output.written() });

    return manifest;
}

/// What the plugin brings that its sandboxed build left out, said on stderr: it builds, and
/// runs without them.
fn warn_left_out(init: std.process.Init, name: []const u8, manifest: []const u8) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(manifest.len > 0);

    const Declared = struct { left_out: []const []const u8 = &.{} };
    const declared = try std.json.parseFromSliceLeaky(Declared, init.arena.allocator(), manifest, .{
        .ignore_unknown_fields = true,
    });

    if (declared.left_out.len == 0) {
        return;
    }

    std.debug.print("publr plugin build: {s} builds for the sandbox without:\n", .{name});

    for (declared.left_out) |item| {
        std.debug.print("  - {s}\n", .{item});
    }

    std.debug.print("Calls to what is left out answer unavailable; list the plugin in " ++
        "publr.zon's `.plugins.native` to compile it in with everything.\n", .{});
}

fn manifest_of(gpa: std.mem.Allocator, arena: std.mem.Allocator, module_bytes: []u8) ![]u8 {
    std.debug.assert(module_bytes.len > 0);

    const heap = try gpa.alloc(u8, heap_bytes);
    defer gpa.free(heap);

    var runtime: wasm.Runtime = undefined;
    var problem: wasm.Problem = .{};

    try runtime.init(.{ .heap = heap, .imports = &invoke.imports });
    defer runtime.deinit();

    var module = try wasm.Module.load(&runtime, module_bytes, &problem);
    defer module.unload();

    var instance = try wasm.Instance.init(&module, .{ .memory_pages_max = 256 }, &problem);
    defer instance.deinit();

    const budget: wasm.Instance.CallOptions = .{ .instructions_max = manifest_instructions_max };
    const cell = try instance.call("publr_alloc", &.{wire.result_bytes}, budget, &problem);
    const status = try instance.call("publr_manifest", &.{cell}, budget, &problem);

    if (cell == 0 or status != wire.ok) {
        return error.NoManifest;
    }

    const result_bytes = instance.bytes(cell, wire.result_bytes) orelse return error.NoManifest;
    const result = std.mem.bytesToValue(wire.Result, result_bytes);
    const json = instance.bytes(result.ptr, result.len) orelse return error.NoManifest;

    std.debug.assert(result.len == json.len);

    return arena.dupe(u8, json);
}

/// `plugin add` as the local operator, then `plugin enable` for a new plugin or `plugin
/// update` for its next version, printing what each answered; in the server when one runs
/// (`operator.zig`), so the new version is live when this returns.
fn install(init: std.process.Init, db_path: [:0]const u8, name: []const u8, path: []const u8) !u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(path.len > 0);

    var commands: operator.Commands = .{ .init = init, .db_path = db_path };
    defer commands.deinit();

    if (try unchanged(init, &commands, name, path)) {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "{s} is up to date\n", .{name});

        try std.Io.File.stdout().writeStreamingAll(init.io, line);
        return 0;
    }

    var added: std.Io.Writer.Allocating = .init(init.arena.allocator());
    const add = [_][]const u8{ "--as-admin", "plugin", "add", "--file", path };

    if (try commands.run(&add, &added.writer) != 0) {
        return 1;
    }

    const update = std.mem.indexOf(u8, added.written(), "\"update\": true") != null;
    const verb: []const u8 = if (update) "update" else "enable";
    const flag: []const u8 = if (update) "--name" else "--names";
    const next = [_][]const u8{ "--as-admin", "plugin", verb, flag, name };
    var stdout_buffer: [16 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch |err| std.debug.print("stdout: {t}\n", .{err});

    return commands.run(&next, &stdout.interface);
}

/// Whether the plugin installed as `name` is this very module: its hash is the SHA-256 of
/// the module's bytes, as `plugin get` answers it.
fn unchanged(
    init: std.process.Init,
    commands: *operator.Commands,
    name: []const u8,
    path: []const u8,
) !bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(path.len > 0);

    const arena = init.arena.allocator();
    const limit: std.Io.Limit = .limited(module_bytes_max);
    const module = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, limit);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(module, &digest, .{});

    const hex = std.fmt.bytesToHex(digest, .lower);
    const listed = try std.fmt.allocPrint(arena, "\"name\": \"{s}\"", .{name});
    const hashed = try std.fmt.allocPrint(arena, "\"hash\": \"{s}\"", .{&hex});
    var plugins: std.Io.Writer.Allocating = .init(arena);
    var installed: std.Io.Writer.Allocating = .init(arena);
    const list = [_][]const u8{ "--as-admin", "plugin", "list" };
    const get = [_][]const u8{ "--as-admin", "plugin", "get", "--name", name };

    if (try commands.run(&list, &plugins.writer) != 0) {
        return false;
    }

    // Asked only once the plugin is there: `plugin get` reports a missing one as an error.
    if (std.mem.indexOf(u8, plugins.written(), listed) == null) {
        return false;
    }

    return try commands.run(&get, &installed.writer) == 0 and
        std.mem.indexOf(u8, installed.written(), hashed) != null;
}

/// What `serve` gives the `plugin build` operation: the build started as this binary's own
/// `publr plugin build`, in a process of its own, its output to `<data>/builds/<name>.log`;
/// it installs through this server when it is done, as the CLI's does.
pub const Builder = struct {
    io: std.Io,
    db_path: []const u8,
    executable: []const u8 = "",
    logs_dir: []const u8 = "",

    pub fn hook(builder: *Builder, arena: std.mem.Allocator) !sdk_context.PluginBuilder {
        std.debug.assert(builder.db_path.len > 0);

        builder.executable = try std.process.executablePathAlloc(builder.io, arena);
        builder.logs_dir = try std.fs.path.join(arena, &.{
            std.fs.path.dirname(builder.db_path) orelse ".",
            "builds",
        });

        std.debug.assert(builder.executable.len > 0);

        return .{
            .context = builder,
            .plugins_dir = "plugins",
            .logs_dir = builder.logs_dir,
            .start = &start,
        };
    }

    fn start(context: *anyopaque, name: []const u8) ?[]const u8 {
        const builder: *Builder = @ptrCast(@alignCast(context));

        std.debug.assert(name.len > 0);
        std.debug.assert(builder.executable.len > 0);

        builder.spawn(name) catch |err| return @errorName(err);

        return null;
    }

    fn spawn(builder: *Builder, name: []const u8) !void {
        std.debug.assert(name.len <= 64);

        var buffer: [512]u8 = undefined;
        const log_path = try std.fmt.bufPrint(&buffer, "{s}/{s}.log", .{ builder.logs_dir, name });
        const cwd = std.Io.Dir.cwd();

        try cwd.createDirPath(builder.io, builder.logs_dir);

        var log = try cwd.createFile(builder.io, log_path, .{});
        defer log.close(builder.io);

        // Not waited for: it outlives this request, and installs through the server itself.
        _ = try std.process.spawn(builder.io, .{
            .argv = &.{
                builder.executable, "--db",  builder.db_path,
                "plugin",           "build", "--name",
                name,
            },
            .stdin = .ignore,
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
        });
    }
};

const sdk_context = @import("../sdk/context.zig");
