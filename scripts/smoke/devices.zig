//! A device signing in by link against the running server: asked over HTTP, approved by its
//! person from the CLI, its token claimed once; then `publr --site` and `whoami` with that
//! token, a destroying command refused to it, and the approve page behind the sign-in.
const std = @import("std");
const smoke = @import("../smoke.zig");

const Started = struct { device_code: []const u8, user_code: []const u8 };
const Claimed = struct { token: []const u8 };

const email = "device@example.com";

pub fn expect_devices(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/devices", .{work_dir});
    const setup = [_][]const u8{
        "init", "--email", email, "--display_name", "Device", "--password", "device smoke pass",
    };

    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try smoke.expect_contains(init, binary, dir, &setup, "\"roles\": [");

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8093" },
        .cwd = .{ .path = dir },
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
    const start = try smoke.http_post(init, port, "/api/device/start", asked);
    const started = try body_as(Started, arena, start);
    const approve = [_][]const u8{
        "--as",   email,             "device",  "approve",
        "--code", started.user_code, "--scope", "drafts",
    };

    try smoke.expect_contains(init, binary, work_dir, &approve, "\"approved\": true");

    const code = try std.fmt.allocPrint(arena, "{{\"device_code\":\"{s}\"}}", .{
        started.device_code,
    });
    const polled = try smoke.http_post(init, port, "/api/device/poll", code);

    try expect_in("device poll", polled, "\"state\":\"approved\"");

    const claim = try smoke.http_post(init, port, "/api/device/claim", code);
    const claimed = try body_as(Claimed, arena, claim);

    try expect_remote(init, binary, work_dir, port, claimed.token);

    const page = try smoke.http_get(init, port, "/admin/settings/devices/approve?code=BCDF-GHJK");

    try expect_in("approve page signed out", page, "Location: /admin/login?return=");
}

/// `whoami` and a command sent with `--site`, as the device; destroying refused.
fn expect_remote(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    port: u16,
    token: []const u8,
) !void {
    std.debug.assert(token.len > 0);

    const arena = init.arena.allocator();
    const address = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port});
    const file = try std.fmt.allocPrint(arena, "{s}/credentials", .{work_dir});
    const kept = try std.fmt.allocPrint(arena, "{{\"sites\":[{{\"address\":\"{s}\"," ++
        "\"token\":\"{s}\"}}]}}", .{ address, token });

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = file, .data = kept });

    const whoami = try run_with(init, binary, work_dir, file, &.{"whoami"});

    try expect_in("whoami", whoami.stdout, "smoke device");

    const types = try run_with(init, binary, work_dir, file, &.{
        "--site", address, "content_type", "list",
    });

    try expect_in("--site content_type list", types.stdout, "\"types\"");

    const delete = try run_with(init, binary, work_dir, file, &.{
        "--site", address, "content_type", "delete", "--type", "post",
    });

    try expect_in("--site content_type delete", delete.stderr, "a person does it in the admin");
}

fn run_with(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    credentials: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    std.debug.assert(args.len < 8);
    std.debug.assert(credentials.len > 0);

    var environ = try init.environ_map.clone(init.arena.allocator());
    var argv: [9][]const u8 = undefined;

    try environ.put("PUBLR_CREDENTIALS", credentials);
    argv[0] = binary;

    for (args, 0..) |arg, index| argv[index + 1] = arg;

    return std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv[0 .. args.len + 1],
        .cwd = .{ .path = work_dir },
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
}

/// The JSON body of a raw HTTP answer.
fn body_as(comptime Body: type, arena: std.mem.Allocator, answer: []const u8) !Body {
    std.debug.assert(answer.len > 0);

    const start = std.mem.indexOf(u8, answer, "\r\n\r\n") orelse return error.SmokeFailed;

    return std.json.parseFromSliceLeaky(Body, arena, answer[start + 4 ..], .{
        .ignore_unknown_fields = true,
    });
}

fn expect_in(what: []const u8, text: []const u8, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);

    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("smoke: {s}: missing {s} in {s}\n", .{ what, needle, text });
        return error.SmokeFailed;
    }
}
