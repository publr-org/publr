//! Upgrade tests (`../.agents/specs/upgrade-testing.md`).
//!
//!   upgrade matrix <publr> <version> <fixtures> <work> [--from <release>] [--previous <publr>]
//!       Every fixture in <fixtures> updated by <publr>, one line each; exits 1 on any failure.
//!
//! <fixtures> is `.zig-cache/upgrade-sites`: each release's site, and the lived site, are that
//! release's assets on GitHub, never files in the repository; CI fetches them there.
//!   upgrade draft <publr> <version> <fixtures> <work>
//!       `src/lib/db/migrations/unreleased.zig` drafted from what the schema adds to the last
//!       release's.
//!   upgrade fixture <publr> <version> <fixtures> <work>
//!       The release's fixture (<version>.tar.gz) and the lived site carried on to it.

const std = @import("std");
const facts_module = @import("upgrade/facts.zig");
const seed = @import("upgrade/seed.zig");
const check_module = @import("upgrade/check.zig");
const frozen = @import("upgrade/frozen.zig");
const smoke = @import("smoke.zig");

const lived_name = "lived";
const port: u16 = 8093;
const fixtures_max: u32 = 4096;
/// Readers are tolerant from here on: a release before it cannot run on a newer database.
const step_back_baseline: std.SemanticVersion = .{
    .major = 0,
    .minor = 3,
    .patch = 0,
};

const Arguments = struct {
    command: []const u8,
    binary: []const u8,
    version: []const u8,
    fixtures: []const u8,
    work: []const u8,
    from: ?[]const u8 = null,
    previous: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !u8 {
    std.debug.assert(fixtures_max > 0);

    const args = parse(init) catch {
        std.debug.print("usage: upgrade matrix|fixture <publr> <version> <fixtures> <work> " ++
            "[--from <release>] [--previous <publr>]\n", .{});
        return 2;
    };

    // Fetched by CI, empty on a fresh clone: no fixtures is a run that checks nothing.
    try std.Io.Dir.cwd().createDirPath(init.io, args.fixtures);

    if (std.mem.eql(u8, args.command, "matrix")) {
        return matrix(init, args);
    }

    if (std.mem.eql(u8, args.command, "fixture")) {
        try fixture(init, args);
        return 0;
    }

    if (std.mem.eql(u8, args.command, "draft")) {
        return draft(init, args);
    }

    return 2;
}

fn parse(init: std.process.Init) !Arguments {
    std.debug.assert(port > 0);

    const arena = init.arena.allocator();
    var iterator = try init.minimal.args.iterateAllocator(arena);

    _ = iterator.next();

    var args: Arguments = .{
        .command = iterator.next() orelse return error.Usage,
        .binary = iterator.next() orelse return error.Usage,
        .version = iterator.next() orelse return error.Usage,
        .fixtures = iterator.next() orelse return error.Usage,
        .work = iterator.next() orelse return error.Usage,
    };

    while (iterator.next()) |flag| {
        const value = iterator.next() orelse return error.Usage;

        if (std.mem.eql(u8, flag, "--from")) {
            args.from = if (value.len == 0) null else value;
        } else if (std.mem.eql(u8, flag, "--previous")) {
            args.previous = if (value.len == 0) null else value;
        } else {
            return error.Usage;
        }
    }

    std.debug.assert(args.version.len > 0);

    return args;
}

/// Every fixture, oldest first, then the lived site.
fn matrix(init: std.process.Init, given: Arguments) !u8 {
    std.debug.assert(given.fixtures.len > 0);
    std.debug.assert(port > 0);

    const arena = init.arena.allocator();
    var args = given;

    args.previous = try stepping_back(init, given);

    if (!try frozen.expect_unchanged(init, args.fixtures)) {
        return 1;
    }

    const releases = try releases_in(init, args.fixtures);

    std.debug.print("upgrade to {s} from {d} release(s)\n", .{ args.version, releases.len });

    var failed: u32 = 0;
    var passed: u32 = 0;
    var names: std.ArrayList([]const u8) = .empty;

    try names.appendSlice(arena, releases);

    const lived_archive = try std.fs.path.join(arena, &.{ args.fixtures, lived_name ++ ".tar.gz" });

    if (try exists(init, lived_archive)) {
        try names.append(arena, lived_name);
    }

    for (names.items) |name| {
        if (args.from) |only| {
            if (!std.mem.eql(u8, only, name)) {
                continue;
            }
        }

        if (try one(init, args, name)) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    std.debug.print("{d} passed, {d} failed\n", .{ passed, failed });

    return if (failed == 0) 0 else 1;
}

/// The release to step back to, unless it predates tolerant readers: a step back is promised
/// from the baseline on.
fn stepping_back(init: std.process.Init, args: Arguments) !?[]const u8 {
    std.debug.assert(args.work.len > 0);
    std.debug.assert(args.version.len > 0);

    const previous = args.previous orelse return null;
    const result = try smoke.run_publr(init, previous, ".", &.{"--version"});
    const printed = std.mem.trim(u8, result.stdout, " \n");
    const name = if (std.mem.startsWith(u8, printed, "publr ")) printed["publr ".len..] else "";
    const version = std.SemanticVersion.parse(name) catch {
        std.debug.print("upgrade: {s} reports no version: {s}\n", .{ previous, printed });
        return error.UnknownPrevious;
    };

    if (version.order(step_back_baseline) == .lt) {
        std.debug.print("upgrade: no step back to {s}: readers are tolerant from 0.3.0\n", .{
            name,
        });
        return null;
    }

    return previous;
}

/// One fixture unpacked and checked, its line printed; whether it passed.
fn one(init: std.process.Init, args: Arguments, name: []const u8) !bool {
    std.debug.assert(name.len > 0);

    const arena = init.arena.allocator();
    const site = try std.fs.path.join(arena, &.{ args.work, name });
    const archive = try std.fmt.allocPrint(arena, "{s}/{s}.tar.gz", .{ args.fixtures, name });

    try unpack(init, archive, site);

    const facts = try facts_module.read(init.io, arena, site);
    const from = if (facts.releases.len > 0) facts.releases[facts.releases.len - 1] else name;
    var check: check_module.Check = .{
        .init = init,
        .binary = try absolute(init, args.binary),
        .site_dir = site,
        .from = from,
        .version = args.version,
        .previous = if (args.previous) |previous| try absolute(init, previous) else null,
        .port = port,
    };
    const result = check_module.run(&check) catch |err| {
        const why = if (check.failure.len > 0) check.failure else @errorName(err);

        std.debug.print("  {s:<8} FAILED  {s}\n           kept in {s}\n" ++
            "           {s} --db {s}/data/publr.db serve\n", .{
            name,
            why,
            site,
            args.binary,
            site,
        });
        return false;
    };

    std.debug.print("  {s:<8} {d} migration(s)  gate {d} ms  shape ok  facts {d}/{d}  " ++
        "pages {d}  back {t}  restore ok\n", .{
        name,
        result.migrations,
        result.gate_ms,
        result.facts_held,
        result.facts_total,
        result.pages,
        result.back,
    });

    try std.Io.Dir.cwd().deleteTree(init.io, site);

    return true;
}

/// The next migration drafted against the last release's schema, from its tag.
fn draft(init: std.process.Init, args: Arguments) !u8 {
    std.debug.assert(args.fixtures.len > 0);

    const arena = init.arena.allocator();
    const fixtures = try absolute(init, args.fixtures);
    const repo = std.fs.path.dirname(std.fs.path.dirname(fixtures) orelse ".") orelse ".";
    const target = try std.fs.path.join(arena, &.{ repo, "src/lib/db/migrations/unreleased.zig" });

    if (try exists(init, target)) {
        std.debug.print("upgrade: {s} is already there: finish it, or remove it to draft " ++
            "again\n", .{target});
        return 1;
    }

    const tag = try frozen.latest_tag(init, repo) orelse {
        std.debug.print("upgrade: no release tag here to draft against\n", .{});
        return 1;
    };
    const spec = try std.fmt.allocPrint(arena, "{s}:src/lib/db/schema.sql", .{tag});
    const shown = try std.process.run(arena, init.io, .{
        .argv = &.{ "git", "-C", repo, "show", spec },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(64 << 10),
    });

    if (shown.term != .exited or shown.term.exited != 0) {
        std.debug.print("upgrade: git show {s}: {s}\n", .{ spec, shown.stderr });
        return 1;
    }

    const released = try std.fs.path.join(arena, &.{ args.work, "released-schema.sql" });

    try std.Io.Dir.cwd().createDirPath(init.io, args.work);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = released,
        .data = shown.stdout,
    });

    const text = try seed.call(init, try absolute(init, args.binary), args.work, &.{
        "db", "draft", released,
    });

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(target).?);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = target,
        .data = text,
    });
    std.debug.print("upgrade: drafted {s} against {s}. Finish it, then add it to " ++
        "`core` in src/lib/db/migrations.zig:\n" ++
        "    .of(\n        \"publr\",\n        \"unreleased\",\n" ++
        "        @import(\"migrations/unreleased.zig\"),\n" ++
        "        @embedFile(\"migrations/unreleased.zig\"),\n    ),\n", .{ target, tag });

    return 0;
}

/// The release's fixture, made from nothing, and the lived site carried on to it.
fn fixture(init: std.process.Init, args: Arguments) !void {
    std.debug.assert(args.version.len > 0);

    const arena = init.arena.allocator();
    const binary = try absolute(init, args.binary);
    const fresh = try std.fs.path.join(arena, &.{ args.work, "fresh" });
    const cwd = std.Io.Dir.cwd();

    try cwd.deleteTree(init.io, fresh);
    try cwd.createDirPath(init.io, fresh);

    const made = try seed.run(init, binary, fresh, args.version, true);

    try seed.expect_every_table(init, binary, fresh);
    try facts_module.write(init.io, arena, fresh, made);
    try pack(init, fresh, try std.fmt.allocPrint(arena, "{s}/{s}.tar.gz", .{
        args.fixtures,
        args.version,
    }));
    std.debug.print("upgrade: fixture {s}: {d} facts\n", .{ args.version, made.count() });

    try carry_lived(init, args, binary, made);
}

/// The lived site, checked by this release and seeded on: rows of every release side by
/// side. The first release's is its fresh fixture.
fn carry_lived(
    init: std.process.Init,
    args: Arguments,
    binary: []const u8,
    fresh_facts: facts_module.Facts,
) !void {
    std.debug.assert(binary.len > 0);
    std.debug.assert(fresh_facts.releases.len == 1);

    const arena = init.arena.allocator();
    const archive = try std.fmt.allocPrint(arena, "{s}/{s}.tar.gz", .{ args.fixtures, lived_name });
    const fresh = try std.fs.path.join(arena, &.{ args.work, "fresh" });

    if (!try exists(init, archive)) {
        try pack(init, fresh, archive);
        std.debug.print("upgrade: lived site starts at {s}\n", .{args.version});
        return;
    }

    if (!try one(init, args, lived_name)) {
        return error.LivedSiteFailed;
    }

    const site = try std.fs.path.join(arena, &.{ args.work, lived_name });

    try unpack(init, archive, site);

    const history = try facts_module.read(init.io, arena, site);

    // Opened by this release first, so its seed writes beside rows the gate brought up.
    _ = try seed.call(init, binary, site, &.{ "--as-admin", "heartbeat", "check" });

    const added = try seed.run(init, binary, site, args.version, false);
    const all = try facts_module.Facts.append(arena, history, added);

    try seed.expect_every_table(init, binary, site);
    const backups = try std.fs.path.join(arena, &.{ site, "data", "backups" });

    try std.Io.Dir.cwd().deleteTree(init.io, backups);
    try facts_module.write(init.io, arena, site, all);
    try pack(init, site, archive);
    std.debug.print("upgrade: lived site carried to {s}: {d} facts\n", .{
        args.version,
        all.count(),
    });
}

/// The fixtures' releases, oldest first.
fn releases_in(init: std.process.Init, fixtures: []const u8) ![]const []const u8 {
    std.debug.assert(fixtures.len > 0);
    std.debug.assert(fixtures_max > 0);

    const arena = init.arena.allocator();
    const options: std.Io.Dir.OpenOptions = .{
        .iterate = true,
    };
    var dir = std.Io.Dir.cwd().openDir(init.io, fixtures, options) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(init.io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(init.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".tar.gz") or names.items.len == fixtures_max) {
            continue;
        }

        const name = entry.name[0 .. entry.name.len - ".tar.gz".len];

        if (std.SemanticVersion.parse(name)) |_| {
            try names.append(arena, try arena.dupe(u8, name));
        } else |_| {}
    }

    std.mem.sort([]const u8, names.items, {}, older_first);

    return names.items;
}

fn older_first(_: void, left: []const u8, right: []const u8) bool {
    const left_version = std.SemanticVersion.parse(left) catch unreachable;
    const right_version = std.SemanticVersion.parse(right) catch unreachable;

    return left_version.order(right_version) == .lt;
}

fn unpack(init: std.process.Init, archive: []const u8, site: []const u8) !void {
    std.debug.assert(archive.len > 0);
    std.debug.assert(site.len > 0);

    try std.Io.Dir.cwd().deleteTree(init.io, site);
    try std.Io.Dir.cwd().createDirPath(init.io, site);
    try tar(init, &.{ "tar", "-xzf", archive, "-C", site });
}

fn pack(init: std.process.Init, site: []const u8, archive: []const u8) !void {
    std.debug.assert(archive.len > 0);
    std.debug.assert(site.len > 0);

    try tar(init, &.{ "tar", "-czf", archive, "-C", site, "." });
}

fn tar(init: std.process.Init, argv: []const []const u8) !void {
    std.debug.assert(argv.len > 2);

    const result = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    });

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("upgrade: {s} failed: {s}\n", .{ argv[1], result.stderr });
        return error.TarFailed;
    }
}

fn absolute(init: std.process.Init, path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0);

    return std.Io.Dir.cwd().realPathFileAlloc(init.io, path, init.arena.allocator());
}

fn exists(init: std.process.Init, path: []const u8) !bool {
    std.debug.assert(path.len > 0);

    std.Io.Dir.cwd().access(init.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}
