//! A site's updates from the outside: what `db check` and `db tables` find, the backups and
//! a restore of one that is not there, `update status` from a running server, and the
//! Settings › Updates page behind the sign-in.
const std = @import("std");
const smoke = @import("../smoke.zig");

const email = "updates@example.com";
const password = "updates smoke pass";

pub fn expect_updates(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/updates", .{work_dir});
    const setup = [_][]const u8{
        "init", "--email", email, "--display_name", "Updates", "--password", password,
    };

    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try smoke.expect_contains(init, binary, dir, &setup, "\"roles\": [");
    try smoke.expect_contains(init, binary, dir, &.{ "db", "check" }, "would open it");
    try smoke.expect_contains(init, binary, dir, &.{ "db", "tables" }, "users 1 core");
    try smoke.expect_contains(init, binary, dir, &.{"backups"}, "No backups yet");
    try smoke.expect_failure(init, binary, dir, &.{ "restore", "nope" }, "no backup named");

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8096" },
        .cwd = .{
            .path = dir,
        },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    const port = try smoke.read_port(init, child.stderr.?);
    const status = [_][]const u8{ "--as-admin", "update", "status" };

    try smoke.expect_contains(init, binary, dir, &status, "\"step\": \"idle\"");
    try expect_page(init, port);
}

fn expect_page(init: std.process.Init, port: u16) !void {
    std.debug.assert(port > 0);

    const body = "{\"email\":\"" ++ email ++ "\",\"password\":\"" ++ password ++ "\"}";
    const answer = try smoke.http_post(init, port, "/api/auth/sign-in", body);
    const marker = "Set-Cookie: ";
    const start = (std.mem.indexOf(u8, answer, marker) orelse {
        std.debug.print("smoke: updates: sign-in set no cookie: {s}\n", .{answer});
        return error.SmokeFailed;
    }) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, answer, start, ';') orelse answer.len;
    const cookie = answer[start..end];
    const page = try smoke.http_get_cookie(init, port, "/admin/settings/updates", cookie);

    if (std.mem.indexOf(u8, page, "Check for updates") == null) {
        std.debug.print("smoke: updates: the page has no Check for updates: {s}\n", .{page});
        return error.SmokeFailed;
    }
}
