const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const dir_default = "plugins";
pub const plugins_max: u32 = 64;
pub const name_len_max: u32 = 32;

/// Which plugins are compiled in: every one (`.native = .all`) or those `publr.zon` names.
/// The rest are built for the sandbox. With no `publr.zon`, none are compiled in.
pub const Native = union(enum) {
    all,
    names: []const []const u8,
};

/// `publr.zon` beside the plugins folder, at the project's root:
/// `.plugins = .{ .native = .{ "blog" } }` or `.plugins = .{ .native = .all }`.
pub fn native_of(builder: *std.Build, plugins_dir: []const u8) Native {
    std.debug.assert(plugins_dir.len > 0);

    const root = std.fs.path.dirname(plugins_dir) orelse ".";
    const path = builder.pathJoin(&.{ root, "publr.zon" });
    const io = builder.graph.io;
    const limit: std.Io.Limit = .limited(1 << 16);
    const handle = builder.build_root.handle;
    const text = handle.readFileAllocOptions(io, path, builder.allocator, limit, .of(u8), 0) catch {
        return .{ .names = &.{} };
    };
    const Listed = struct { plugins: struct { native: []const []const u8 = &.{} } = .{} };
    const Every = struct { plugins: struct { native: enum { all } } };
    // Strict: a misspelt field fails the build rather than compiling nothing in.
    const options: std.zon.parse.Options = .{};

    if (std.zon.parse.fromSliceAlloc(Listed, builder.allocator, text, null, options)) |listed| {
        return .{ .names = listed.plugins.native };
    } else |_| {}

    _ = std.zon.parse.fromSliceAlloc(Every, builder.allocator, text, null, options) catch {
        diagnostic.fail("{s}: `.plugins.native` is a list of plugin names, or `.all`", .{path});
    };

    return .all;
}

/// The plugins under `dir` that `native` compiles in, as the `native_plugins` module the
/// library imports. A name `publr.zon` lists that `dir` lacks fails the build.
pub fn add(builder: *std.Build, library: *std.Build.Module, dir: []const u8, native: Native) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    var names_storage: [plugins_max][]const u8 = undefined;
    const names = compiled_in(builder, dir, native, &names_storage);
    const listing = builder.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;

    source.appendSlice(builder.allocator, "pub const all = .{\n") catch @panic("OOM");

    for (names) |name| {
        source.appendSlice(builder.allocator, builder.fmt("    @import(\"{s}\"),\n", .{name})) catch
            @panic("OOM");
    }

    source.appendSlice(builder.allocator, "};\n") catch @panic("OOM");

    const root = listing.add("plugins.zig", source.items);
    const plugins = builder.createModule(.{
        .root_source_file = root,
        .target = library.resolved_target,
        .optimize = library.optimize,
    });

    var modules: [plugins_max]*std.Build.Module = undefined;

    for (names, 0..) |name, index| {
        const plugin = builder.createModule(.{
            .root_source_file = builder.path(builder.fmt("{s}/{s}/main.zig", .{ dir, name })),
            .target = library.resolved_target,
            .optimize = library.optimize,
        });

        plugin.addImport("publr", library);
        plugins.addImport(name, plugin);
        modules[index] = plugin;
    }

    add_interfaces(builder, library, dir, names, modules[0..names.len]);
    library.addImport("native_plugins", plugins);
}

/// A plugin's own `interface.zig`, its operations' names and shapes, imported under its
/// name by its own files: `@import("newsletter")` inside newsletter. Another plugin never
/// imports it: it declares the contract it uses (`publr.plugin.Remote`), checked against
/// this one when both are compiled in, and when they are installed.
fn add_interfaces(
    builder: *std.Build,
    library: *std.Build.Module,
    dir: []const u8,
    names: []const []const u8,
    modules: []const *std.Build.Module,
) void {
    std.debug.assert(names.len == modules.len);

    for (names, 0..) |name, index| {
        const path = builder.fmt("{s}/{s}/interface.zig", .{ dir, name });

        builder.build_root.handle.access(builder.graph.io, path, .{}) catch continue;

        const interface = builder.createModule(.{
            .root_source_file = builder.path(path),
            .target = library.resolved_target,
            .optimize = library.optimize,
        });

        interface.addImport("publr", library);

        modules[index].addImport(name, interface);
    }
}

/// Whether `name` is compiled in.
pub fn is_native(native: Native, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    return switch (native) {
        .all => true,
        .names => |names| for (names) |listed| {
            if (std.mem.eql(u8, listed, name)) {
                break true;
            }
        } else false,
    };
}

/// The `ui/` folders of the plugins `native` compiles in, relative to this repository:
/// their views lower with the admin's.
pub fn ui_dirs(builder: *std.Build, dir: []const u8, native: Native) []const []const u8 {
    std.debug.assert(dir.len > 0);

    var names_storage: [plugins_max][]const u8 = undefined;
    const names = compiled_in(builder, dir, native, &names_storage);
    var found: std.ArrayList([]const u8) = .empty;

    for (names) |name| {
        const ui = builder.pathJoin(&.{ dir, name, "ui" });
        var handle = builder.build_root.handle.openDir(builder.graph.io, ui, .{}) catch continue;

        handle.close(builder.graph.io);
        found.append(builder.allocator, ui) catch @panic("OOM");
    }

    std.debug.assert(found.items.len <= names.len);

    return found.items;
}

fn compiled_in(
    builder: *std.Build,
    dir: []const u8,
    native: Native,
    storage: *[plugins_max][]const u8,
) []const []const u8 {
    std.debug.assert(dir.len > 0);

    const found = discover(builder, dir, storage);

    if (native == .names) {
        for (native.names) |listed| {
            const present = for (found) |name| {
                if (std.mem.eql(u8, name, listed)) {
                    break true;
                }
            } else false;

            if (!present) {
                diagnostic.fail("publr.zon lists {s}, which {s} does not have", .{ listed, dir });
            }
        }
    }

    var count: u32 = 0;

    for (found) |name| {
        if (is_native(native, name)) {
            storage[count] = name;
            count += 1;
        }
    }

    return storage[0..count];
}

pub fn add_tests(builder: *std.Build, library: *std.Build.Module, test_step: *std.Build.Step) void {
    std.debug.assert(library.root_source_file != null);
    std.debug.assert(plugins_max > 0);

    const listing = library.import_table.get("native_plugins") orelse
        @panic("native plugins not added");

    for (listing.import_table.values()) |module| {
        const tests = builder.addTest(.{ .root_module = module });

        test_step.dependOn(&builder.addRunArtifact(tests).step);
    }
}

pub fn discover(
    builder: *std.Build,
    dir: []const u8,
    storage: *[plugins_max][]const u8,
) []const []const u8 {
    std.debug.assert(storage.len == plugins_max);
    std.debug.assert(dir.len > 0);

    const io = builder.graph.io;
    var root = builder.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch {
        if (!std.mem.eql(u8, dir, dir_default)) {
            diagnostic.fail("-Dplugins: no folder at {s}", .{dir});
        }

        return &.{};
    };
    defer root.close(io);

    var iterator = root.iterate();
    var count: u32 = 0;

    while (iterator.next(io) catch null) |entry| {
        // A link counts: a native plugins folder may gather plugins kept elsewhere. The main.zig
        // check below follows it, and skips a link to anything but a plugin's folder.
        const folder = entry.kind == .directory or entry.kind == .sym_link;

        if (!folder or !valid_name(entry.name)) {
            continue;
        }

        const main_path = builder.fmt("{s}/main.zig", .{entry.name});
        root.access(io, main_path, .{}) catch continue;

        if (count == plugins_max) {
            @panic("too many native plugins");
        }

        storage[count] = builder.dupe(entry.name);
        count += 1;
    }

    std.mem.sort([]const u8, storage[0..count], {}, less_than);

    return storage[0..count];
}

fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    std.debug.assert(name.len <= name_len_max);

    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or char == '_';

        if (!ok) {
            return false;
        }
    }

    return name[0] >= 'a' and name[0] <= 'z';
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    std.debug.assert(left.len > 0);
    std.debug.assert(right.len > 0);

    return std.mem.lessThan(u8, left, right);
}
