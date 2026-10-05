//! The admin's `.ptsx → Zig` build, on the PJSX compiler's `zig` target. Run by
//! `zig build` as a host tool:
//!
//!     pjsx_gen <ui_dir> <components_dir> <icons_dir> <out_dir> [<plugin_ui_dir> ...]
//!
//! Compiles every `.ptsx` under `<ui_dir>` (`layouts/`, `pages/`, `components/`),
//! then every design-system component those reach through their imports
//! (`@publr/ui/<Name>.ptsx`, resolved by file stem under `<components_dir>/<Family>/`),
//! and an icon sprite holding every icon the compiled set names. The whole set
//! lowers as one program into `<out_dir>`: `<Name>.zig` per module, `views.zig`,
//! `classes.txt` (the JIT's manifest) and `stores.js`. Anything that does not
//! resolve or lower fails the build by name.
const std = @import("std");
const pjsx = @import("pjsx");
const request = @import("request");
const layouts = @import("pjsx_gen/layouts.zig");

const Module = pjsx.compiler.ModuleIR;
/// Stands for the render runtime's node while the request's fields are read.
const ShapeNode = struct { render_fn: ?*const anyopaque };

const file_bytes_max = 4 << 20;
const modules_max: u32 = 512;
const icons_max: u32 = 64;
const plugin_dirs_max: u32 = 64;
const runtime_import = "publr-jsx";
/// The design-system Button's loading spinner: always in the sprite.
const icon_always = "sync";
/// The one module the tool writes itself, after the closure names its icons.
const sprite_stem = "IconSprite";

const Set = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    modules: std.ArrayList(*const Module) = .empty,
    sources: std.ArrayList([]const u8) = .empty,
    /// Design-system components by file stem: `Button` → `Button/Button.ptsx`.
    components: std.StringHashMapUnmanaged([]const u8) = .empty,
    components_dir: std.Io.Dir,
    components_dir_path: []const u8,
    /// The admin's views as a compiled-in plugin's views import them:
    /// `@publr/admin/Layout.ptsx`.
    admin_views: std.ArrayList(pjsx.FileResolver.Import) = .empty,

    fn compile(set: *Set, source: []const u8, label: []const u8) !void {
        std.debug.assert(label.len > 0);

        if (set.modules.items.len >= modules_max) {
            return report(error.TooManyModules, label);
        }

        var imports: std.ArrayList(pjsx.FileResolver.Import) = .empty;
        var iterator = set.components.iterator();

        while (iterator.next()) |entry| {
            try imports.append(set.arena, .{
                .specifier = try std.fmt.allocPrint(set.arena, "@publr/ui/{s}.ptsx", .{
                    entry.key_ptr.*,
                }),
                .filename = try std.fs.path.join(set.arena, &.{
                    set.components_dir_path,
                    entry.value_ptr.*,
                }),
            });
        }

        try imports.appendSlice(set.arena, set.admin_views.items);

        var resolver = pjsx.FileResolver{ .io = set.io, .imports = imports.items };
        const module = pjsx.compiler.createPjsxModuleWithResolver(
            set.arena,
            source,
            label,
            resolver.resolver(),
        ) catch |err| {
            return report(err, label);
        };
        try set.modules.append(set.arena, module);
        try set.sources.append(set.arena, source);
    }

    fn has(set: *const Set, stem: []const u8) bool {
        std.debug.assert(stem.len > 0);
        std.debug.assert(set.modules.items.len == set.sources.items.len);

        for (set.modules.items) |module| {
            if (std.mem.eql(u8, module.component.name, stem)) {
                return true;
            }

            if (std.mem.eql(u8, stem_of(module.filename), stem)) {
                return true;
            }
        }

        return false;
    }
};

pub fn main(init: std.process.Init) u8 {
    std.debug.assert(modules_max > icons_max);

    return run(init) catch |err| {
        if (err != error.Failed) {
            std.debug.print("pjsx_gen: {s}\n", .{@errorName(err)});
        }

        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const ui_dir_path = args.next() orelse return usage();
    const components_dir_path = args.next() orelse return usage();
    const icons_dir_path = args.next() orelse return usage();
    const out_dir_path = args.next() orelse return usage();
    var plugin_dirs: std.ArrayList([]const u8) = .empty;

    while (args.next()) |plugin_dir| {
        if (plugin_dirs.items.len == plugin_dirs_max or plugin_dir.len == 0) {
            return usage();
        }

        try plugin_dirs.append(arena, plugin_dir);
    }

    for ([_][]const u8{ ui_dir_path, components_dir_path, icons_dir_path, out_dir_path }) |path| {
        if (path.len == 0) {
            return usage();
        }
    }

    const cwd = std.Io.Dir.cwd();
    var set: Set = .{
        .arena = arena,
        .io = io,
        .components_dir_path = components_dir_path,
        .components_dir = try cwd.openDir(io, components_dir_path, .{ .iterate = true }),
    };
    defer set.components_dir.close(io);

    try index_components(&set);
    try compile_ui(&set, ui_dir_path, .admin);

    if (set.modules.items.len == 0) {
        return report(error.NoModules, ui_dir_path);
    }

    for (plugin_dirs.items) |plugin_dir| {
        try compile_ui(&set, plugin_dir, .plugin);
    }

    try compile_imports(&set);

    const ui_dirs = try std.mem.concat(arena, []const u8, &.{ &.{ui_dir_path}, plugin_dirs.items });

    try compile_sprite(&set, ui_dirs, icons_dir_path);
    try cwd.createDirPath(io, out_dir_path);
    var out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);
    try lower(&set, out_dir);

    std.debug.assert(set.modules.items.len > 0);

    return 0;
}

/// Every `<Family>/<Name>.ptsx` under the design system, by stem.
fn index_components(set: *Set) !void {
    std.debug.assert(set.components.count() == 0);
    std.debug.assert(set.modules.items.len == 0);

    var walker = try set.components_dir.walk(set.arena);
    defer walker.deinit();

    while (try walker.next(set.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".ptsx")) {
            continue;
        }

        const stem = try set.arena.dupe(u8, stem_of(entry.basename));
        const path = try set.arena.dupe(u8, entry.path);

        try index_entry(set, stem, path);

        // A file may export a component under another name (`Sidebar.ptsx` exports
        // `SidebarRail`), and imports name components: index that name too.
        const source = try set.components_dir.readFileAlloc(
            set.io,
            path,
            set.arena,
            .limited(file_bytes_max),
        );

        if (exported_component(source)) |name| {
            try index_entry(set, try set.arena.dupe(u8, name), path);
        }
    }
}

/// `Family/Family.ptsx` wins a stem; a sibling variant (`Family.next.ptsx`) never
/// displaces it, and a name already mapped keeps its first file.
fn index_entry(set: *Set, key: []const u8, path: []const u8) !void {
    std.debug.assert(key.len > 0);
    std.debug.assert(path.len > 0);

    const slot = try set.components.getOrPut(set.arena, key);

    if (slot.found_existing and !is_canonical(path, key)) {
        return;
    }

    slot.value_ptr.* = path;
}

/// The name after the first `export function`, which is the module's component.
fn exported_component(source: []const u8) ?[]const u8 {
    std.debug.assert(source.len > 0);

    const marker = "export function ";
    const at = std.mem.indexOf(u8, source, marker) orelse return null;
    const rest = source[at + marker.len ..];
    var end: usize = 0;

    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
        end += 1;
    }

    std.debug.assert(end <= rest.len);

    return if (end > 0) rest[0..end] else null;
}

/// The admin's own views, or a compiled-in plugin's: every `.ptsx` under `ui_dir`, in path
/// order so the output is deterministic. A module is named by its file stem, so the folder
/// is organisation only, and a plugin's stem may not be one the admin or another plugin
/// has. The admin's are what plugins import as `@publr/admin/<Stem>.ptsx`.
fn compile_ui(set: *Set, ui_dir_path: []const u8, owner: enum { admin, plugin }) !void {
    std.debug.assert(ui_dir_path.len > 0);
    std.debug.assert((owner == .admin) == (set.modules.items.len == 0));

    var ui_dir = try std.Io.Dir.cwd().openDir(set.io, ui_dir_path, .{ .iterate = true });
    defer ui_dir.close(set.io);

    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try ui_dir.walk(set.arena);
    defer walker.deinit();

    while (try walker.next(set.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".ptsx")) {
            try paths.append(set.arena, try set.arena.dupe(u8, entry.path));
        }
    }

    std.mem.sort([]const u8, paths.items, {}, less_than);

    for (paths.items) |path| {
        const source = try ui_dir.readFileAlloc(set.io, path, set.arena, .limited(file_bytes_max));
        const label = try std.fs.path.join(set.arena, &.{ ui_dir_path, path });
        const stem = stem_of(path);

        if (owner == .plugin and (set.has(stem) or set.components.contains(stem))) {
            std.debug.print("pjsx_gen: {s}: the view {s} is already the admin's or the " ++
                "design system's; name it after the plugin\n", .{ label, stem });

            return error.Failed;
        }

        if (owner == .admin) {
            try set.admin_views.append(set.arena, .{
                .specifier = try std.fmt.allocPrint(set.arena, "@publr/admin/{s}.ptsx", .{stem}),
                .filename = label,
            });
        }

        try set.compile(source, label);
    }
}

/// The import closure: every value import that is not the runtime must be a compiled
/// module; a design-system stem that is not yet compiled is compiled now, and the loop
/// runs until nothing new appears.
fn compile_imports(set: *Set) !void {
    std.debug.assert(set.modules.items.len > 0);

    if (set.components.count() == 0) {
        return report(error.NoComponents, set.components_dir_path);
    }

    var next: u32 = 0;

    while (next < set.modules.items.len) : (next += 1) {
        const module = set.modules.items[next];

        for (module.component.imports) |import| {
            if (is_runtime(import.source) or !imports_values(import)) {
                continue;
            }

            const stem = stem_of(import.source);

            if (set.has(stem) or std.mem.eql(u8, stem, sprite_stem)) {
                continue;
            }

            const path = set.components.get(stem) orelse {
                std.debug.print("pjsx_gen: {s} imports \"{s}\", which is neither a view " ++
                    "nor a design-system component\n", .{ module.component.name, import.source });

                return error.UnresolvedImport;
            };
            const source = try set.components_dir.readFileAlloc(
                set.io,
                path,
                set.arena,
                .limited(file_bytes_max),
            );
            const marked = try mark_design_system(set.arena, source, stem);
            const label = try std.fs.path.join(set.arena, &.{ set.components_dir_path, path });
            try set.compile(marked, label);
        }
    }
}

/// Audit aid: the root element of a design-system component gets `data-ds="<Stem>"`, so
/// the admin stylesheet can outline what the design system draws. A root that is another
/// component or a fragment is left alone; the component it wraps carries the mark. A
/// `Dynamic` root forwards its attributes, so it is marked like an intrinsic.
fn mark_design_system(arena: std.mem.Allocator, source: []const u8, stem: []const u8) ![]const u8 {
    std.debug.assert(stem.len > 0);
    std.debug.assert(source.len <= file_bytes_max);

    const function_at = std.mem.indexOf(u8, source, "export function ") orelse return source;
    const return_at = std.mem.indexOfPos(u8, source, function_at, "return (") orelse return source;
    var tag_at = return_at + "return (".len;

    while (tag_at < source.len and std.ascii.isWhitespace(source[tag_at])) {
        tag_at += 1;
    }

    if (tag_at + 1 >= source.len or source[tag_at] != '<') {
        return source;
    }

    const dynamic_root = std.mem.startsWith(u8, source[tag_at..], "<Dynamic");

    if (!std.ascii.isLower(source[tag_at + 1]) and !dynamic_root) {
        return source;
    }

    var name_end = tag_at + 1;

    while (name_end < source.len) : (name_end += 1) {
        const byte = source[name_end];

        if (!std.ascii.isAlphanumeric(byte) and byte != '-') {
            break;
        }
    }

    std.debug.assert(name_end > tag_at + 1);

    return std.fmt.allocPrint(arena, "{s} data-ds=\"{s}\"{s}", .{
        source[0..name_end],
        stem,
        source[name_end..],
    });
}

fn imports_values(import: anytype) bool {
    std.debug.assert(import.source.len > 0);
    std.debug.assert(import.names.len <= 256);

    for (import.names) |name| {
        if (!name.type_only) {
            return true;
        }
    }

    return false;
}

/// One `<symbol>` per icon the compiled set names, as a component the shell renders once.
fn compile_sprite(set: *Set, ui_dirs: []const []const u8, icons_dir_path: []const u8) !void {
    std.debug.assert(icons_dir_path.len > 0);
    std.debug.assert(set.modules.items.len > 0);

    var icons_dir = try std.Io.Dir.cwd().openDir(set.io, icons_dir_path, .{});
    defer icons_dir.close(set.io);

    var names: std.ArrayList([]const u8) = .empty;
    try names.append(set.arena, icon_always);

    for (set.sources.items) |source| {
        try collect_icon_names(set.arena, source, &names);
    }

    for (ui_dirs) |ui_dir_path| {
        try collect_runtime_icons(set, ui_dir_path, &names);
    }

    std.mem.sort([]const u8, names.items, {}, less_than);

    var out: std.Io.Writer.Allocating = .init(set.arena);
    try out.writer.writeAll("export function IconSprite() {\n  return (\n" ++
        "    <svg id=\"publr-icon-sprite\" " ++
        // Hidden by size, never `display:none`: an icon's clip paths and masks would not
        // render from a sprite that is not displayed.
        "style=\"position:absolute;width:0;height:0;overflow:hidden\" aria-hidden=\"true\">\n");

    for (names.items) |name| {
        try write_symbol(set, icons_dir, name, &out.writer);
    }

    try out.writer.writeAll("    </svg>\n  );\n}\n");
    try set.compile(out.written(), sprite_stem ++ ".ptsx");
}

/// `<ui_dir>/icons.txt`: the icons a page names at runtime (`name={row.icon}`), which the
/// source scan cannot see. One name per line; absent when nothing needs it.
fn collect_runtime_icons(
    set: *Set,
    ui_dir_path: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(ui_dir_path.len > 0);
    std.debug.assert(names.items.len >= 1);

    const path = try std.fs.path.join(set.arena, &.{ ui_dir_path, "icons.txt" });
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(set.io, path, set.arena, limit) catch |err| {
        return if (err == error.FileNotFound) {} else err;
    };
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \r\t");

        if (name.len == 0 or contains(names.items, name)) {
            continue;
        }

        if (names.items.len == icons_max) {
            return error.TooManyIcons;
        }

        try names.append(set.arena, try set.arena.dupe(u8, name));
    }
}

/// Every `name="..."` on an `<Icon` element in `source`, deduplicated into `names`.
fn collect_icon_names(
    arena: std.mem.Allocator,
    source: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(names.items.len <= icons_max);
    std.debug.assert(names.items.len >= 1);

    var at: usize = 0;

    while (std.mem.indexOfPos(u8, source, at, "<Icon")) |tag_at| {
        const tag_end = std.mem.indexOfScalarPos(u8, source, tag_at, '>') orelse break;
        const tag = source[tag_at..tag_end];
        at = tag_end;
        const name_at = std.mem.indexOf(u8, tag, "name=\"") orelse continue;
        const value = tag[name_at + "name=\"".len ..];
        const value_end = std.mem.indexOfScalar(u8, value, '"') orelse continue;
        const name = value[0..value_end];

        if (contains(names.items, name)) {
            continue;
        }

        if (names.items.len == icons_max) {
            return error.TooManyIcons;
        }

        try names.append(arena, try arena.dupe(u8, name));
    }
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);
    std.debug.assert(names.len <= icons_max);

    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) {
            return true;
        }
    }

    return false;
}

/// The icon's artwork without its `<svg>` wrapper, one line, under the sprite's id scheme.
fn write_symbol(set: *Set, icons_dir: std.Io.Dir, name: []const u8, out: *std.Io.Writer) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, name, '/') == null);

    const file = try std.fmt.allocPrint(set.arena, "{s}.svg", .{name});
    const svg = icons_dir.readFileAlloc(set.io, file, set.arena, .limited(file_bytes_max)) catch {
        std.debug.print("pjsx_gen: a view names the icon \"{s}\", which does not exist\n", .{name});

        return error.UnknownIcon;
    };
    const open_end = std.mem.indexOfScalar(u8, svg, '>') orelse return error.MalformedSvg;
    const close = std.mem.lastIndexOf(u8, svg, "</svg>") orelse return error.MalformedSvg;
    const body = std.mem.trim(u8, svg[open_end + 1 .. close], " \t\r\n");

    try out.print(
        "      <symbol id=\"publr-icon-{s}\" viewBox=\"0 0 24 24\" fill=\"none\">",
        .{name},
    );
    var lines = std.mem.tokenizeAny(u8, body, "\r\n");

    while (lines.next()) |line| {
        try out.writeAll(std.mem.trim(u8, line, " \t"));
    }

    try out.writeAll("</symbol>\n");
}

/// The whole set through the `zig` target, one file per module plus the three
/// program-wide files.
fn lower(set: *Set, out_dir: std.Io.Dir) !void {
    std.debug.assert(set.modules.items.len > 0);
    std.debug.assert(set.modules.items.len <= modules_max);

    const arena = set.arena;

    try layouts.check(set.modules.items);

    var program = pjsx.targets.zig.Program.init(arena, set.modules.items) catch |err| {
        return report(err, "program");
    };

    program.request = pjsx.targets.zig.requestFields(request.Shape(ShapeNode));
    // Root paths in URL attributes go under the path the project is served at.
    program.url_base = "admin.base";

    for (set.modules.items) |module| {
        const name = module.component.name;
        const code = program.lower(arena, name) catch |err| return report(err, name);
        const file_name = try std.fmt.allocPrint(arena, "{s}.zig", .{name});
        try out_dir.writeFile(set.io, .{ .sub_path = file_name, .data = code });
    }

    const views = program.viewsFile(arena) catch |err| return report(err, "views.zig");
    const classes = program.classesFile(arena) catch |err| return report(err, "classes.txt");
    var browser: std.Io.Writer.Allocating = .init(arena);
    try browser_imports(set, &browser.writer);
    try browser.writer.writeAll(try program.storesFile(arena));
    const stores = browser.written();
    try out_dir.writeFile(set.io, .{ .sub_path = "views.zig", .data = views });
    try out_dir.writeFile(set.io, .{ .sub_path = "classes.txt", .data = classes });
    try out_dir.writeFile(set.io, .{ .sub_path = "stores.js", .data = stores });
}

fn is_runtime(source: []const u8) bool {
    return std.mem.eql(u8, source, runtime_import) or
        std.mem.eql(u8, source, "publr") or std.mem.startsWith(u8, source, "publr/");
}

fn browser_imports(set: *Set, writer: *std.Io.Writer) !void {
    std.debug.assert(set.modules.items.len > 0);
    std.debug.assert(set.modules.items.len <= modules_max);

    var seen: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (set.modules.items) |module| {
        for (module.component.imports) |entry| {
            if (!is_runtime(entry.source)) {
                continue;
            }

            const source = if (std.mem.eql(u8, entry.source, "publr"))
                "./publr.js"
            else if (std.mem.startsWith(u8, entry.source, "publr/"))
                try std.fmt.allocPrint(set.arena, "./publr-{s}.js", .{entry.source[6..]})
            else
                continue;

            for (entry.names) |name| {
                if (name.type_only or std.mem.eql(u8, name.local, "Publr")) {
                    continue;
                }

                const signature = try std.fmt.allocPrint(set.arena, "{s}:{s}", .{
                    source, name.imported,
                });
                const found = try seen.getOrPut(set.arena, name.local);

                if (found.found_existing) {
                    if (!std.mem.eql(u8, found.value_ptr.*, signature)) {
                        return error.ConflictingBrowserImport;
                    }

                    continue;
                }

                found.value_ptr.* = signature;
                try writer.print("import {{ {s} as {s} }} from \"{s}\";\n", .{
                    name.imported, name.local, source,
                });
            }
        }
    }
}

fn usage() u8 {
    std.debug.print("usage: pjsx_gen <ui_dir> <components_dir> <icons_dir> <out_dir> " ++
        "[<plugin_ui_dir> ...]\n", .{});

    return 2;
}

/// The compiler's diagnostic is the message; anything else is named as-is.
fn report(err: anyerror, name: []const u8) error{Failed} {
    std.debug.assert(name.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    if (err == error.Pjsx) {
        std.debug.print("pjsx_gen: {s}: {s}\n", .{ name, pjsx.lastError() });
    } else {
        std.debug.print("pjsx_gen: {s}: {s}\n", .{ name, @errorName(err) });
    }

    return error.Failed;
}

/// `Button/Button.ptsx` for the stem `Button`.
fn is_canonical(path: []const u8, stem: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(stem.len > 0);

    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    const family = path[0..slash];
    const file = path[slash + 1 ..];

    return std.mem.eql(u8, family, stem) and
        std.mem.eql(u8, file[0..@min(file.len, stem.len)], stem) and
        std.mem.eql(u8, file[stem.len..], ".ptsx");
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// `@publr/ui/Dropdown.ptsx` → `Dropdown`; `Button/Button.ptsx` → `Button`.
fn stem_of(source: []const u8) []const u8 {
    std.debug.assert(source.len > 0);

    const slash = std.mem.lastIndexOfScalar(u8, source, '/');
    const start = if (slash) |index| index + 1 else 0;
    const dot = std.mem.indexOfScalarPos(u8, source, start, '.') orelse source.len;

    std.debug.assert(dot >= start);

    return source[start..dot];
}

test "the exported component name is read off the source" {
    const source = "x\nexport function SidebarRail({ props }: Props) {}";
    try std.testing.expectEqualStrings("SidebarRail", exported_component(source).?);
    try std.testing.expect(exported_component("const value = 1;") == null);
}

test "stems drop the path and the extension" {
    try std.testing.expectEqualStrings("Button", stem_of("@publr/ui/Button.ptsx"));
    try std.testing.expectEqualStrings("Button", stem_of("Button/Button.ptsx"));
    try std.testing.expectEqualStrings("Layout", stem_of("./Layout.ptsx"));
}

test "icon names are collected from Icon elements only, once each" {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    try names.append(std.testing.allocator, icon_always);
    const source = "<Icon name=\"grid\" size=\"sm\" /> <Icon name=\"grid\"/> " ++
        "<Input name=\"q\" /> <Icon\n name=\"file\">";
    try collect_icon_names(std.testing.allocator, source, &names);
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("grid", names.items[1]);
    try std.testing.expectEqualStrings("file", names.items[2]);

    for (names.items[1..]) |name| {
        std.testing.allocator.free(name);
    }
}
