//! The sandbox from the command line: a plugin added from its file and enabled, its
//! operation called as the operator and refused to nobody, and listed.
const std = @import("std");
const smoke = @import("../smoke.zig");

pub fn expect_sandboxed_plugins(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    module: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(module));

    const add = [_][]const u8{ "--as-admin", "plugin", "add", "--file", module };
    const enable = [_][]const u8{ "--as-admin", "plugin", "enable", "--name", "greeter" };
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
