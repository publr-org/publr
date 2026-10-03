//! The sandbox from the command line: a plugin added from its file and enabled, its
//! operation called as the operator and refused to nobody, and listed.
const std = @import("std");
const smoke = @import("../smoke.zig");

/// A plugin built from its source by the compiler the binary carries, added and enabled;
/// built again unchanged, it is up to date.
pub fn expect_plugin_build(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    fixtures: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(fixtures));

    const arena = init.arena.allocator();
    const dir = try std.fmt.allocPrint(arena, "{s}/plugin-build", .{work_dir});
    const source = try std.fmt.allocPrint(arena, "{s}/greeter", .{fixtures});
    const build = [_][]const u8{ "plugin", "build", "--name", "greeter", "--dir", source };

    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try smoke.expect_contains(init, binary, dir, &build, "\"enabled\": true");
    try smoke.expect_contains(init, binary, dir, &build, "greeter is up to date");
}

pub fn expect_sandboxed_plugins(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    module: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(module));

    const add = [_][]const u8{ "--as-admin", "plugin", "add", "--file", module };
    const enable = [_][]const u8{ "--as-admin", "plugin", "enable", "--names", "greeter" };
    const greet = [_][]const u8{ "--as-admin", "greeter", "greet", "--note", "smoke" };
    const anonymous = [_][]const u8{ "greeter", "count" };
    const list = [_][]const u8{ "--as-admin", "plugin", "list" };
    const help = [_][]const u8{ "greeter", "greet", "--help" };

    try smoke.expect_contains(init, binary, work_dir, &add, "\"name\": \"greeter\"");
    try smoke.expect_contains(init, binary, work_dir, &enable, "\"enabled\": true");
    try smoke.expect_contains(init, binary, work_dir, &greet, "\"total\": 1");
    try smoke.expect_failure(init, binary, work_dir, &anonymous, "denied");
    try smoke.expect_contains(init, binary, work_dir, &list, "\"version\": \"0.1.0\"");
    try smoke.expect_contains(init, binary, work_dir, &help, "--note");
}
