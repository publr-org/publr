//! The published interfaces a plugin builds against: asked of the site it builds for
//! (`plugin interfaces`, here or at `--site`), those of `--with` packages over them, each
//! written beside the build as a module under its plugin's name: the interface as data
//! (`<name>.zon`) and what a plugin imports (`<name>.zig`, its contracts to provide).
const std = @import("std");
const wasm = @import("publr_wasm");
const published = @import("../../sdk/published.zig");
const plugin_manifest = @import("../../sdk/plugin/manifest.zig");
const state = @import("../../operations/plugin/state.zig");
const report = @import("../../lib/report.zig");
const doc_reader = @import("../../sdk/plugin/doc_reader.zig");
const Manifest = @import("../../model/sandboxed_plugin.zig").Manifest;

const page_size: u32 = 200;
/// Plugins on one site at most, built in and installed.
const plugins_max: u32 = 600;
const module_bytes_max: u32 = 16 << 20;
const answer_bytes_max: u32 = 16 << 20;

/// The modules written for one build: the folder, and the plugins in it by name.
pub const Modules = struct {
    dir: []const u8,
    names: []const []const u8,
};

/// Names a plugin's module never takes: the build's own modules.
const taken = [_][]const u8{
    "std",              "builtin", "root",    "publr", "plugin",      "plugin_docs", "plugin_views",
    "plugin_published", "runtime", "request", "ds",    "class_merge",
};

/// Every plugin's interface the site answers, a page at a time. `asker.ask(words, out)` runs
/// a command against the site and writes its answer.
pub fn asked(arena: std.mem.Allocator, asker: anytype) ![]const published.Interface {
    const Page = struct {
        interfaces: []const published.Interface = &.{},
        more: bool = false,
    };
    var found: std.ArrayList(published.Interface) = .empty;
    var offset: u32 = 0;

    comptime std.debug.assert(page_size <= plugins_max);

    while (offset < plugins_max) : (offset += page_size) {
        var answer: std.Io.Writer.Allocating = .init(arena);
        const at = try std.fmt.allocPrint(arena, "{d}", .{offset});
        const limit = try std.fmt.allocPrint(arena, "{d}", .{page_size});
        const words = [_][]const u8{ "plugin", "interfaces", "--limit", limit, "--offset", at };

        if (try asker.ask(&words, &answer.writer) != 0) {
            report.err("publr plugin build: the site did not list its plugins' interfaces", .{});
            return error.Unavailable;
        }

        const page = std.json.parseFromSliceLeaky(Page, arena, answer.written(), .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            report.err("publr plugin build: the site's interfaces could not be read", .{});
            return error.Unavailable;
        };

        try found.appendSlice(arena, page.interfaces);

        if (!page.more) {
            break;
        }
    }

    return found.items;
}

/// `there` with each `--with` package's interface over the one of the same name.
pub fn with_packages(
    init: std.process.Init,
    there: []const published.Interface,
    with: []const []const u8,
) ![]const published.Interface {
    const arena = init.arena.allocator();
    var all: std.ArrayList(published.Interface) = .empty;

    try all.appendSlice(arena, there);

    for (with) |path| {
        const interface = package_interface(init, path) catch |err| {
            report.err("publr plugin build: --with {s}: {t}", .{ path, err });
            return err;
        };
        const index = for (all.items, 0..) |each, at| {
            if (std.mem.eql(u8, each.plugin, interface.plugin)) {
                break at;
            }
        } else null;

        if (index) |at| {
            all.items[at] = interface;
        } else {
            try all.append(arena, interface);
        }
    }

    return all.items;
}

/// A built plugin's interface, from the manifest it carries.
fn package_interface(init: std.process.Init, path: []const u8) !published.Interface {
    std.debug.assert(path.len > 0);

    const manifest = try manifest_of(init, path);

    return .{
        .plugin = manifest.name,
        .version = manifest.version,
        .contracts = manifest.contracts,
        .dimensions = manifest.dimensions,
    };
}

/// The manifest a built plugin carries in its module.
pub fn manifest_of(init: std.process.Init, path: []const u8) !Manifest {
    std.debug.assert(path.len > 0);

    const arena = init.arena.allocator();
    const limit: std.Io.Limit = .limited(module_bytes_max);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, limit);
    const text = (wasm.section.find(bytes, plugin_manifest.section_name) catch
        return error.NotAPlugin) orelse return error.NotAPlugin;

    std.debug.assert(text.len > 0);

    return state.parse_manifest(arena, text);
}

/// Each interface but the plugin's own written into `<built>.published/`, with `all.zig`
/// listing them.
pub fn write(
    init: std.process.Init,
    built: []const u8,
    own: []const u8,
    interfaces: []const published.Interface,
) !Modules {
    std.debug.assert(built.len > 0);
    std.debug.assert(own.len > 0);

    const arena = init.arena.allocator();
    const dir = try std.fmt.allocPrint(arena, "{s}.published", .{built});
    const cwd = std.Io.Dir.cwd();
    var names: std.ArrayList([]const u8) = .empty;
    var listing: std.Io.Writer.Allocating = .init(arena);

    try cwd.createDirPath(init.io, dir);
    try listing.writer.writeAll("//! The published interfaces this build has, one per plugin.\n" ++
        "pub const all = [_]@import(\"publr\").published.Interface{\n");

    for (interfaces) |interface| {
        if (std.mem.eql(u8, interface.plugin, own) or is_taken(interface.plugin)) {
            continue;
        }

        var data: std.Io.Writer.Allocating = .init(arena);

        try std.zon.stringify.serialize(interface, .{}, &data.writer);
        try data.writer.writeByte('\n');
        try write_file(init, dir, interface.plugin, ".zon", data.written());
        try write_file(init, dir, interface.plugin, ".zig", try std.fmt.allocPrint(arena,
            \\//! {0s} {1s}'s published interface, as the site it builds for has it.
            \\const publr = @import("publr");
            \\
            \\pub const interface: publr.published.Interface = @import("{0s}.zon");
            \\pub const contracts = publr.published.contracts(interface){{}};
            \\
        , .{ interface.plugin, interface.version }));
        try listing.writer.print("    @import(\"{s}\").interface,\n", .{interface.plugin});
        try names.append(arena, interface.plugin);
    }

    try listing.writer.writeAll("};\n");
    try write_file(init, dir, "all", ".zig", listing.written());

    return .{
        .dir = dir,
        .names = names.items,
    };
}

/// A plugin a source file imports by name (`@import("payments")`) that has no interface
/// here; none when every such import has one. The plugin's own name and the build's own
/// modules are not plugins.
pub fn missing(
    files: []const doc_reader.File,
    own: []const u8,
    interfaces: []const published.Interface,
) ?[]const u8 {
    std.debug.assert(own.len > 0);

    const opening = "@import(\"";

    for (files) |file| {
        var at: usize = 0;

        while (std.mem.indexOfPos(u8, file.text, at, opening)) |found| {
            const start = found + opening.len;
            const end = std.mem.indexOfScalarPos(u8, file.text, start, '"') orelse break;
            const name = file.text[start..end];

            at = end;

            if (!std.mem.endsWith(u8, file.path, ".zig") or !is_plugin_name(name)) {
                continue;
            }

            if (std.mem.eql(u8, name, own) or is_taken(name) or known(interfaces, name)) {
                continue;
            }

            return name;
        }
    }

    return null;
}

fn is_plugin_name(name: []const u8) bool {
    std.debug.assert(name.len < 1 << 16);

    if (name.len == 0 or name.len > 32 or !std.ascii.isLower(name[0])) {
        return false;
    }

    for (name) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '_') {
            return false;
        }
    }

    return true;
}

fn known(interfaces: []const published.Interface, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (interfaces) |interface| {
        if (std.mem.eql(u8, interface.plugin, name)) {
            return true;
        }
    }

    return false;
}

fn write_file(
    init: std.process.Init,
    dir: []const u8,
    name: []const u8,
    extension: []const u8,
    data: []const u8,
) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(data.len <= answer_bytes_max);

    const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}{s}", .{
        dir,
        name,
        extension,
    });

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = data,
    });
}

fn is_taken(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (taken) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}
