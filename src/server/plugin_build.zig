//! A sandboxed plugin's build, around a compiler outside this binary (the `publr`
//! command's): `plugin prepare` checks the source and writes what the compile takes (this
//! release's SDK, the docs module, the lowered views, the published interfaces) with the
//! recipe's arguments; `plugin check --file` makes the compiled module whole (its manifest
//! read by running it and written into its `publr` section) and runs its examples. Adding it
//! is `plugin add`'s.
const std = @import("std");
const doc_reader = @import("../sdk/plugin/doc_reader.zig");
const wasm = @import("publr_wasm");
const plugin_sdk = @import("plugin_sdk.zig");
const invoke = @import("sandboxed_plugins/invoke.zig");
const wire = @import("../sdk/plugin/wire.zig");
const plugin_manifest = @import("../sdk/plugin/manifest.zig");
const report = @import("../lib/report.zig");
const operator = @import("operator.zig");

const module_bytes_max: u32 = 16 << 20;
const heap_bytes: u32 = 32 << 20;
const manifest_instructions_max: u64 = 400_000_000;
const stubs_max: u32 = 32;

pub const Request = struct {
    name: []const u8,
    dir: []const u8,
    /// Only build, into this file: nothing is installed.
    out: ?[]const u8 = null,
    /// Built plugins (`.wasm`) whose published interfaces it builds against, over what the
    /// site has: an owner not installed yet, or a build with no site.
    with: []const []const u8 = &.{},
};

const published = @import("../sdk/published.zig");
const published_dir = @import("plugin_build/published.zig");
const examples = @import("plugin_build/examples.zig");

/// What a build has of the site it builds for: each plugin's published interface, and the
/// modules of the plugins it has installed, for its examples.
pub const Site = struct {
    interfaces: []const published.Interface,
    modules: []const examples.Module = &.{},
};

/// The local site: its plugins' interfaces as it answers `plugin interfaces`, and its
/// enabled installed plugins' modules, in `plugins/` beside its database.
fn site_of(init: std.process.Init, db_path: [:0]const u8) !Site {
    std.debug.assert(db_path.len > 0);

    var commands: operator.Commands = .{
        .init = init,
        .db_path = db_path,
    };
    defer commands.deinit();

    const arena = init.arena.allocator();
    const asker: Asker = .{
        .commands = &commands,
    };
    const dir = std.fs.path.dirname(db_path) orelse ".";

    return .{
        .interfaces = try published_dir.asked(arena, asker),
        .modules = try installed_modules(arena, asker, dir),
    };
}

/// Commands run as the site's administrator: in the server when one runs, else here.
const Asker = struct {
    commands: *operator.Commands,

    pub fn ask(asker: Asker, words: []const []const u8, out: *std.Io.Writer) !u8 {
        var as_admin: [8][]const u8 = undefined;

        std.debug.assert(words.len < as_admin.len);

        as_admin[0] = "--as-admin";
        @memcpy(as_admin[1 .. words.len + 1], words);

        return asker.commands.run(as_admin[0 .. words.len + 1], out);
    }
};

/// Each enabled installed plugin's module, by its hash in `<data>/plugins/`. Asked as every
/// other command is, so it works whether `serve` runs or not: the plugins page by page,
/// then each one's hash.
fn installed_modules(
    arena: std.mem.Allocator,
    asker: Asker,
    dir: []const u8,
) ![]const examples.Module {
    std.debug.assert(dir.len > 0);

    const Listed = struct {
        name: []const u8,
        mode: []const u8,
        enabled: bool,
    };
    const Page = struct {
        plugins: []const Listed = &.{},
        total: u32 = 0,
    };
    var modules: std.ArrayList(examples.Module) = .empty;
    var offset: u32 = 0;

    while (offset < plugins_listed_max) : (offset += list_page) {
        var answer: std.Io.Writer.Allocating = .init(arena);
        const at = try std.fmt.allocPrint(arena, "{d}", .{offset});
        const limit = try std.fmt.allocPrint(arena, "{d}", .{list_page});
        const words = [_][]const u8{ "plugin", "list", "--limit", limit, "--offset", at };

        if (try asker.ask(&words, &answer.writer) != 0) {
            return error.Unavailable;
        }

        const page = try std.json.parseFromSliceLeaky(Page, arena, answer.written(), .{
            .ignore_unknown_fields = true,
        });

        for (page.plugins) |plugin| {
            if (!plugin.enabled or !std.mem.eql(u8, plugin.mode, "sandboxed")) {
                continue;
            }

            const hash = try hash_of(arena, asker, plugin.name);
            const file = try std.fmt.allocPrint(arena, "{s}.wasm", .{hash});

            try modules.append(arena, .{
                .name = plugin.name,
                .path = try std.fs.path.join(arena, &.{ dir, "plugins", file }),
            });
        }

        if (offset + list_page >= page.total) {
            break;
        }
    }

    return modules.items;
}

/// The hash of the module the installed plugin `name` runs, as `plugin get` answers it.
fn hash_of(arena: std.mem.Allocator, asker: Asker, name: []const u8) ![]const u8 {
    std.debug.assert(name.len > 0);

    const Detail = struct {
        hash: []const u8,
    };
    var answer: std.Io.Writer.Allocating = .init(arena);

    if (try asker.ask(&.{ "plugin", "get", "--name", name }, &answer.writer) != 0) {
        return error.Unavailable;
    }

    const detail = try std.json.parseFromSliceLeaky(Detail, arena, answer.written(), .{
        .ignore_unknown_fields = true,
    });

    std.debug.assert(detail.hash.len > 0);

    return detail.hash;
}

const list_page: u32 = 200;
/// Plugins on one site at most, built in and installed.
const plugins_listed_max: u32 = 600;

/// The built plugins a build has: each `--with` package, then the site's.
fn modules_of(
    init: std.process.Init,
    with: []const []const u8,
    site: Site,
) ![]const examples.Module {
    const arena = init.arena.allocator();
    var modules: std.ArrayList(examples.Module) = .empty;

    std.debug.assert(with.len < 1 << 10);

    for (with) |path| {
        const manifest = try published_dir.manifest_of(init, path);

        try modules.append(arena, .{
            .name = manifest.name,
            .path = path,
        });
    }

    try modules.appendSlice(arena, site.modules);

    return modules.items;
}

/// What a build takes beside the compiler, made ready: the recipe's arguments and what the
/// checks after compiling read.
pub const Prepared = struct {
    /// The compiler's arguments after its own executable: Publr's recipe (the SDK's root,
    /// its modules, the plugin's, its docs, views and published interfaces, the output). What
    /// is the compiler's own goes after them: its compiler_rt, its wasm flags, its cache.
    args: []const []const u8,
    /// The plugin's lowered views (`views.zig` and its modules), when it has any.
    views: ?[]const u8,
    /// The plugin's source files, as `check.files_in` reads them.
    files: []const doc_reader.File,
};

/// Everything a build of the plugin into `built` needs from Publr, against the SDK in
/// `sdk`: its source checked, its docs module and lowered views written beside `built`, the
/// published interfaces of the plugins `site` has (and `request.with`'s over them) written
/// as modules, and the compiler's arguments. Null, having said why, when it cannot build.
pub fn prepared(
    init: std.process.Init,
    request: Request,
    built: []const u8,
    site: Site,
    sdk: []const u8,
) !?Prepared {
    std.debug.assert(request.name.len > 0);
    std.debug.assert(built.len > 0);
    std.debug.assert(sdk.len > 0);

    const arena = init.arena.allocator();
    const main_path = try std.fs.path.join(arena, &.{ request.dir, "main.zig" });

    std.Io.Dir.cwd().access(init.io, main_path, .{}) catch {
        report.err("publr plugin build: no plugin at {s}", .{main_path});
        return null;
    };

    const check = @import("plugin_build/check.zig");
    const files = try check.files_in(init, request.dir);
    const read = try doc_reader.source_of(arena, files);
    const problems = try check.problems_of(arena, read);

    check.reported(request.dir, problems);

    if (doc_reader.failing(problems)) {
        return null;
    }

    const docs_path = try std.fmt.allocPrint(arena, "{s}.docs.zig", .{built});

    try write_docs(init, docs_path, read.source);

    const views = @import("plugin_build/views.zig").lower(init, sdk, request.dir, built) catch {
        return null;
    };

    @import("plugin_build/interactive.zig").lower(init, sdk, request.dir, built) catch {
        return null;
    };
    const interfaces = published_dir.with_packages(init, site.interfaces, request.with) catch {
        return null;
    };

    if (published_dir.missing(files, request.name, interfaces)) |name| {
        report.err("publr plugin build: {s} imports {s}, which this site doesn't have: " ++
            "install {s} first, or pass --with <{s}.wasm>", .{ request.name, name, name, name });
        return null;
    }

    const modules = try published_dir.write(init, built, request.name, interfaces);
    const args = try recipe(init, sdk, request, .{
        .out = built,
        .docs = docs_path,
        .views = views,
        .published = modules,
    });

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(built) orelse ".");

    return .{
        .args = args,
        .views = views,
        .files = files,
    };
}

pub const Finish = struct {
    /// The plugin's source files, as `check.files_in` reads them.
    files: []const doc_reader.File,
    /// Its lowered views (`views.zig`), when it has any.
    views: ?[]const u8 = null,
    /// Its `Example:`s run against an empty site with it, beside the other modules.
    examples: bool = true,
    /// Its types written beside its views, in its source folder.
    types: bool = false,
};

/// A compiled module made whole and checked: its manifest read by running it and written
/// into its `publr` section with its source and its views' browser code, what its sandboxed
/// build left out said, its examples run. False, having said why, when it fails them.
pub fn finished(
    init: std.process.Init,
    request: Request,
    built: []const u8,
    site: Site,
    finish: Finish,
) !bool {
    std.debug.assert(request.name.len > 0);
    std.debug.assert(built.len > 0);

    const source = try std.json.Stringify.valueAlloc(init.arena.allocator(), finish.files, .{});
    const stores = if (finish.views) |folder| try stores_of(init, folder) else null;
    const components = try components_of(init, request.dir);
    const interactive = try @import("plugin_build/interactive.zig").section_of(init, built);
    const manifest = try write_manifest(init, built, .{
        .source = source,
        .stores = stores,
        .components = components,
        .interactive = interactive,
    });

    try warn_left_out(init, request.name, manifest);

    if (finish.examples) {
        // Every `Example:` runs against an empty site with the plugin before it reaches this
        // one.
        const beside = try modules_of(init, request.with, site);

        if (!try examples.run(init, built, manifest, beside)) {
            return false;
        }
    }

    if (finish.types) {
        try @import("plugin_build/types.zig").write(init, request.dir, manifest);
    }

    return true;
}

const CheckArgs = struct {
    file: []const u8,
    dir: []const u8,
    views: ?[]const u8 = null,
    types: bool = false,
    /// Its examples left unrun: a module built only to a file (Publr's own test plugins).
    examples: bool = true,
    with: []const []const u8 = &.{},
};

/// `--file` and `--dir`, required; `--views`, `--with` (again for each), `--types` and
/// `--no-examples`.
fn check_args(arena: std.mem.Allocator, args: []const []const u8) ?CheckArgs {
    std.debug.assert(args.len < 1 << 16);

    var file: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var views: ?[]const u8 = null;
    var types = false;
    var run_examples = true;
    var with: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const word = args[index];

        if (std.mem.eql(u8, word, "--types")) {
            types = true;
            continue;
        }

        if (std.mem.eql(u8, word, "--no-examples")) {
            run_examples = false;
            continue;
        }

        if (index + 1 == args.len) {
            return null;
        }

        index += 1;

        if (std.mem.eql(u8, word, "--file")) {
            file = args[index];
        } else if (std.mem.eql(u8, word, "--dir")) {
            dir = args[index];
        } else if (std.mem.eql(u8, word, "--views")) {
            views = args[index];
        } else if (std.mem.eql(u8, word, "--with")) {
            with.append(arena, args[index]) catch return null;
        } else {
            return null;
        }
    }

    return .{
        .file = file orelse return null,
        .dir = dir orelse return null,
        .views = views,
        .types = types,
        .examples = run_examples,
        .with = with.items,
    };
}

/// `publr plugin check --file <module.wasm> --dir <source> [--views <folder>] [--with
/// <x.wasm>]... [--types] [--no-examples]`: a module compiled elsewhere (by the `publr`
/// command, against this release's SDK from `plugin sdk`) made whole and checked: the source
/// checks, the manifest written into the module, its examples run
/// beside the site's plugins (or this binary's, with no site here). It installs nothing:
/// `plugin add --file` does. Exits 1 when the module fails, 2 for wrong words.
pub fn check_file(init: std.process.Init, db_path: [:0]const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    const asked = check_args(arena, args) orelse {
        report.err("usage: publr plugin check --file <module.wasm> --dir <source folder> " ++
            "[--views <folder>] [--with <x.wasm>]... [--types] [--no-examples]", .{});
        return 2;
    };
    const built = asked.file;
    const source_dir = asked.dir;
    const views = asked.views;
    const types = asked.types;
    const with = asked.with;

    std.Io.Dir.cwd().access(init.io, built, .{}) catch {
        report.err("publr plugin check: no module at {s}", .{built});
        return 1;
    };

    const limit: std.Io.Limit = .limited(module_bytes_max);
    const module = try std.Io.Dir.cwd().readFileAlloc(init.io, built, arena, limit);
    const whole = wasm.section.find(module, plugin_manifest.section_name) catch {
        report.err("publr plugin check: {s} is not a WebAssembly module", .{built});
        return 1;
    };

    if (whole != null) {
        report.err("publr plugin check: {s} carries its manifest already; check the module " ++
            "as the compiler wrote it", .{built});
        return 1;
    }

    const check = @import("plugin_build/check.zig");
    const files = try check.files_in(init, source_dir);
    const read = try doc_reader.source_of(arena, files);
    const problems = try check.problems_of(arena, read);

    check.reported(source_dir, problems);

    if (doc_reader.failing(problems)) {
        return 1;
    }

    // With a site here, its examples run beside the site's plugins; else beside this
    // binary's.
    const has_site = blk: {
        std.Io.Dir.cwd().access(init.io, db_path, .{}) catch break :blk false;
        break :blk true;
    };
    const site: Site = if (has_site) try site_of(init, db_path) else .{
        .interfaces = @import("registry.zig").published_interfaces,
    };
    const request: Request = .{
        .name = std.fs.path.stem(built),
        .dir = source_dir,
        .with = with,
    };
    const ok = try finished(init, request, built, site, .{
        .files = files,
        .views = views,
        .types = types,
        .examples = asked.examples,
    });

    return if (ok) 0 else 1;
}

/// `publr plugin prepare --name <n> [--dir <folder>] --out <folder> [--with <x.wasm>]...
/// [--interfaces <file>]`: everything a compiler outside this binary (the `publr` command's)
/// needs to build the plugin as `plugin build` would, written into a new or empty folder:
/// this release's SDK (`sdk/`), the plugin's docs module, its lowered views and the published
/// interfaces it builds against, beside `<name>.wasm`, the module it is to build. It prints
/// the build as JSON: `args`, the compiler's arguments after its own executable (absolute
/// paths, the output included), then `module`, `views` (null without views) and `dir`. The
/// compiler adds what is its own after `args`: its compiler_rt, its wasm flags, its cache.
/// The interfaces are the site's here, those `--interfaces` holds (a site elsewhere's, as
/// `plugin interfaces` answers them), or this binary's with neither. Exits 1 when the plugin
/// cannot build, 2 for wrong words.
pub fn prepare(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    var words: std.ArrayList([]const u8) = .empty;
    var interfaces_file: ?[]const u8 = null;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--interfaces") and index + 1 < args.len) {
            index += 1;
            interfaces_file = args[index];
        } else {
            try words.append(arena, args[index]);
        }
    }

    const asked = parse(arena, words.items) orelse return prepare_usage();
    const folder_given = asked.out orelse return prepare_usage();
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(init.io, folder_given);

    var folder_dir = try cwd.openDir(init.io, folder_given, .{
        .iterate = true,
    });
    defer folder_dir.close(init.io);
    var iterator = folder_dir.iterate();

    if (try iterator.next(init.io) != null) {
        report.err("publr plugin prepare: {s} is not empty", .{folder_given});
        return 1;
    }

    const folder = try cwd.realPathFileAlloc(init.io, folder_given, arena);
    const dir = cwd.realPathFileAlloc(init.io, asked.dir, arena) catch {
        report.err("publr plugin prepare: no plugin at {s}", .{asked.dir});
        return 1;
    };
    const sdk = try std.fs.path.join(arena, &.{ folder, "sdk" });
    var sdk_dir = try cwd.createDirPathOpen(init.io, sdk, .{});
    defer sdk_dir.close(init.io);

    plugin_sdk.extract_sdk(init.io, sdk_dir) catch |err| {
        report.err_reason(@errorName(err), "publr plugin prepare: this binary carries no SDK", .{});
        return 1;
    };

    const has_site = blk: {
        cwd.access(init.io, db_path, .{}) catch break :blk false;
        break :blk true;
    };
    const site: Site = if (interfaces_file) |file| .{
        .interfaces = published_dir.from_file(init, file) catch return 1,
    } else if (has_site) try site_of(init, db_path) else .{
        .interfaces = @import("registry.zig").published_interfaces,
    };
    const request: Request = .{
        .name = asked.name,
        .dir = dir,
        .with = asked.with,
    };
    const module_name = try std.fmt.allocPrint(arena, "{s}.wasm", .{asked.name});
    const built = try std.fs.path.join(arena, &.{ folder, module_name });
    const ready = try prepared(init, request, built, site, sdk) orelse return 1;
    const Answer = struct {
        args: []const []const u8,
        module: []const u8,
        views: ?[]const u8,
        dir: []const u8,
    };

    try std.json.Stringify.value(Answer{
        .args = ready.args,
        .module = built,
        .views = ready.views,
        .dir = dir,
    }, .{
        .whitespace = .indent_2,
    }, out);
    try out.writeByte('\n');

    return 0;
}

fn prepare_usage() u8 {
    report.err("usage: publr plugin prepare --name <name> [--dir <folder>] --out <folder> " ++
        "[--with <x.wasm>]... [--interfaces <file>]", .{});
    return 2;
}

/// `--name <name>`, `--dir <folder>` (default `plugins/<name>`), whose `main.zig`
/// is the plugin, `--out <file>` to only build it, and `--with <file.wasm>`, again for each,
/// a built plugin to build against.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) ?Request {
    std.debug.assert(args.len < 1 << 16);

    var name: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var with: std.ArrayList([]const u8) = .empty;
    var index: u32 = 0;

    while (index + 1 < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--name")) {
            name = args[index + 1];
        } else if (std.mem.eql(u8, args[index], "--dir")) {
            dir = args[index + 1];
        } else if (std.mem.eql(u8, args[index], "--out")) {
            out = args[index + 1];
        } else if (std.mem.eql(u8, args[index], "--with")) {
            with.append(arena, args[index + 1]) catch return null;
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

    return .{
        .name = name.?,
        .dir = folder,
        .out = out,
        .with = with.items,
    };
}

/// Where a build goes and what it takes beside the plugin's source.
const Paths = struct {
    out: []const u8,
    docs: []const u8,
    /// The plugin's lowered views (`views.zig`), when it has any.
    views: ?[]const u8 = null,
    /// The other plugins' published interfaces, a module each, and their listing.
    published: published_dir.Modules,
};

/// Publr's recipe: the plugin built for the sandbox against the SDK in `sdk`, its root
/// (`guest.zig`, the exports), `publr` (the SDK's source) with a stub for each module only
/// the host has, and the plugin. The compiler's own executable, compiler_rt, wasm flags and
/// cache are not in it.
fn recipe(
    init: std.process.Init,
    sdk: []const u8,
    request: Request,
    paths: Paths,
) ![]const []const u8 {
    const out_path = paths.out;
    const docs_path = paths.docs;
    const arena = init.arena.allocator();
    const stubs = try stub_names(init, sdk);
    const target = [_][]const u8{
        "-Osmall",
        "-target",
        "wasm32-freestanding",
        "-mcpu=baseline+bulk_memory",
    };
    var argv: std.ArrayList([]const u8) = .empty;

    std.debug.assert(stubs.len > 0);

    try argv.appendSlice(arena, &.{ "build-exe", "--stack", "262144" });
    try argv.appendSlice(arena, &target);
    try argv.appendSlice(arena, &.{ "--dep", "publr", "--dep", "plugin", "--dep", "plugin_docs" });
    try argv.appendSlice(arena, &.{ "--dep", "plugin_published" });
    try argv.append(arena, try std.fmt.allocPrint(arena, "-Mroot={s}/guest.zig", .{sdk}));
    try argv.appendSlice(arena, &target);

    for (stubs) |stub| {
        try argv.appendSlice(arena, &.{ "--dep", stub });
    }

    if (paths.views != null) {
        try argv.appendSlice(arena, &.{ "--dep", "plugin_views" });
    }

    const publr_module = try std.fmt.allocPrint(arena, "-Mpublr={s}/src/publr.zig", .{sdk});

    try argv.append(arena, publr_module);

    if (paths.views) |views| {
        try views_modules(arena, &argv, &target, sdk, views);
    }

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

    try published_modules(arena, &argv, &target, paths.published);
    try argv.appendSlice(arena, &target);
    try argv.appendSlice(arena, &.{ "--dep", "publr" });

    if (has_interface) {
        try argv.appendSlice(arena, &.{ "--dep", request.name });
    }

    for (paths.published.names) |name| {
        try argv.appendSlice(arena, &.{ "--dep", name });
    }

    try argv.append(arena, try std.fmt.allocPrint(arena, "-Mplugin={s}/main.zig", .{request.dir}));
    try argv.appendSlice(arena, &target);
    try argv.append(arena, try std.fmt.allocPrint(arena, "-Mplugin_docs={s}", .{docs_path}));

    for (stubs) |stub| {
        // A plugin with views runs the real render runtime, defined with them.
        if (paths.views != null and std.mem.eql(u8, stub, "runtime")) {
            continue;
        }

        const path = try std.fmt.allocPrint(arena, "-M{s}={s}/stubs/{s}.zig", .{
            stub,
            sdk,
            stub,
        });

        try argv.append(arena, path);
    }

    try argv.appendSlice(arena, &.{ "--name", request.name, "-rdynamic" });
    try argv.append(arena, try std.fmt.allocPrint(arena, "-femit-bin={s}", .{out_path}));

    return argv.items;
}

/// Each other plugin's published interface as a module under its name, and their listing
/// (`plugin_published`) the root checks the plugin's dimension options against.
fn published_modules(
    arena: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    target: []const []const u8,
    modules: published_dir.Modules,
) !void {
    std.debug.assert(target.len > 0);
    std.debug.assert(modules.dir.len > 0);

    for (modules.names) |name| {
        try argv.appendSlice(arena, target);
        try argv.appendSlice(arena, &.{ "--dep", "publr" });
        try argv.append(arena, try std.fmt.allocPrint(arena, "-M{s}={s}/{s}.zig", .{
            name,
            modules.dir,
            name,
        }));
    }

    try argv.appendSlice(arena, target);
    try argv.appendSlice(arena, &.{ "--dep", "publr" });

    for (modules.names) |name| {
        try argv.appendSlice(arena, &.{ "--dep", name });
    }

    const listing = try std.fmt.allocPrint(arena, "-Mplugin_published={s}/all.zig", .{modules.dir});

    try argv.append(arena, listing);
}

/// A plugin's views as modules: its own (`plugin_views`), the real props of what the host
/// draws for it (`ds`), and what both are written against (`runtime`, `request`, a plain
/// `class_merge`).
fn views_modules(
    arena: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    target: []const []const u8,
    sdk: []const u8,
    views: []const u8,
) !void {
    std.debug.assert(views.len > 0);
    std.debug.assert(target.len > 0);

    const Module = struct {
        name: []const u8,
        deps: []const []const u8,
        /// Under the lowered views rather than the SDK.
        own: bool = false,
        file: []const u8,
    };
    const modules = [_]Module{
        .{
            .name = "plugin_views",
            .deps = &.{ "runtime", "request", "ds", "publr" },
            .own = true,
            .file = "views.zig",
        },
        .{
            .name = "ds",
            .deps = &.{ "runtime", "request" },
            .file = "ui/views/views.zig",
        },
        .{
            .name = "request",
            .deps = &.{"runtime"},
            .file = "ui/request.zig",
        },
        .{
            .name = "runtime",
            .deps = &.{"class_merge"},
            .file = "pjsx/template_runtime.zig",
        },
        .{
            .name = "class_merge",
            .deps = &.{},
            .file = "ui/class_merge.zig",
        },
    };

    for (modules) |module| {
        const name = module.name;
        const deps = module.deps;
        const folder = if (module.own) views else sdk;
        const path = try std.fmt.allocPrint(arena, "-M{s}={s}/{s}", .{ name, folder, module.file });

        try argv.appendSlice(arena, target);

        for (deps) |dep| {
            try argv.appendSlice(arena, &.{ "--dep", dep });
        }

        try argv.append(arena, path);
    }
}

/// The modules the SDK imports that only the host has, each a stub in `<sdk>/stubs/`.
fn stub_names(init: std.process.Init, sdk_dir: []const u8) ![]const []const u8 {
    const arena = init.arena.allocator();
    const stubs_path = try std.fs.path.join(arena, &.{ sdk_dir, "stubs" });
    var dir = try std.Io.Dir.cwd().openDir(init.io, stubs_path, .{
        .iterate = true,
    });
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

/// The browser half of the plugin's views (`stores.js` its lowering wrote), or null when they
/// register nothing: their page loads it in the plugin frame after the admin's.
fn stores_of(init: std.process.Init, views: []const u8) !?[]const u8 {
    std.debug.assert(views.len > 0);

    const arena = init.arena.allocator();
    const path = try std.fs.path.join(arena, &.{ views, "stores.js" });
    const limit: std.Io.Limit = .limited(stores_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, limit) catch |err| {
        switch (err) {
            error.FileNotFound => return null,
            else => return err,
        }
    };

    return if (std.mem.indexOf(u8, text, "Publr.") == null) null else text;
}

/// The most browser code a plugin's views may carry.
const stores_bytes_max = 1 << 20;

/// The site components the plugin brings (`components/<Name>.publr`), as `publr.components`
/// carries them; null when it has none.
fn components_of(init: std.process.Init, dir: []const u8) !?[]const u8 {
    std.debug.assert(dir.len > 0);

    const arena = init.arena.allocator();
    const folder = try std.fs.path.join(arena, &.{ dir, "components" });
    var handle = std.Io.Dir.cwd().openDir(init.io, folder, .{
        .iterate = true,
    }) catch return null;
    defer handle.close(init.io);

    var found: std.ArrayList(components_module.Carried) = .empty;
    var entries = handle.iterate();

    while (try entries.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".publr")) {
            continue;
        }

        const name = entry.name[0 .. entry.name.len - ".publr".len];

        if (!components_module.valid_name(name) or
            found.items.len == components_module.components_max)
        {
            report.err("publr plugin build: components/{s}: a component is " ++
                "`<Name>.publr`, at most {d}", .{ entry.name, components_module.components_max });
            return error.InvalidComponents;
        }

        try found.append(arena, .{
            .name = try arena.dupe(u8, name),
            .text = try handle.readFileAlloc(init.io, entry.name, arena, .limited(1 << 20)),
        });
    }

    if (found.items.len == 0) {
        return null;
    }

    return try std.json.Stringify.valueAlloc(arena, found.items, .{});
}

const components_module = @import("sandboxed_plugins/components.zig");

/// What a built module carries besides its code.
const Carried = struct {
    /// The plugin's source, JSON.
    source: []const u8,
    /// Its views' browser code.
    stores: ?[]const u8 = null,
    /// Its site components, JSON.
    components: ?[]const u8 = null,
    /// Its interactive components, built for a place with no compiler, JSON.
    interactive: ?[]const u8 = null,
};

/// Reads the manifest by running the module's `publr_manifest` in the sandbox, with no
/// grants and nothing it could call, and writes it into the module's `publr` section, the
/// plugin's source into `publr.source`, for the install gate's checks, its views' browser
/// code into `publr.stores` and its site components into `publr.components`.
fn write_manifest(
    init: std.process.Init,
    path: []const u8,
    carried: Carried,
) ![]const u8 {
    std.debug.assert(path.len > 0);

    const cwd = std.Io.Dir.cwd();
    const arena = init.arena.allocator();
    const module = try cwd.readFileAlloc(init.io, path, arena, .limited(module_bytes_max));
    // WAMR rewrites the bytes it loads, so it gets a copy of its own.
    const read = try manifest_of(init.gpa, arena, try arena.dupe(u8, module));
    const manifest = read.manifest;
    var output: std.Io.Writer.Allocating = .init(arena);

    std.debug.assert(manifest.len > 0);

    try output.writer.writeAll(module);
    try wasm.section.write(&output.writer, plugin_manifest.section_name, manifest);
    try wasm.section.write(&output.writer, plugin_manifest.source_section_name, carried.source);

    if (read.translations) |translations| {
        const name = plugin_manifest.translations_section_name;

        try wasm.section.write(&output.writer, name, translations);
    }

    if (carried.stores) |code| {
        try wasm.section.write(&output.writer, plugin_manifest.stores_section_name, code);
    }

    if (carried.components) |json| {
        try wasm.section.write(&output.writer, plugin_manifest.components_section_name, json);
    }

    if (carried.interactive) |json| {
        try wasm.section.write(&output.writer, plugin_manifest.interactive_section_name, json);
    }

    try cwd.writeFile(init.io, .{
        .sub_path = path,
        .data = output.written(),
    });

    return manifest;
}

/// What the plugin brings that its sandboxed build left out, said on stderr: it builds, and
/// runs without them.
fn warn_left_out(init: std.process.Init, name: []const u8, manifest: []const u8) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(manifest.len > 0);

    const Declared = struct {
        left_out: []const []const u8 = &.{},
    };
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

/// What running the module tells of it: its manifest, and its translations when it brings
/// any.
const Read = struct {
    manifest: []u8,
    translations: ?[]u8,
};

fn manifest_of(gpa: std.mem.Allocator, arena: std.mem.Allocator, module_bytes: []u8) !Read {
    std.debug.assert(module_bytes.len > 0);

    const heap = try gpa.alloc(u8, heap_bytes);
    defer gpa.free(heap);

    var runtime: wasm.Runtime = undefined;
    var problem: wasm.Problem = .{};

    try runtime.init(heap, &invoke.imports, .{});
    defer runtime.deinit();

    var module = wasm.Module.load(&runtime, module_bytes, &problem) catch |err| {
        std.log.err("the built module does not load: {s}", .{problem.text()});

        return err;
    };
    defer module.unload();

    var instance = try wasm.Instance.init(&module, 256, &problem, .{});
    defer instance.deinit();

    const manifest = try exported_json(&instance, arena, "publr_manifest", &problem) orelse {
        return error.NoManifest;
    };
    // Only a plugin that brings translations exports them.
    const asked = exported_json(&instance, arena, "publr_translations", &problem);
    const translations = asked catch |err| {
        if (err != error.NotFound) {
            return err;
        }

        return .{
            .manifest = manifest,
            .translations = null,
        };
    };

    return .{
        .manifest = manifest,
        .translations = translations,
    };
}

/// The JSON the module's `export_name` writes, copied out; null when it answers nothing.
fn exported_json(
    instance: *wasm.Instance,
    arena: std.mem.Allocator,
    export_name: [:0]const u8,
    problem: *wasm.Problem,
) !?[]u8 {
    std.debug.assert(export_name.len > 0);

    const budget = manifest_instructions_max;
    const cell = try instance.call("publr_alloc", &.{wire.result_bytes}, budget, problem, .{});
    const status = try instance.call(export_name, &.{cell}, budget, problem, .{});

    if (cell == 0 or status != wire.ok) {
        return null;
    }

    const result_bytes = instance.bytes(cell, wire.result_bytes) orelse return null;
    const result = std.mem.bytesToValue(wire.Result, result_bytes);
    const json = instance.bytes(result.ptr, result.len) orelse return null;

    std.debug.assert(result.len == json.len);

    return try arena.dupe(u8, json);
}

/// Every plugin is held to the plugin checks before it compiles; each problem is told with
/// its file and line.
/// The plugin's docs module, beside its built module.
fn write_docs(init: std.process.Init, path: []const u8, source: []const u8) !void {
    std.debug.assert(path.len > 0);

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(path) orelse ".");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = source,
    });
}
