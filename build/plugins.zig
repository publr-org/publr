const std = @import("std");

pub const dir_default = "plugins";
pub const plugins_max: u32 = 64;
pub const name_len_max: u32 = 32;

pub fn add(builder: *std.Build, library: *std.Build.Module, dir: []const u8) void {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(library.root_source_file != null);

    var names_storage: [plugins_max][]const u8 = undefined;
    const names = discover(builder, dir, &names_storage);
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

    for (names) |name| {
        const plugin = builder.createModule(.{
            .root_source_file = builder.path(builder.fmt("{s}/{s}/main.zig", .{ dir, name })),
            .target = library.resolved_target,
            .optimize = library.optimize,
        });

        plugin.addImport("publr", library);
        plugins.addImport(name, plugin);
    }

    library.addImport("plugins", plugins);
}

pub fn add_tests(
    builder: *std.Build,
    library: *std.Build.Module,
    dir: []const u8,
    test_step: *std.Build.Step,
) void {
    std.debug.assert(library.root_source_file != null);
    std.debug.assert(plugins_max > 0);

    const listing = library.import_table.get("plugins") orelse @panic("plugins not added");
    var names_storage: [plugins_max][]const u8 = undefined;

    for (discover(builder, dir, &names_storage)) |name| {
        const module = listing.import_table.get(name) orelse @panic("plugin module missing");
        const tests = builder.addTest(.{ .root_module = module });

        test_step.dependOn(&builder.addRunArtifact(tests).step);
    }
}

fn discover(
    builder: *std.Build,
    dir: []const u8,
    storage: *[plugins_max][]const u8,
) []const []const u8 {
    std.debug.assert(storage.len == plugins_max);
    std.debug.assert(dir.len > 0);

    const io = builder.graph.io;
    var root = builder.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch {
        if (!std.mem.eql(u8, dir, dir_default)) {
            @import("diagnostic.zig").fail("-Dplugins: no folder at {s}", .{dir});
        }

        return &.{};
    };
    defer root.close(io);

    var iterator = root.iterate();
    var count: u32 = 0;

    while (iterator.next(io) catch null) |entry| {
        // A link counts: a plugins folder may gather plugins kept elsewhere. The main.zig
        // check below follows it, and skips a link to anything but a plugin's folder.
        const folder = entry.kind == .directory or entry.kind == .sym_link;

        if (!folder or !valid_name(entry.name)) {
            continue;
        }

        const main_path = builder.fmt("{s}/main.zig", .{entry.name});
        root.access(io, main_path, .{}) catch continue;

        if (count == plugins_max) {
            @panic("too many plugins");
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
