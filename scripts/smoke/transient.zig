//! A transient plugin: `serve --plugin` loads it for that server only, its operations answer
//! through the server, and once the server stops nothing of it is in the site. The same
//! server names where it is synced (`--sync-url`) in `/api/health`.
const std = @import("std");
const smoke = @import("../smoke.zig");

const sync_url = "https://sync.example.test:8443/smoke";

pub fn expect_transient(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    module: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(module));

    const dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/transient", .{work_dir});
    const setup = [_][]const u8{
        "project",
        "init",
        "--email",
        "transient@example.com",
        "--display_name",
        "Transient",
        "--password",
        "transient smoke pass",
    };
    const greet = [_][]const u8{ "--as-admin", "greeter", "greet", "--note", "transient" };
    const list = [_][]const u8{ "--as-admin", "plugin", "list" };

    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try smoke.expect_contains(init, binary, dir, &setup, "\"roles\": [");

    {
        var child = try std.process.spawn(init.io, .{
            .argv = &.{
                binary,     "serve", "--port",     "8096",
                "--plugin", module,  "--sync-url", sync_url,
            },
            .cwd = .{
                .path = dir,
            },
            .stdout = .ignore,
            .stderr = .pipe,
        });
        defer child.kill(init.io);

        const port = try smoke.read_port(init, child.stderr.?);
        const health = try smoke.http_get(init, port, "/api/health");

        try expect_in("health sync", health, sync_url);
        try smoke.expect_contains(init, binary, dir, &greet, "\"total\": 1");
    }

    const listed = try smoke.run_publr(init, binary, dir, &list);

    if (std.mem.indexOf(u8, listed.stdout, "greeter") != null) {
        std.debug.print("smoke: transient: greeter stayed in the site: {s}\n", .{listed.stdout});
        return error.SmokeFailed;
    }
}

fn expect_in(what: []const u8, text: []const u8, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);

    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("smoke: {s}: missing {s} in {s}\n", .{ what, needle, text });
        return error.SmokeFailed;
    }
}
