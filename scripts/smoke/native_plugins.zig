//! A compiled-in plugin in the admin: its settings page answered at its own route in the
//! admin's chrome, listed in the Settings sidebar, and its item in the top bar of every
//! signed-in page; its state, hooks and operator command; and every structure change
//! heard by a plugin listening for them. `binary` is Publr with the fixture plugins
//! compiled in; `module` an installed plugin to add.
const std = @import("std");
const smoke = @import("../smoke.zig");

const email = "native@example.com";
const password = "native smoke pass";

pub fn expect_native_admin(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    module: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/native-plugins", .{work_dir});
    const setup = [_][]const u8{
        "init", "--email", email, "--display_name", "Native", "--password", password,
    };
    const note = [_][]const u8{ "--as", email, "sampler", "note", "--note", "kept" };

    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try smoke.expect_contains(init, binary, dir, &setup, "\"roles\": [");
    try smoke.expect_contains(init, binary, dir, &note, "\"note\": \"KEPT\"");

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8092" },
        .cwd = .{ .path = dir },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    const port = try smoke.read_port(init, child.stderr.?);
    const cookie = try sign_in(init, port);
    const page = try smoke.http_get_cookie(init, port, "/admin/sampler", cookie);
    const system = try smoke.http_get_cookie(init, port, "/admin/settings/system", cookie);

    try expect_in("/admin/sampler", page, "<title>Sampler · Publr</title>");
    try expect_in("/admin/sampler", page, "noted KEPT");
    try expect_in("/admin/sampler", page, "Sampler: 1");
    try expect_in("/admin/sampler", page, "served on port 8092");
    try expect_in("/admin/settings/system", system, "href=\"/admin/sampler\"");
    try expect_in("/admin/settings/system", system, "Sampler: 1");
    try expect_ping(init, port, dir);
    try expect_moved(init, binary, work_dir);
    try expect_structure(init, binary, dir, module);
}

/// A type, a taxonomy, a field group, an installed plugin: each change, made through the
/// running server, heard by `recorder`, as the apps loaded when it started were.
fn expect_structure(
    init: std.process.Init,
    binary: []const u8,
    dir: []const u8,
    module: []const u8,
) !void {
    std.debug.assert(std.fs.path.isAbsolute(module));

    const thing = "{\"handle\":\"thing\",\"name\":\"Thing\",\"fields\":[" ++
        "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\",\"required\":true}]}";
    const tags = "{\"handle\":\"tags\",\"name\":\"Tags\",\"title_field\":\"name\"," ++
        "\"fields\":[{\"name\":\"name\",\"label\":\"Name\",\"kind\":\"string\"," ++
        "\"required\":true}]}";
    const profile = "{\"handle\":\"profile\",\"name\":\"Profile\"," ++
        "\"kind\":\"component\",\"fields\":[]}";
    const steps = [_][]const []const u8{
        &.{ "--as", email, "content_type", "create", "--definition", thing },
        &.{ "--as", email, "taxonomy", "create", "--definition", tags },
        &.{
            "--as",    email,     "custom_fields", "create",
            "--group", "profile", "--definition",  profile,
        },
        &.{ "--as-admin", "plugin", "add", "--file", module },
        &.{ "--as-admin", "plugin", "enable", "--name", "postcard" },
    };

    for (steps) |step| {
        try smoke.expect_contains(init, binary, dir, step, "{");
    }

    const seen = [_][]const u8{ "--as-admin", "recorder", "seen" };
    const heard = [_][]const u8{
        "apps.loaded ",
        "content_type.created thing",
        "taxonomy.created tags",
        "custom_fields.created profile",
        "plugin.added postcard",
        "plugin.enabled postcard",
    };

    for (heard) |line| {
        try smoke.expect_contains(init, binary, dir, &seen, line);
    }
}

/// The operator command: refused without the key, answered with it, from the plugin's state.
fn expect_ping(init: std.process.Init, port: u16, dir: []const u8) !void {
    std.debug.assert(port > 0);

    const arena = init.arena.allocator();
    const session_path = try std.fs.path.join(arena, &.{ dir, "data/publr.db.serve" });
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, session_path, arena, .limited(256));
    var words = std.mem.tokenizeAny(u8, text, " \n");
    _ = words.next();
    const key = words.next() orelse return error.SmokeFailed;
    const refused = try smoke.http_post(init, port, "/_publr/sampler/ping", "{}");
    const answered = try smoke.http_post_headers(
        init,
        port,
        "/_publr/sampler/ping",
        try std.fmt.allocPrint(arena, "X-Publr-Operator: {s}\r\n", .{key}),
        "{}",
    );

    try expect_in("/_publr/sampler/ping without the key", refused, "403 Forbidden");
    try expect_in("/_publr/sampler/ping", answered, "\"port\":8092");
    try expect_in("/_publr/sampler/ping", answered, "\"pings\":1");
}

/// The CLI pre-command hook: `--sampler-in <folder>` runs the command in that folder.
fn expect_moved(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);

    const check = [_][]const u8{
        "--sampler-in", "native-plugins", "--as", email, "sampler", "logs",
    };

    try smoke.expect_contains(init, binary, work_dir, &check, "noted KEPT");
}

/// The session cookie pair (`publr_session=...`) a sign-in sets.
fn sign_in(init: std.process.Init, port: u16) ![]const u8 {
    std.debug.assert(port > 0);

    const body = "{\"email\":\"" ++ email ++ "\",\"password\":\"" ++ password ++ "\"}";
    const answer = try smoke.http_post(init, port, "/api/auth/sign-in", body);
    const marker = "Set-Cookie: ";
    const start = (std.mem.indexOf(u8, answer, marker) orelse {
        std.debug.print("smoke: native plugins: sign-in set no cookie: {s}\n", .{answer});
        return error.SmokeFailed;
    }) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, answer, start, ';') orelse answer.len;

    return answer[start..end];
}

fn expect_in(path: []const u8, body: []const u8, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);

    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print("smoke: native plugins: {s} lacks {s}: {s}\n", .{
            path,
            needle,
            body[0..@min(body.len, 2048)],
        });

        return error.SmokeFailed;
    }
}
