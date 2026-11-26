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

    if (std.mem.eql(u8, command, "check") and given.len == 4) {
        return check(try read_file(init, given[1]), try read_previous(init, given[2]), given[3]);
    }

    if (std.mem.eql(u8, command, "prompt") and given.len == 3) {
        try prompt(init, try read_file(init, given[1]), try read_previous(init, given[2]));
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

        const declaration = try std.fmt.allocPrint(arena, "pub const name = \"{s}\";", .{
            item.name,
        });
        const place = try declared_at(init, src, declaration);

        std.debug.print("{s}  removed on {s}  (deprecated since {s})\n  declared at {s}\n", .{
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

/// Fails when an item is past its day and still here, or gone without having been deprecated
/// for at least that long.
fn check(current: Surface, previous: ?Surface, today: []const u8) u8 {
    std.debug.assert(today.len == 10);
    std.debug.assert(current.offered.len > 0);

    var failures: u32 = 0;

    for (current.deprecated) |item| {
        if (std.mem.order(u8, item.removed_on, today) != .gt) {
            std.debug.print("surface: {s} was due to go on {s}: remove it, or move its " ++
                "`removed_on` later\n", .{ item.name, item.removed_on });
            failures += 1;
        }
    }

    const before = previous orelse return if (failures == 0) 0 else 1;

    for (before.offered) |item| {
        if (contains(current.offered, "", item)) {
            continue;
        }

        const announced = deprecation_of(before, item) orelse {
            std.debug.print("surface: {s} is gone without having been deprecated: deprecate " ++
                "it in a release first (`publr.Deprecated`)\n", .{item});
            failures += 1;
            continue;
        };
        const due = std.mem.order(u8, announced.removed_on, today) != .gt;

        if (!due) {
            std.debug.print("surface: {s} is gone before {s}, the day it was to go: keep it " ++
                "until then\n", .{ item, announced.removed_on });
            failures += 1;
        }
    }

    return if (failures == 0) 0 else 1;
}

/// The release's migration prompt: what it removed, what it deprecated, what is still on its
/// way out; one entry per item, keyed by its name as a plugin's `uses` writes it.
fn prompt(init: std.process.Init, current: Surface, previous: ?Surface) !void {
    std.debug.assert(current.publr.len > 0);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    try out.print("# Moving plugins and apps to Publr {s}\n\n", .{current.publr});

    var written: u32 = 0;

    if (previous) |before| {
        for (before.deprecated) |item| {
            if (!contains(current.offered, "call:", item.name)) {
                try write_entry(out, "Removed", item);
                written += 1;
            }
        }
    }

    for (current.deprecated) |item| {
        const fresh = if (previous) |before| deprecation_of(before, item.name) == null else true;

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

    try out.print("## `call:{s}`: {s}\n\n", .{ item.name, heading });
    try out.print("Deprecated since {s}, removed on {s}.", .{ item.since, item.removed_on });

    if (item.instead.len > 0) {
        try out.print(" Use `{s}` instead.", .{item.instead});
    }

    try out.print("\n\n{s}\n\n", .{item.migration});
}

fn deprecation_of(surface: Surface, name: []const u8) ?Deprecation {
    std.debug.assert(name.len > 0);

    const bare = if (std.mem.startsWith(u8, name, "call:")) name["call:".len..] else name;

    for (surface.deprecated) |item| {
        if (std.mem.eql(u8, item.name, bare)) {
            return item;
        }
    }

    return null;
}

fn contains(names: []const []const u8, comptime prefix: []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |one| {
        if (one.len == prefix.len + name.len and std.mem.startsWith(u8, one, prefix) and
            std.mem.eql(u8, one[prefix.len..], name))
        {
            return true;
        }
    }

    return false;
}
