//! One fixture updated by the build under test: the gate takes it, the shape is a fresh
//! one's, a second open changes nothing, every fact still holds, the site still works, the
//! release before can still run on it, and the backup the gate took puts it back.

const std = @import("std");
const smoke = @import("../smoke.zig");
const facts_module = @import("facts.zig");

pub const Check = struct {
    init: std.process.Init,
    binary: []const u8,
    site_dir: []const u8,
    /// The release that made the fixture.
    from: []const u8,
    /// This build's version, as `/api/health` answers it.
    version: []const u8,
    /// The previous minor's latest release, to prove a step back; null when none exists.
    previous: ?[]const u8,
    port: u16,
    /// `db check`'s line naming who last opened the fixture, before the update.
    before_opened: []const u8 = "",
    /// Why it failed, for the matrix's line.
    failure: []const u8 = "",

    fn arena(check: *Check) std.mem.Allocator {
        return check.init.arena.allocator();
    }

    fn fail(check: *Check, comptime format: []const u8, args: anytype) error{CheckFailed} {
        check.failure = std.fmt.allocPrint(check.arena(), format, args) catch "out of memory";
        return error.CheckFailed;
    }

    /// Run `args` with `binary`: its output when it exited 0.
    fn publr_with(check: *Check, binary: []const u8, args: []const []const u8) ![]const u8 {
        std.debug.assert(args.len > 0);
        std.debug.assert(binary.len > 0);

        const result = try smoke.run_publr(check.init, binary, check.site_dir, args);
        const ok = result.term == .exited and result.term.exited == 0;

        if (!ok) {
            return check.fail("`{s}` failed: {s}{s}", .{
                try std.mem.join(check.arena(), " ", args),
                std.mem.trim(u8, result.stdout, "\n"),
                std.mem.trim(u8, result.stderr, "\n"),
            });
        }

        return result.stdout;
    }

    fn publr(check: *Check, args: []const []const u8) ![]const u8 {
        return check.publr_with(check.binary, args);
    }
};

pub const Result = struct {
    migrations: u32 = 0,
    gate_ms: i64 = 0,
    facts_held: u32 = 0,
    facts_total: u32 = 0,
    pages: u32 = 0,
    back: enum { ok, none } = .none,
};

pub fn run(check: *Check) !Result {
    std.debug.assert(check.site_dir.len > 0);
    std.debug.assert(check.port > 0);

    const facts = try facts_module.read(check.init.io, check.arena(), check.site_dir);
    var result: Result = .{
        .facts_total = facts.count(),
    };

    const db_check = [_][]const u8{ "db", "check" };
    const before = try smoke.run_publr(check.init, check.binary, check.site_dir, &db_check);

    result.migrations = @intCast(std.mem.count(u8, before.stdout, "\nto run "));

    const opened_at = std.mem.indexOf(u8, before.stdout, "last opened by ") orelse 0;
    const opened_end = std.mem.indexOfScalarPos(u8, before.stdout, opened_at, ';') orelse
        before.stdout.len;

    check.before_opened = before.stdout[opened_at..opened_end];

    const started_ms = std.Io.Clock.awake.now(check.init.io).toMilliseconds();

    _ = try check.publr(&.{ "--as-admin", "heartbeat", "check" });
    result.gate_ms = std.Io.Clock.awake.now(check.init.io).toMilliseconds() - started_ms;

    try expect_shape(check);
    _ = try check.publr(&.{ "--as-admin", "heartbeat", "check" });

    // A fixture this very release made, with nothing to run or make, is opened, not updated.
    const opened_by = try std.fmt.allocPrint(check.arena(), "last opened by {s};", .{
        check.version,
    });
    const updates = result.migrations > 0 or
        std.mem.indexOf(u8, before.stdout, opened_by) == null or
        std.mem.indexOf(u8, before.stdout, "\nrefused ") != null;

    try expect_backups(check, if (updates) 1 else 0);

    result.facts_held = try expect_facts(check, facts);
    result.pages = try expect_site(check, facts);

    if (check.previous) |previous| {
        try expect_back(check, previous, facts);
        result.back = .ok;
    }

    if (updates) {
        try expect_restore(check);
    }

    return result;
}

/// The release before still runs on the updated site: it opens it and reads what the
/// fixture holds, through operations every release has.
fn expect_back(check: *Check, previous: []const u8, facts: facts_module.Facts) !void {
    std.debug.assert(previous.len > 0);

    _ = try check.publr_with(previous, &.{ "--as-admin", "heartbeat", "check" });

    for (facts.records) |record| {
        const listed = try check.publr_with(previous, &.{
            "--as-admin", "record", "list", "--type", record.type,
        });

        try expect_in(check, "record list by the release before", listed, record.title);
    }

    for (facts.users) |user| {
        _ = try check.publr_with(previous, &.{
            "user", "sign_in", "--email", user.email, "--password", facts_module.password,
        });
    }
}

/// The updated database is what this release would make fresh: `db check` finds nothing to
/// run and nothing it would refuse.
fn expect_shape(check: *Check) !void {
    std.debug.assert(check.binary.len > 0);

    const found = try check.publr(&.{ "db", "check" });
    const pending = std.mem.indexOf(u8, found, "\nto run ") != null;
    const refused = std.mem.indexOf(u8, found, "\nrefused ") != null;

    if (pending or refused) {
        return check.fail("the updated database is not this release's shape:\n{s}", .{found});
    }
}

/// The update was backed up once; opening again took no second backup.
fn expect_backups(check: *Check, expected: u32) !void {
    std.debug.assert(check.from.len > 0);
    std.debug.assert(expected <= 1);

    const listed = try check.publr(&.{"backups"});
    const lines: u32 = if (std.mem.startsWith(u8, listed, "No backups"))
        0
    else
        @intCast(std.mem.count(u8, listed, "\n"));

    if (lines != expected) {
        return check.fail("expected {d} backup(s) after the update, found:\n{s}", .{
            expected,
            listed,
        });
    }
}

fn expect_facts(check: *Check, facts: facts_module.Facts) !u32 {
    std.debug.assert(check.binary.len > 0);

    var held: u32 = 0;

    for (facts.users) |user| {
        _ = try check.publr(&.{
            "user", "sign_in", "--email", user.email, "--password", facts_module.password,
        });
        held += 1;
    }

    for (facts.records) |record| {
        const listed = try check.publr(&.{ "--as-admin", "record", "list", "--type", record.type });

        try expect_in(check, "record list", listed, record.title);
        held += 1;
    }

    for (facts.terms) |term| {
        const tree = try check.publr(&.{ "term", "tree", "--taxonomy", term.taxonomy });

        try expect_in(check, "term tree", tree, term.title);
        held += 1;
    }

    const media = try check.publr(&.{ "--as-admin", "media", "list", "--folder", "unsorted" });

    for (facts.media) |item| {
        try expect_in(check, "media list", media, item.filename);
        held += 1;
    }

    const secrets = try check.publr(&.{ "--as-admin", "secret", "list" });

    for (facts.secrets) |secret| {
        try expect_in(check, "secret list", secrets, secret.name);
        held += 1;
    }

    return held + @as(u32, @intCast(facts.pages.len));
}

/// The site served: health answers this release, every fact's page has its text, an admin
/// signs in and opens the admin, and a record can still be written and published.
fn expect_site(check: *Check, facts: facts_module.Facts) !u32 {
    std.debug.assert(check.port > 0);

    const port_text = try std.fmt.allocPrint(check.arena(), "{d}", .{check.port});
    var child = try std.process.spawn(check.init.io, .{
        .argv = &.{ check.binary, "serve", "--port", port_text },
        .cwd = .{
            .path = check.site_dir,
        },
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(check.init.io);

    const port = try smoke.read_port(check.init, child.stderr.?);
    const health = try smoke.http_get(check.init, port, "/api/health");
    const version = try std.fmt.allocPrint(check.arena(), "\"version\":\"{s}\"", .{check.version});

    try expect_in(check, "/api/health", health, version);

    for (facts.pages) |page| {
        const answer = try smoke.http_get(check.init, port, page.path);

        try expect_in(check, page.path, answer, page.contains);
    }

    if (facts.users.len > 0) {
        try expect_admin(check, port, facts.users[0].email);
    }

    if (facts.records.len > 0) {
        try expect_write(check, facts.records[0].type);
    }

    return @intCast(facts.pages.len);
}

fn expect_admin(check: *Check, port: u16, email: []const u8) !void {
    std.debug.assert(port > 0);
    std.debug.assert(email.len > 0);

    const body = try std.fmt.allocPrint(
        check.arena(),
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, facts_module.password },
    );
    const answer = try smoke.http_post(check.init, port, "/api/auth/sign-in", body);
    const marker = "Set-Cookie: ";
    const start = (std.mem.indexOf(u8, answer, marker) orelse
        return check.fail("signing in as {s} set no cookie: {s}", .{ email, answer })) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, answer, start, ';') orelse answer.len;
    const page = try smoke.http_get_cookie(check.init, port, "/admin", answer[start..end]);

    try expect_in(check, "/admin", page, "200 OK");
}

fn expect_write(check: *Check, content_type: []const u8) !void {
    std.debug.assert(content_type.len > 0);

    const created = try check.publr(&.{
        "--as-admin", "record",     "create",                                   "--type",
        content_type, "--document", "{\"title\":\"Written after the update\"}",
    });
    const Created = struct {
        id: []const u8,
    };
    const parsed = try std.json.parseFromSliceLeaky(Created, check.arena(), created, .{
        .ignore_unknown_fields = true,
    });

    _ = try check.publr(&.{ "--as-admin", "record", "publish", "--id", parsed.id });
}

/// The backup the gate took puts the site back as the fixture's release left it.
fn expect_restore(check: *Check) !void {
    std.debug.assert(check.from.len > 0);

    const listed = try check.publr(&.{"backups"});
    const to = try std.fmt.allocPrint(check.arena(), "-> {s}\n", .{check.version});
    var lines = std.mem.splitScalar(u8, listed, '\n');
    const name = while (lines.next()) |line| {
        if (std.mem.endsWith(u8, try std.fmt.allocPrint(check.arena(), "{s}\n", .{line}), to)) {
            break line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
        }
    } else return check.fail("no backup taken for the update to {s}:\n{s}", .{
        check.version,
        listed,
    });

    _ = try check.publr(&.{ "restore", name });

    const db_check = [_][]const u8{ "db", "check" };
    const found = try smoke.run_publr(check.init, check.binary, check.site_dir, &db_check);
    // Put back as it was: what `db check` said before the update, it says again.
    try expect_in(check, "db check after restore", found.stdout, check.before_opened);
}

fn expect_in(check: *Check, what: []const u8, text: []const u8, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);

    if (std.mem.indexOf(u8, text, needle) == null) {
        return check.fail("{s}: no \"{s}\" in:\n{s}", .{ what, needle, text });
    }
}
