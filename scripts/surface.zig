//! What this Publr offers plugins and apps, and what it is removing (`.agents/specs`
//! `versioning.md`), from the built binary's `plugin surface`:
//!
//!   surface write <publr> <out.json>                  every page in one file, for a release
//!   surface list <publr> <src> [--before <day>]       each deprecation, where it is declared
//!   surface check <surface.json> <previous.json|-> <today>
//!                                                     nothing overdue; nothing gone unannounced
//!   surface prompt <surface.json> <previous.json|->   the release's migration prompt, Markdown
const std = @import("std");

const pages_max: u32 = 64;
const output_bytes_max: u32 = 8 << 20;
const files_max: u32 = 20_000;

const Deprecation = struct {
    /// `call`, `event`, `mod`: the key is `<kind>:<name>`, as `offered` writes it.
    kind: []const u8 = "call",
    name: []const u8,
    since: []const u8,
    removed_on: []const u8,
    instead: []const u8 = "",
    migration: []const u8,
};

const Surface = struct {
    publr: []const u8,
    offered: []const []const u8,
    deprecated: []const Deprecation = &.{},
};

const Page = struct {
    publr: []const u8,
    offered: []const []const u8,
    deprecated: []const Deprecation = &.{},
    more: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var iterator = try init.minimal.args.iterateAllocator(arena);
    var words: std.ArrayList([]const u8) = .empty;

    _ = iterator.next();

    while (iterator.next()) |word| {
        try words.append(arena, word);
    }

    std.debug.assert(words.items.len < 1 << 10);

    const given = words.items;
    const command = if (given.len > 0) given[0] else "";

    if (std.mem.eql(u8, command, "write") and given.len == 3) {
        const surface = try read_publr(init, given[1], given[2]);
        const text = try std.json.Stringify.valueAlloc(arena, surface, .{});

        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = given[2],
            .data = text,
        });
        return 0;
    }

    if (std.mem.eql(u8, command, "list") and (given.len == 3 or given.len == 5)) {
        const before = if (given.len == 5) given[4] else "9999-12-31";

        return list(init, try read_publr(init, given[1], ".zig-cache/surface"), given[2], before);
    }

    if (std.mem.eql(u8, command, "check") and (given.len == 4 or given.len == 5)) {
        const broke = if (given.len == 5) try read_unreleased(init, given[4]) else "";

        return check(.{
            .current = try read_file(init, given[1]),
            .previous = try read_previous(init, given[2]),
            .today = given[3],
            .broke = broke,
        });
    }

    if (std.mem.eql(u8, command, "prompt") and (given.len == 3 or given.len == 4)) {
        const broke = if (given.len == 4) try read_unreleased(init, given[3]) else "";

        try prompt(init, try read_file(init, given[1]), try read_previous(init, given[2]), broke);
        return 0;
    }

    std.debug.print("usage: surface write|list|check|prompt … (see scripts/surface.zig)\n", .{});
    return 2;
}

/// Every page of `publr plugin surface`, asked of a site made in `<work>.site`.
fn read_publr(init: std.process.Init, publr: []const u8, work: []const u8) !Surface {
    std.debug.assert(publr.len > 0);
    std.debug.assert(work.len > 0);

    const arena = init.arena.allocator();
    const site = try std.fmt.allocPrint(arena, "{s}.site", .{work});
    // Run from inside the site, so a path relative to here would not be found.
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, publr, arena);
    var offered: std.ArrayList([]const u8) = .empty;
    var first: ?Page = null;
    var page_index: u32 = 0;

    try std.Io.Dir.cwd().createDirPath(init.io, site);

    while (page_index < pages_max) : (page_index += 1) {
        const offset = try std.fmt.allocPrint(arena, "{d}", .{offered.items.len});
        const result = try std.process.run(arena, init.io, .{
            .argv = &.{ binary, "--as-admin", "plugin", "surface", "--offset", offset },
            .cwd = .{
                .path = site,
            },
            .stdout_limit = .limited(output_bytes_max),
            .stderr_limit = .limited(output_bytes_max),
        });

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("surface: `plugin surface` failed: {s}\n", .{result.stderr});
            return error.PublrFailed;
        }

        const page = try std.json.parseFromSliceLeaky(Page, arena, result.stdout, .{
            .ignore_unknown_fields = true,
        });

        try offered.appendSlice(arena, page.offered);
        first = first orelse page;

        if (!page.more) {
            break;
        }
    }

    const found = first orelse return error.PublrFailed;

    return .{
        .publr = found.publr,
        .offered = offered.items,
        .deprecated = found.deprecated,
    };
}

fn read_file(init: std.process.Init, path: []const u8) !Surface {
    std.debug.assert(path.len > 0);

    const arena = init.arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        arena,
        .limited(output_bytes_max),
    );

    return std.json.parseFromSliceLeaky(Surface, arena, text, .{
        .ignore_unknown_fields = true,
    });
}

/// The previous release's surface, or none (`-`, or a file not there: the first release
/// that has one).
fn read_previous(init: std.process.Init, path: []const u8) !?Surface {
    std.debug.assert(path.len > 0);

    if (std.mem.eql(u8, path, "-")) {
        return null;
    }

    return read_file(init, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Each deprecation removed before `before`, with where it is declared under `src`.
fn list(init: std.process.Init, surface: Surface, src: []const u8, before: []const u8) !u8 {
    std.debug.assert(src.len > 0);
    std.debug.assert(before.len > 0);

    const arena = init.arena.allocator();
    var shown: u32 = 0;

    for (surface.deprecated) |item| {
        if (std.mem.order(u8, item.removed_on, before) != .lt) {
            continue;
        }

        // An operation declares `pub const name`; an event or a mod `.name = ` in a literal.
        const declaration = if (std.mem.eql(u8, item.kind, "call"))
            try std.fmt.allocPrint(arena, "pub const name = \"{s}\";", .{item.name})
        else if (std.mem.eql(u8, item.kind, "template"))
            try std.fmt.allocPrint(arena, ".name = \"{s}\",", .{bare_feature(item.name)})
        else
            try std.fmt.allocPrint(arena, ".name = \"{s}\",", .{item.name});
        const place = try declared_at(init, src, declaration);

        std.debug.print("{s}:{s}  removed on {s}  (deprecated since {s})\n  declared at {s}\n", .{
            item.kind,
            item.name,
            item.removed_on,
            item.since,
            place,
        });

        if (item.instead.len > 0) {
            std.debug.print("  instead: {s}\n", .{item.instead});
        }

        std.debug.print("  {s}\n\n", .{item.migration});
        shown += 1;
    }

    std.debug.print("{d} deprecated before {s}\n", .{ shown, before });

    return 0;
}

/// `file:line` of the first line under `src` holding `text`, or "not found under src".
fn declared_at(init: std.process.Init, src: []const u8, text: []const u8) ![]const u8 {
    std.debug.assert(text.len > 0);

    const arena = init.arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(init.io, src, .{
        .iterate = true,
    });
    defer dir.close(init.io);

    var walker = try dir.walk(init.gpa);
    defer walker.deinit();

    var seen: u32 = 0;

    while (try walker.next(init.io)) |entry| : (seen += 1) {
        if (seen == files_max) {
            return error.TooManyFiles;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }

        const limit: std.Io.Limit = .limited(output_bytes_max);
        const content = try dir.readFileAlloc(init.io, entry.path, arena, limit);
        const at = std.mem.indexOf(u8, content, text) orelse continue;
        const line = std.mem.count(u8, content[0..at], "\n") + 1;

        return std.fmt.allocPrint(arena, "{s}/{s}:{d}", .{ src, entry.path, line });
    }

    return "not found under src";
}

const Checked = struct {
    current: Surface,
    previous: ?Surface,
    today: []const u8,
    /// BREAKING.md's `## Unreleased` section; empty without the file.
    broke: []const u8 = "",
};

/// Fails when an item is past its day and still here; before 1.0, when an item is gone with
/// no entry in BREAKING.md; from 1.0, when one is gone without having been deprecated until
/// its day (versioning.md, sections 2 and 11).
fn check(checked: Checked) u8 {
    std.debug.assert(checked.today.len == 10);
    std.debug.assert(checked.current.offered.len > 0);

    var failures: u32 = 0;
    const stable = !std.mem.startsWith(u8, checked.current.publr, "0.");

    for (checked.current.deprecated) |item| {
        if (std.mem.order(u8, item.removed_on, checked.today) != .gt) {
            std.debug.print("surface: {s} was due to go on {s}: remove it, or move its " ++
                "`removed_on` later\n", .{ item.name, item.removed_on });
            failures += 1;
        }
    }

    if (checked.previous) |before| {
        failures += if (stable)
            gone_early(before, checked.current, checked.today)
        else
            gone_unexplained(before, checked.current, checked.broke);
    }

    return if (failures == 0) 0 else 1;
}

/// Before 1.0: each item gone since `before` with no `### \`<item>\`` entry in `broke`.
fn gone_unexplained(before: Surface, current: Surface, broke: []const u8) u32 {
    std.debug.assert(current.offered.len > 0);
    std.debug.assert(broke.len <= output_bytes_max);

    var failures: u32 = 0;

    for (before.offered) |item| {
        if (contains(current.offered, item) or entered(broke, item)) {
            continue;
        }

        std.debug.print("surface: {s} is gone with no entry in BREAKING.md. Under " ++
            "## Unreleased, add the heading ### `{s}` and say what to use instead\n", .{
            item,
            item,
        });
        failures += 1;
    }

    return failures;
}

/// From 1.0: each item gone since `before` that was not deprecated, or not until its day.
fn gone_early(before: Surface, current: Surface, today: []const u8) u32 {
    std.debug.assert(today.len == 10);
    std.debug.assert(current.offered.len > 0);

    var failures: u32 = 0;

    for (before.offered) |item| {
        if (contains(current.offered, item)) {
            continue;
        }

        const announced = deprecation_of(before, item) orelse {
            std.debug.print("surface: {s} is gone without having been deprecated: deprecate " ++
                "it in a release first (`publr.Deprecated`)\n", .{item});
            failures += 1;
            continue;
        };

        if (std.mem.order(u8, announced.removed_on, today) == .gt) {
            std.debug.print("surface: {s} is gone before {s}, the day it was to go: keep it " ++
                "until then\n", .{ item, announced.removed_on });
            failures += 1;
        }
    }

    return failures;
}

/// Whether `section` has an entry for `item`: a `### \`<item>\`` heading.
fn entered(section: []const u8, item: []const u8) bool {
    std.debug.assert(item.len > 0);

    var lines = std.mem.splitScalar(u8, section, '\n');

    while (lines.next()) |line| {
        const heading = std.mem.trimEnd(u8, line, " \r");
        const framed = heading.len == item.len + "### ``".len and
            std.mem.startsWith(u8, heading, "### `") and std.mem.endsWith(u8, heading, "`");

        if (framed and std.mem.eql(u8, heading["### `".len .. heading.len - 1], item)) {
            return true;
        }
    }

    return false;
}

/// BREAKING.md's `## Unreleased` section, up to the next `## `; empty without one.
fn read_unreleased(init: std.process.Init, path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0);

    const text = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(output_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return "",
        else => return err,
    };
    const start = std.mem.indexOf(u8, text, "\n## Unreleased\n") orelse return "";
    const body = text[start + "\n## Unreleased\n".len ..];
    const end = std.mem.indexOf(u8, body, "\n## ") orelse body.len;

    return body[0..end];
}

/// The release's migration prompt: what it changed (BREAKING.md's `broke`), what it removed,
/// what it deprecated, what is still on its way out; one entry per item, keyed by its name as
/// a plugin's `uses` writes it.
fn prompt(init: std.process.Init, current: Surface, previous: ?Surface, broke: []const u8) !void {
    std.debug.assert(current.publr.len > 0);
    std.debug.assert(broke.len <= output_bytes_max);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    try out.print("# Moving plugins and apps to Publr {s}\n\n", .{current.publr});

    var written = try write_broke(out, broke);

    if (previous) |before| {
        for (before.deprecated) |item| {
            if (!keyed_any(current.offered, item)) {
                try write_entry(out, "Removed", item);
                written += 1;
            }
        }
    }

    for (current.deprecated) |item| {
        const fresh = if (previous) |before| !keyed_in(before.deprecated, item) else true;

        try write_entry(out, if (fresh) "Deprecated in this release" else "On its way out", item);
        written += 1;
    }

    if (written == 0) {
        try out.writeAll("Nothing in this release asks plugins or apps to change.\n");
    }

    try out.flush();
}

fn write_entry(out: *std.Io.Writer, heading: []const u8, item: Deprecation) !void {
    std.debug.assert(heading.len > 0);
    std.debug.assert(item.name.len > 0);

    try out.print("## `{s}:{s}`: {s}\n\n", .{ item.kind, item.name, heading });
    try out.print("Deprecated since {s}, removed on {s}.", .{ item.since, item.removed_on });

    if (item.instead.len > 0) {
        try out.print(" Use `{s}` instead.", .{item.instead});
    }

    try out.print("\n\n{s}\n\n", .{item.migration});
}

/// The deprecation whose key (`<kind>:<name>`) is `key`.
fn deprecation_of(surface: Surface, key: []const u8) ?Deprecation {
    std.debug.assert(key.len > 0);

    for (surface.deprecated) |item| {
        if (keyed(item, key)) {
            return item;
        }
    }

    return null;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |one| {
        if (std.mem.eql(u8, one, name)) {
            return true;
        }
    }

    return false;
}

/// Whether `key` is `item`'s `<kind>:<name>`.
fn keyed(item: Deprecation, key: []const u8) bool {
    std.debug.assert(item.kind.len > 0);

    return key.len == item.kind.len + 1 + item.name.len and
        std.mem.startsWith(u8, key, item.kind) and key[item.kind.len] == ':' and
        std.mem.eql(u8, key[item.kind.len + 1 ..], item.name);
}

/// Whether one of `keys` is `item`'s.
fn keyed_any(keys: []const []const u8, item: Deprecation) bool {
    std.debug.assert(item.name.len > 0);

    for (keys) |key| {
        if (keyed(item, key)) {
            return true;
        }
    }

    return false;
}

/// Whether `items` holds a deprecation of the same item as `item`.
fn keyed_in(items: []const Deprecation, item: Deprecation) bool {
    std.debug.assert(item.name.len > 0);

    for (items) |other| {
        if (std.mem.eql(u8, other.kind, item.kind) and std.mem.eql(u8, other.name, item.name)) {
            return true;
        }
    }

    return false;
}

/// BREAKING.md's entries for this release, each `### \`<item>\`` made the prompt's
/// `## \`<item>\`: Changed in this release`; how many.
fn write_broke(out: *std.Io.Writer, broke: []const u8) !u32 {
    std.debug.assert(broke.len <= output_bytes_max);

    var written: u32 = 0;
    var lines = std.mem.splitScalar(u8, broke, '\n');

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "### ")) {
            try out.print("## {s}: Changed in this release\n", .{line["### ".len..]});
            written += 1;
            continue;
        }

        if (written > 0) {
            try out.print("{s}\n", .{line});
        }
    }

    std.debug.assert(written <= broke.len);

    return written;
}

/// A template feature's name as `features.zig` lists it: `getEntry` for `Publr.*.getEntry`.
fn bare_feature(name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const scope = "Publr.*.";

    return if (std.mem.startsWith(u8, name, scope)) name[scope.len..] else name;
}
