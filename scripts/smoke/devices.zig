//! A device signing in by link against the running server: asked over HTTP, approved by its
//! person from the CLI, its token claimed once; then that token naming the device and sending
//! commands through `/api/cli`, a destroying one listed, and the approve page behind the
//! sign-in.
const std = @import("std");
const smoke = @import("../smoke.zig");

const Started = struct {
    device_code: []const u8,
    user_code: []const u8,
};
const Claimed = struct {
    token: []const u8,
};

const email = "device@example.com";

pub fn expect_devices(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/devices", .{work_dir});
    const setup = [_][]const u8{
        "project",
        "init",
        "--email",
        email,
        "--display_name",
        "Device",
        "--password",
        "device smoke pass",
    };

    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try smoke.expect_contains(init, binary, dir, &setup, "\"roles\": [");

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8093" },
        .cwd = .{
            .path = dir,
        },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    const port = try smoke.read_port(init, child.stderr.?);

    try expect_signed_in(init, binary, dir, port);
}

/// Asked over HTTP, approved by its person from the CLI, its token claimed once.
fn expect_signed_in(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    port: u16,
) !void {
    std.debug.assert(port > 0);

    const arena = init.arena.allocator();
    const asked = "{\"name\":\"smoke device\"}";
    const start = try smoke.http_post(init, port, "/api/device.start", asked);
    const started = try body_as(Started, arena, start);
    const approve = [_][]const u8{
        "--as",   email,             "device",  "approve",
        "--code", started.user_code, "--scope", "production",
    };

    try smoke.expect_contains(init, binary, work_dir, &approve, "\"approved\": true");

    const code = try std.fmt.allocPrint(arena, "{{\"device_code\":\"{s}\"}}", .{
        started.device_code,
    });
    const polled = try smoke.http_post(init, port, "/api/device.poll", code);

    try expect_in("device poll", polled, "\"state\":\"approved\"");

    const claim = try smoke.http_post(init, port, "/api/device.claim", code);
    const claimed = try body_as(Claimed, arena, claim);

    try expect_remote(init, port, claimed.token);

    const page = try smoke.http_get(init, port, "/admin/settings/devices/approve?code=BCDF-GHJK");

    try expect_in("approve page signed out", page, "Location: /admin/login?return=");
}

/// The device's token at the site: it names the device, sends commands through `/api/cli`
/// (what the `publr` command's `--site` uses), and a destroying one is listed, never run.
fn expect_remote(
    init: std.process.Init,
    port: u16,
    token: []const u8,
) !void {
    std.debug.assert(token.len > 0);
    std.debug.assert(port > 0);

    const arena = init.arena.allocator();
    const bearer = try std.fmt.allocPrint(arena, "Authorization: Bearer {s}\r\n", .{token});
    const devices = try smoke.http_post_headers(init, port, "/api/device.list", bearer, "{}");

    try expect_in("device.list", devices, "smoke device");

    const types = try smoke.http_post_headers(
        init,
        port,
        "/api/cli",
        bearer,
        "{\"args\":[\"content_type\",\"list\"]}",
    );

    try expect_in("/api/cli content_type list", types, "types");

    // Final, so not run: listed for the device's person (a missing record is listed too:
    // the person's own removal finds it gone).
    const purge = try smoke.http_post_headers(
        init,
        port,
        "/api/cli",
        bearer,
        "{\"args\":[\"record\",\"purge\",\"--id\",\"0190a1b2c3d40001a1b2c3d4\"]}",
    );

    try expect_in("/api/cli record purge", purge, "Listed for removal");

    const list_words = "{\"args\":[\"content_type\",\"list\"]}";
    const anonymous = try smoke.http_post(init, port, "/api/cli", list_words);

    try expect_in("/api/cli signed out", anonymous, "device_required");
}

/// The JSON body of a raw HTTP answer.
fn body_as(comptime Body: type, arena: std.mem.Allocator, answer: []const u8) !Body {
    std.debug.assert(answer.len > 0);

    const start = std.mem.indexOf(u8, answer, "\r\n\r\n") orelse return error.SmokeFailed;

    return @import("publr_api").result(Body, arena, answer[start + 4 ..]);
}

fn expect_in(what: []const u8, text: []const u8, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);

    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("smoke: {s}: missing {s} in {s}\n", .{ what, needle, text });
        return error.SmokeFailed;
    }
}
