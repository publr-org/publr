//! A site's data moved from the outside: `site export` in one folder, `site import` of it in
//! another, a second import there refused, and an export into a folder that is not empty
//! refused.
const std = @import("std");
const smoke = @import("../smoke.zig");

pub fn expect_bundles(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const arena = init.arena.allocator();
    const source = try std.fmt.allocPrint(arena, "{s}/bundle-source", .{work_dir});
    const target = try std.fmt.allocPrint(arena, "{s}/bundle-target", .{work_dir});
    const exported = try std.fmt.allocPrint(arena, "{s}/bundle-export", .{work_dir});
    const setup = [_][]const u8{
        "project",
        "init",
        "--email",
        "bundle@example.com",
        "--display_name",
        "Bundle",
        "--password",
        "bundle smoke pass",
    };
    const export_words = [_][]const u8{ "site", "export", "--to", exported };
    const import_words = [_][]const u8{ "site", "import", "--from", exported };

    try std.Io.Dir.cwd().createDirPath(init.io, source);
    try std.Io.Dir.cwd().createDirPath(init.io, target);
    try smoke.expect_contains(init, binary, source, &setup, "\"roles\": [");
    try smoke.expect_contains(init, binary, source, &export_words, "Exported");
    try smoke.expect_failure(init, binary, source, &export_words, "the folder is not empty");
    try smoke.expect_contains(init, binary, target, &import_words, "Imported");
    try smoke.expect_contains(init, binary, target, &.{ "db", "tables" }, "users 1 core");
    try smoke.expect_failure(init, binary, target, &import_words, "has a site already");
}
