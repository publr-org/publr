//! A site in one file from the outside: `pack` in one folder, `unpack` in another, a second
//! `unpack` there refused, and `cloud deploy` refused without the account's token.
const std = @import("std");
const smoke = @import("../smoke.zig");

pub fn expect_bundles(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const arena = init.arena.allocator();
    const source = try std.fmt.allocPrint(arena, "{s}/bundle-source", .{work_dir});
    const target = try std.fmt.allocPrint(arena, "{s}/bundle-target", .{work_dir});
    const file = try std.fmt.allocPrint(arena, "{s}/site.site.tar.gz", .{source});
    const password = "bundle smoke pass";
    const setup = [_][]const u8{
        "init",
        "--email",
        "bundle@example.com",
        "--display_name",
        "Bundle",
        "--password",
        password,
    };
    const deploy = [_][]const u8{ "cloud", "deploy", "--space", "s", "--slug", "smoke-site" };

    try std.Io.Dir.cwd().createDirPath(init.io, source);
    try std.Io.Dir.cwd().createDirPath(init.io, target);
    try smoke.expect_contains(init, binary, source, &setup, "\"roles\": [");
    try smoke.expect_contains(init, binary, source, &.{ "pack", file }, "Packed");
    try smoke.expect_contains(init, binary, target, &.{ "unpack", file }, "Unpacked bundle-source");
    try smoke.expect_contains(init, binary, target, &.{ "db", "tables" }, "users 1 core");
    try smoke.expect_failure(init, binary, target, &.{ "unpack", file }, "has a site already");
    try smoke.expect_failure(init, binary, source, &deploy, "PUBLR_CLOUD_TOKEN");
}
