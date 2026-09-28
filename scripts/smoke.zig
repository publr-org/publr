const std = @import("std");

const output_bytes_max: u32 = 64 << 10;
const startup_attempts_max: u32 = 50;
const startup_wait_ms: u32 = 100;

pub fn main(init: std.process.Init) !u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());

    _ = iterator.next();

    const binary_arg = iterator.next() orelse return error.MissingBinaryPath;
    const work_dir = iterator.next() orelse return error.MissingWorkDir;
    const arena = init.arena.allocator();
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, binary_arg, arena);

    std.debug.assert(std.fs.path.isAbsolute(binary));
    std.debug.assert(std.fs.path.isAbsolute(work_dir));

    try std.Io.Dir.cwd().deleteTree(init.io, work_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, work_dir);

    const check = [_][]const u8{ "heartbeat", "check", "--echo", "smoke" };
    const admin_check = [_][]const u8{ "--as-admin", "heartbeat", "check" };

    try expect_output(init, binary, work_dir, &.{"--version"}, "publr 0.2.0\n");
    try expect_contains(init, binary, work_dir, &check, "\"echo\": \"smoke\"");
    try expect_contains(init, binary, work_dir, &admin_check, "\"caller\": \"system\"");
    try expect_contains(init, binary, work_dir, &.{"--help"}, "heartbeat check");
    try expect_contains(init, binary, work_dir, &.{ "user", "--help" }, "user password_link");
    try expect_auth(init, binary, work_dir);
    try expect_build(init, binary, work_dir, "smoke@example.com");
    try expect_serve(init, binary, work_dir);

    std.debug.print("smoke: ok\n", .{});

    return 0;
}

fn run_publr(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    std.debug.assert(args.len < 16);
    std.debug.assert(binary.len > 0);

    var argv: [17][]const u8 = undefined;
    argv[0] = binary;

    for (args, 0..) |arg, index| argv[index + 1] = arg;

    return std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv[0 .. args.len + 1],
        .cwd = .{ .path = work_dir },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
}

fn expect_output(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
    expected: []const u8,
) !void {
    const result = try run_publr(init, binary, work_dir, args);

    std.debug.assert(expected.len > 0);
    std.debug.assert(args.len > 0);

    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print("smoke: {s}: expected {s}, got {s}{s}\n", .{
            args[0],
            expected,
            result.stdout,
            result.stderr,
        });
        return error.SmokeFailed;
    }
}

fn expect_contains(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
    needle: []const u8,
) !void {
    const result = try run_publr(init, binary, work_dir, args);

    std.debug.assert(needle.len > 0);
    std.debug.assert(args.len > 0);

    if (std.mem.indexOf(u8, result.stdout, needle) == null) {
        std.debug.print("smoke: {s}: missing {s} in {s}{s}\n", .{
            args[0],
            needle,
            result.stdout,
            result.stderr,
        });
        return error.SmokeFailed;
    }
}

fn expect_auth(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const email = "smoke@example.com";
    const password = "smoke test pass";
    const setup = [_][]const u8{
        "init", "--email", email, "--display_name", "Smoke", "--password", password,
    };
    const setup_again = [_][]const u8{
        "site", "init", "--email", "x@example.com", "--display_name", "X", "--password", password,
    };
    const login = [_][]const u8{ "user", "sign_in", "--email", email, "--password", password };
    const wrong = [_][]const u8{
        "user", "sign_in", "--email", email, "--password", "wrong wrong wrong",
    };
    const list = [_][]const u8{ "--as", "smoke@example.com", "user", "list" };
    const denied = [_][]const u8{ "user", "list" };
    const generated = [_][]const u8{
        "--as", email, "user", "create", "--email", "gen@example.com", "--display_name", "Gen",
    };
    const invited = [_][]const u8{
        "--as",            email,
        "user",            "create",
        "--email",         "new@example.com",
        "--display_name",  "New",
        "--password_link", "true",
    };
    const relink = [_][]const u8{
        "--as", email, "user", "password_link", "--user", "new@example.com",
    };
    const forged = [_][]const u8{
        "user", "set_password", "--token", "0" ** 64, "--password", password,
    };

    try expect_contains(init, binary, work_dir, &setup, "\"role\": \"admin\"");
    try expect_failure(init, binary, work_dir, &setup_again, "conflict");
    try expect_contains(init, binary, work_dir, &login, "\"token\": \"");
    try expect_failure(init, binary, work_dir, &wrong, "wrong email or password");
    try expect_contains(init, binary, work_dir, &list, "smoke@example.com");
    try expect_failure(init, binary, work_dir, &denied, "denied for an anonymous caller");
    try expect_contains(init, binary, work_dir, &generated, "\"password\": \"");
    try expect_contains(init, binary, work_dir, &invited, "/auth/set-password?token=");
    try expect_contains(init, binary, work_dir, &relink, "/auth/set-password?token=");
    try expect_failure(init, binary, work_dir, &forged, "not found");
    try expect_content(init, binary, work_dir, email);
}

fn expect_content(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    admin: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(admin.len > 0);

    const definition = "{\"handle\":\"post\",\"name\":\"Post\"," ++
        "\"public\":true,\"fields\":[" ++
        "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\",\"required\":true}," ++
        "{\"name\":\"slug\",\"label\":\"Slug\",\"kind\":\"slug\"," ++
        "\"options\":{\"source\":\"title\"}}," ++
        "{\"name\":\"body\",\"label\":\"Body\",\"kind\":\"richtext\",\"searchable\":true}]}";
    const create_type = [_][]const u8{
        "--as", admin, "content_type", "create", "--definition", definition,
    };
    const document = "{\"title\":\"Smoke\",\"body\":\"hello there\"}";
    const create_entry = [_][]const u8{
        "--as", admin, "record", "create", "--type", "post", "--document", document,
    };
    const list_anonymous = [_][]const u8{ "record", "list", "--type", "post" };
    const search = [_][]const u8{
        "--as", admin, "record", "list", "--type", "post", "--search", "hello",
    };
    const editor_types = [_][]const u8{ "--as", admin, "content_type", "list" };

    try expect_contains(init, binary, work_dir, &create_type, "\"handle\": \"post\"");
    try expect_contains(init, binary, work_dir, &create_entry, "\"slug\": \"smoke\"");
    try expect_contains(init, binary, work_dir, &list_anonymous, "\"records\": []");
    try expect_contains(init, binary, work_dir, &search, "\"title\": \"Smoke\"");
    try expect_contains(init, binary, work_dir, &editor_types, "\"handle\": \"post\"");
    try expect_taxonomies(init, binary, work_dir, admin);
}

/// A taxonomy, a term under a term, a type filing records under the taxonomy, and the
/// record found through the parent.
fn expect_taxonomies(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    admin: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(admin.len > 0);

    const taxonomy = "{\"handle\":\"topics\",\"name\":\"Topics\",\"public\":true," ++
        "\"hierarchical\":true,\"title_field\":\"name\",\"fields\":[" ++
        "{\"name\":\"name\",\"label\":\"Name\",\"kind\":\"string\",\"required\":true}," ++
        "{\"name\":\"slug\",\"label\":\"Slug\",\"kind\":\"slug\"," ++
        "\"options\":{\"source\":\"name\"}}]}";
    const create_taxonomy = [_][]const u8{
        "--as", admin, "taxonomy", "create", "--definition", taxonomy,
    };
    const create_root = [_][]const u8{
        "--as",   admin,        "term",                      "create",   "--taxonomy",
        "topics", "--document", "{\"name\":\"Technology\"}", "--status", "published",
    };

    try expect_contains(init, binary, work_dir, &create_taxonomy, "\"handle\": \"topics\"");
    try expect_contains(init, binary, work_dir, &create_root, "\"slug\": \"technology\"");

    const tree = [_][]const u8{ "term", "tree", "--taxonomy", "topics" };
    const listed_taxonomies = [_][]const u8{ "--as", admin, "taxonomy", "list" };

    try expect_contains(init, binary, work_dir, &tree, "\"title\": \"Technology\"");
    try expect_contains(init, binary, work_dir, &listed_taxonomies, "\"handle\": \"topics\"");
}

/// A greeting recorded through the hello plugin, the site built from it, and the files
/// the build promises.
fn expect_build(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    admin: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(admin.len > 0);

    const publish = [_][]const u8{ "--as", admin, "hello", "record", "--note", "Hello site" };
    const build = [_][]const u8{"build"};
    const files = [_][]const u8{
        "output/index.html",
        "output/greetings/index.html",
        "output/greetings/hello-site/index.html",
        "output/404.html",
        "output/sitemap.xml",
        "output/theme/theme.css",
        "output/theme/islands.js",
    };

    try expect_contains(init, binary, work_dir, &publish, "\"rows\": 1");

    const result = try run_publr(init, binary, work_dir, &build);

    if (std.mem.indexOf(u8, result.stderr, "publr: built ") == null) {
        std.debug.print("smoke: build: {s}{s}\n", .{ result.stdout, result.stderr });
        return error.SmokeFailed;
    }

    var dir = try std.Io.Dir.cwd().openDir(init.io, work_dir, .{});
    defer dir.close(init.io);

    for (files) |file| {
        dir.access(init.io, file, .{}) catch {
            std.debug.print("smoke: build: {s} was not written\n", .{file});
            return error.SmokeFailed;
        };
    }

    const arena = init.arena.allocator();
    const page = try dir.readFileAlloc(init.io, files[2], arena, .limited(output_bytes_max));

    if (std.mem.indexOf(u8, page, "<code>hello-site</code>") == null) {
        std.debug.print("smoke: build: the greeting page is not its own: {s}\n", .{page});
        return error.SmokeFailed;
    }

    try expect_build_again(init, binary, work_dir);
}

/// A second `build` finds nothing to do; `build --full` builds everything again.
fn expect_build_again(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const again = [_][]const u8{"build"};
    const full = [_][]const u8{ "build", "--full" };
    const current = try run_publr(init, binary, work_dir, &again);

    if (std.mem.indexOf(u8, current.stderr, "output/ is current") == null) {
        std.debug.print("smoke: build again: {s}{s}\n", .{ current.stdout, current.stderr });
        return error.SmokeFailed;
    }

    const rebuilt = try run_publr(init, binary, work_dir, &full);

    if (std.mem.indexOf(u8, rebuilt.stderr, "publr: built ") == null) {
        std.debug.print("smoke: build --full: {s}{s}\n", .{ rebuilt.stdout, rebuilt.stderr });
        return error.SmokeFailed;
    }
}

fn expect_failure(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    args: []const []const u8,
    expected: []const u8,
) !void {
    const result = try run_publr(init, binary, work_dir, args);

    std.debug.assert(expected.len > 0);
    std.debug.assert(args.len > 0);

    const failed = result.term == .exited and result.term.exited != 0;

    if (!failed or std.mem.indexOf(u8, result.stderr, expected) == null) {
        std.debug.print("smoke: {s} {s}: expected failure containing {s}, got {s}{s}\n", .{
            args[0],
            args[1],
            expected,
            result.stdout,
            result.stderr,
        });

        return error.SmokeFailed;
    }
}

fn expect_serve(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8090" },
        .cwd = .{ .path = work_dir },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    const port = try read_port(init, child.stderr.?);
    const body = try http_get(init, port, "/api/health");

    if (std.mem.indexOf(u8, body, "\"version\":\"0.2.0\"") == null) {
        std.debug.print("smoke: serve: unexpected /api/health body: {s}\n", .{body});
        return error.SmokeFailed;
    }

    const login_page = try http_get(init, port, "/admin/login");

    if (std.mem.indexOf(u8, login_page, "<title>Log in · Publr</title>") == null) {
        std.debug.print("smoke: serve: /admin/login is not the login page: {s}\n", .{login_page});
        return error.SmokeFailed;
    }

    const styles = try http_get(init, port, "/admin/styles.css");

    if (std.mem.indexOf(u8, styles, "--background:") == null) {
        std.debug.print("smoke: serve: /admin/styles.css carries no palette\n", .{});
        return error.SmokeFailed;
    }

    const login_body = "{\"email\":\"smoke@example.com\",\"password\":\"smoke test pass\"}";
    const login = try http_post(init, port, "/api/auth/sign-in", login_body);

    if (std.mem.indexOf(u8, login, "Set-Cookie: publr_session=") == null) {
        std.debug.print("smoke: serve: login did not set a session cookie: {s}\n", .{login});
        return error.SmokeFailed;
    }

    const listed = try http_get(init, port, "/api/record/list?type=post");

    if (std.mem.indexOf(u8, listed, "\"records\":[]") == null) {
        std.debug.print("smoke: serve: unexpected /api/record/list body: {s}\n", .{listed});
        return error.SmokeFailed;
    }

    const tree = try http_get(init, port, "/api/term/tree?taxonomy=topics");

    if (std.mem.indexOf(u8, tree, "\"terms\":[") == null) {
        std.debug.print("smoke: serve: unexpected /api/term/tree body: {s}\n", .{tree});
        return error.SmokeFailed;
    }

    const denied = try http_get(init, port, "/api/content_type/list");

    if (std.mem.indexOf(u8, denied, "403 Forbidden") == null) {
        std.debug.print("smoke: serve: anonymous content_type list not denied: {s}\n", .{denied});
        return error.SmokeFailed;
    }

    try expect_site(init, port);
}

/// The public site: the built home page, the greeting's page, a fragment, the stylesheet,
/// and the theme's 404 for a path nothing owns.
fn expect_site(init: std.process.Init, port: u16) !void {
    std.debug.assert(port > 0);
    std.debug.assert(output_bytes_max > 0);

    const checks = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "/", .needle = "X-Publr-Served: file" },
        .{ .path = "/", .needle = "<title>Publr</title>" },
        .{ .path = "/greetings/hello-site", .needle = "<code>hello-site</code>" },
        .{ .path = "/greetings", .needle = "Hello site" },
        .{ .path = "/_islands/signed-in", .needle = "<template patchfor=\"signed-in\">" },
        .{ .path = "/theme/theme.css", .needle = ".bg-canvas" },
        .{ .path = "/nowhere", .needle = "404 Not Found" },
        .{ .path = "/nowhere", .needle = "Nothing lives at this address." },
    };

    for (checks) |check| {
        const body = try http_get(init, port, check.path);

        if (std.mem.indexOf(u8, body, check.needle) == null) {
            std.debug.print("smoke: site: {s} lacks {s}: {s}\n", .{
                check.path,
                check.needle,
                body,
            });
            return error.SmokeFailed;
        }
    }
}

fn read_port(init: std.process.Init, stderr: std.Io.File) !u16 {
    var buffer: [256]u8 = undefined;
    var reader = stderr.reader(init.io, &buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');

    std.debug.assert(line.len < buffer.len);
    std.debug.assert(buffer.len == 256);

    return parse_announced_port(line);
}

fn parse_announced_port(line: []const u8) !u16 {
    const marker = "127.0.0.1:";
    const marker_at = std.mem.indexOf(u8, line, marker) orelse return error.NoPortAnnounced;
    const digits = std.mem.trimEnd(u8, line[marker_at + marker.len ..], "/ \r");
    const port = try std.fmt.parseInt(u16, digits, 10);

    std.debug.assert(port > 0);
    std.debug.assert(line.len > marker.len);

    return port;
}

test "the announced port is parsed from the serve banner" {
    const plain = try parse_announced_port("publr serving on http://127.0.0.1:8090");
    const slashed = try parse_announced_port("... on http://127.0.0.1:8091/\r");
    try std.testing.expectEqual(@as(u16, 8090), plain);
    try std.testing.expectEqual(@as(u16, 8091), slashed);
    try std.testing.expectError(error.NoPortAnnounced, parse_announced_port("nothing here"));
    const garbage = parse_announced_port("http://127.0.0.1:abc");
    try std.testing.expectError(error.InvalidCharacter, garbage);
}

fn http_get(init: std.process.Init, port: u16, path: []const u8) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(path.len > 0);

    const request = try std.fmt.allocPrint(
        init.arena.allocator(),
        "GET {s} HTTP/1.1\r\nHost: smoke\r\nConnection: close\r\n\r\n",
        .{path},
    );

    return http_exchange(init, port, request);
}

fn http_post(init: std.process.Init, port: u16, path: []const u8, body: []const u8) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(path.len > 0);

    const request = try std.fmt.allocPrint(
        init.arena.allocator(),
        "POST {s} HTTP/1.1\r\nHost: smoke\r\nOrigin: http://smoke\r\n" ++
            "Content-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, body.len, body },
    );

    return http_exchange(init, port, request);
}

fn http_exchange(init: std.process.Init, port: u16, request: []const u8) ![]const u8 {
    std.debug.assert(port > 0);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(init.io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(init.io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    // The server closes the connection after the response, so a short read is the whole
    // of it; a page carries its stylesheet inline, so the room is generous.
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);
    const response = try init.arena.allocator().alloc(u8, output_bytes_max);
    const len = try reader.interface.readSliceShort(response);

    std.debug.assert(len <= response.len);

    return response[0..len];
}
