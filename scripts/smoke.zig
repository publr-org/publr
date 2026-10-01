const std = @import("std");

const output_bytes_max: u32 = 64 << 10;
/// An admin page, sprite included.
const page_bytes_max: u32 = 1 << 20;
const startup_attempts_max: u32 = 50;
const startup_wait_ms: u32 = 100;

pub fn main(init: std.process.Init) !u8 {
    var iterator = try init.minimal.args.iterateAllocator(init.arena.allocator());

    _ = iterator.next();

    const binary_arg = iterator.next() orelse return error.MissingBinaryPath;
    const bare_arg = iterator.next() orelse return error.MissingBinaryPath;
    const work_dir = iterator.next() orelse return error.MissingWorkDir;
    const module_arg = iterator.next() orelse return error.MissingPlugin;
    const fixtures_arg = iterator.next() orelse return error.MissingPlugin;
    const native_arg = iterator.next() orelse return error.MissingBinaryPath;
    const installable_arg = iterator.next() orelse return error.MissingPlugin;
    const arena = init.arena.allocator();
    const module = try std.Io.Dir.cwd().realPathFileAlloc(init.io, module_arg, arena);
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, binary_arg, arena);
    const bare = try std.Io.Dir.cwd().realPathFileAlloc(init.io, bare_arg, arena);
    const fixtures = try std.Io.Dir.cwd().realPathFileAlloc(init.io, fixtures_arg, arena);
    const native = try std.Io.Dir.cwd().realPathFileAlloc(init.io, native_arg, arena);
    const installable = try std.Io.Dir.cwd().realPathFileAlloc(init.io, installable_arg, arena);

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
    try expect_compiler(init, binary, bare, work_dir);
    try expect_contains(init, bare, work_dir, &.{"agents"}, "publr plugin build --name");
    try expect_contains(init, bare, work_dir, &.{"--help"}, "run `publr agents` first");
    try expect_auth(init, binary, work_dir);
    const sandboxed = @import("smoke/sandboxed_plugins.zig");

    try sandboxed.expect_sandboxed_plugins(init, binary, work_dir, module);
    try sandboxed.expect_plugin_build(init, bare, work_dir, fixtures);
    try expect_build(init, binary, work_dir, "smoke@example.com");
    try expect_serve(init, binary, work_dir);
    try expect_bare(init, bare, work_dir);
    try expect_apps_folder(init, bare, work_dir);
    const native_plugins = @import("smoke/native_plugins.zig");

    try native_plugins.expect_native_admin(init, native, work_dir, installable);

    std.debug.print("smoke: ok\n", .{});

    return 0;
}

pub fn run_publr(
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

pub fn expect_contains(
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
        "project",        "init", "--email",    "x@example.com",
        "--display_name", "X",    "--password", password,
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

    try expect_contains(init, binary, work_dir, &setup, "\"roles\": [\n    \"admin\"");
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

/// A post published, every app built from it, and the files the build promises.
fn expect_build(
    init: std.process.Init,
    binary: []const u8,
    work_dir: []const u8,
    admin: []const u8,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(admin.len > 0);

    const publish = [_][]const u8{
        "--as", admin,        "record",                     "create",   "--type",
        "post", "--document", "{\"title\":\"Hello site\"}", "--status", "published",
    };
    const build = [_][]const u8{"build"};
    const files = [_][]const u8{
        "output/www/index.html",
        "output/www/posts/index.html",
        "output/www/posts/hello-site/index.html",
        "output/www/404.html",
        "output/www/sitemap.xml",
        "output/www/_app/app.css",
        "output/www/_app/islands.js",
        "output/docs/index.html",
        "output/docs/guide/index.html",
    };

    try expect_contains(init, binary, work_dir, &publish, "\"slug\": \"hello-site\"");

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
        std.debug.print("smoke: build: the post page is not its own: {s}\n", .{page});
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

pub fn expect_failure(
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

    try expect_operator(init, binary, work_dir);

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
    const published = std.mem.indexOf(u8, listed, "\"title\":\"Hello site\"") != null;
    const draft = std.mem.indexOf(u8, listed, "\"title\":\"Smoke\"") != null;

    // A visitor sees the published post and never the draft.
    if (!published or draft) {
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

/// The apps: the root app's built home page, the post's page, a fragment, the stylesheet
/// and its 404 for a path nothing owns; the app under `/docs`; the app on a subdomain.
fn expect_site(init: std.process.Init, port: u16) !void {
    std.debug.assert(port > 0);
    std.debug.assert(output_bytes_max > 0);

    const checks = [_]struct { path: []const u8, needle: []const u8, host: []const u8 = "smoke" }{
        .{ .path = "/", .needle = "X-Publr-Served: file" },
        .{ .path = "/", .needle = "<title>Publr</title>" },
        .{ .path = "/posts/hello-site", .needle = "<code>hello-site</code>" },
        .{ .path = "/posts", .needle = "Hello site" },
        .{ .path = "/_islands/signed-in", .needle = "<template patchfor=\"signed-in\">" },
        .{ .path = "/_app/app.css", .needle = ".bg-canvas" },
        .{ .path = "/sitemap.xml", .needle = "<urlset" },
        .{ .path = "/nowhere", .needle = "404 Not Found" },
        .{ .path = "/nowhere", .needle = "Nothing lives at this address." },
        .{ .path = "/docs/guide", .needle = "The guide" },
        .{ .path = "/docs/_app/app.css", .needle = ".bg-paper" },
        .{ .path = "/x", .needle = "\"app\":\"portal\"", .host = "portal.127.0.0.1" },
    };

    for (checks) |check| {
        const body = try http_get_host(init, port, check.host, check.path);

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

/// The real binary carries the compiler; the fixture, built with `-Dcompiler=false`, says it
/// does not and fails, and nothing else about it changes.
fn expect_compiler(
    init: std.process.Init,
    without: []const u8,
    with: []const u8,
    work_dir: []const u8,
) !void {
    std.debug.assert(!std.mem.eql(u8, without, with));
    std.debug.assert(work_dir.len > 0);

    try expect_output(init, with, work_dir, &.{ "zig", "version" }, "0.16.0\n");

    const refused = try run_publr(init, without, work_dir, &.{ "zig", "version" });
    const failed = refused.term != .exited or refused.term.exited != 1;

    if (failed or std.mem.indexOf(u8, refused.stderr, "without the compiler") == null) {
        std.debug.print("smoke: zig: a binary without the compiler: {s}\n", .{refused.stderr});
        return error.SmokeFailed;
    }
}

/// While `serve` runs it owns the project: it leaves its session beside the database, the
/// CLI sends it its commands, and a second server for the same database is refused.
fn expect_operator(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const session = try std.fmt.allocPrint(init.arena.allocator(), "{s}/data/publr.db.serve", .{
        work_dir,
    });
    const echo = [_][]const u8{ "heartbeat", "check", "--echo", "forwarded" };
    const second = [_][]const u8{ "serve", "--port", "8093" };

    std.Io.Dir.cwd().access(init.io, session, .{}) catch {
        std.debug.print("smoke: serve: no session at {s}\n", .{session});
        return error.SmokeFailed;
    };

    try expect_contains(init, binary, work_dir, &echo, "\"echo\": \"forwarded\"");
    try expect_failure(init, binary, work_dir, &second, "already runs");
    try expect_contains(init, binary, work_dir, &.{ "apps", "load" }, "loaded in the running");
}

/// Apps read from a folder, with no server: one that loads is counted, a template the engine
/// refuses is named.
fn expect_apps_folder(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const arena = init.arena.allocator();
    const dir = try std.fmt.allocPrint(arena, "{s}/apps-folder", .{work_dir});
    const cwd = std.Io.Dir.cwd();
    const content = try std.fmt.allocPrint(arena, "{s}/apps/site/content", .{dir});
    const zon = try std.fmt.allocPrint(arena, "{s}/apps/site/app.zon", .{dir});
    const page = try std.fmt.allocPrint(arena, "{s}/index.publr", .{content});
    const broken = try std.fmt.allocPrint(arena, "{s}/broken.publr", .{content});
    const load = [_][]const u8{ "apps", "load", "--apps", "apps" };
    const site = ".{ .name = \"site\", .mount = .{ .path = \"/\" } }\n";

    try cwd.createDirPath(init.io, content);
    try cwd.writeFile(init.io, .{ .sub_path = zon, .data = site });
    try cwd.writeFile(init.io, .{ .sub_path = page, .data = "<html><body>Hi</body></html>\n" });
    try expect_contains(init, binary, dir, &load, "1 apps load from apps");
    try cwd.writeFile(init.io, .{ .sub_path = broken, .data = "<p>{oops(</p>\n" });
    try expect_failure(init, binary, dir, &load, "content/broken.publr");
}

/// A Publr with no apps: its `serve` opens the admin at `/`.
fn expect_bare(init: std.process.Init, binary: []const u8, work_dir: []const u8) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(work_dir.len > 0);

    const bare_dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/bare", .{work_dir});

    try std.Io.Dir.cwd().createDirPath(init.io, bare_dir);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ binary, "serve", "--port", "8090" },
        .cwd = .{ .path = bare_dir },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    const port = try read_port(init, child.stderr.?);
    const root = try http_get(init, port, "/");

    if (std.mem.indexOf(u8, root, "Location: /admin") == null) {
        std.debug.print("smoke: bare: / does not open the admin: {s}\n", .{root});
        return error.SmokeFailed;
    }

    const apps = try run_publr(init, binary, bare_dir, &.{"check-apps"});

    if (std.mem.indexOf(u8, apps.stdout, "0 apps: compile") == null) {
        std.debug.print("smoke: bare: check-apps: {s}{s}\n", .{ apps.stdout, apps.stderr });
        return error.SmokeFailed;
    }
}

/// The port `serve` announces, past the notices it may print first.
pub fn read_port(init: std.process.Init, stderr: std.Io.File) !u16 {
    var buffer: [256]u8 = undefined;
    var reader = stderr.reader(init.io, &buffer);
    var lines: u32 = 0;

    std.debug.assert(buffer.len == 256);

    while (lines < 8) : (lines += 1) {
        const line = try reader.interface.takeDelimiterInclusive('\n');

        std.debug.assert(line.len <= buffer.len);

        return parse_announced_port(std.mem.trimEnd(u8, line, "\n")) catch |err| switch (err) {
            error.NoPortAnnounced => continue,
            else => err,
        };
    }

    return error.NoPortAnnounced;
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

pub fn http_get(init: std.process.Init, port: u16, path: []const u8) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(path.len > 0);

    return http_get_host(init, port, "smoke", path);
}

fn http_get_host(
    init: std.process.Init,
    port: u16,
    host: []const u8,
    path: []const u8,
) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(host.len > 0);

    const request = try std.fmt.allocPrint(
        init.arena.allocator(),
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{ path, host },
    );

    return http_exchange(init, port, request);
}

pub fn http_post(
    init: std.process.Init,
    port: u16,
    path: []const u8,
    body: []const u8,
) ![]const u8 {
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

/// A POST with extra header lines (`Name: value\r\n` each).
pub fn http_post_headers(
    init: std.process.Init,
    port: u16,
    path: []const u8,
    headers: []const u8,
    body: []const u8,
) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(path.len > 0);

    const request = try std.fmt.allocPrint(
        init.arena.allocator(),
        "POST {s} HTTP/1.1\r\nHost: smoke\r\n{s}Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, headers, body.len, body },
    );

    return http_exchange(init, port, request);
}

/// A page as a signed-in browser asks for it: `cookie` is the session pair.
pub fn http_get_cookie(
    init: std.process.Init,
    port: u16,
    path: []const u8,
    cookie: []const u8,
) ![]const u8 {
    std.debug.assert(port > 0);
    std.debug.assert(cookie.len > 0);

    const request = try std.fmt.allocPrint(
        init.arena.allocator(),
        "GET {s} HTTP/1.1\r\nHost: smoke\r\nCookie: {s}\r\nConnection: close\r\n\r\n",
        .{ path, cookie },
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
    const response = try init.arena.allocator().alloc(u8, page_bytes_max);
    const len = try reader.interface.readSliceShort(response);

    std.debug.assert(len <= response.len);

    return response[0..len];
}
