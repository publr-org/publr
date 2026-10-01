//! Where a template's imports lead. Inside the app a template is named by its path from
//! the app's folder, `layouts/base.publr`; an import may also leave the app by `../` into
//! the project's apps folder, to another app's templates or a folder of shared ones (a
//! folder with no `app.zon`), and such a template is named from the apps folder,
//! `../shared/navbar.publr`. Nothing leaves the apps folder.
const std = @import("std");

/// How a template from outside the app is named: `../<folder>/<path>`.
pub const outside_prefix = "../";

pub const segments_max: u32 = 64;
pub const imports_max: u32 = 256;

pub const Error = error{ Unsupported, OutOfMemory };

/// What `spec`, imported by the template named `from`, names: a path inside the app, or
/// `../<folder>/<path>` outside it. `folder` is the app's own folder, so a path that leads
/// back into the app is the app's own name for it.
pub fn resolve(
    arena: std.mem.Allocator,
    from: []const u8,
    spec: []const u8,
    folder: []const u8,
) Error![]const u8 {
    std.debug.assert(from.len > 0);
    std.debug.assert(spec.len > 0);

    var segments: std.ArrayList([]const u8) = .empty;
    const dir = from[0 .. std.mem.lastIndexOfScalar(u8, from, '/') orelse 0];

    try walk(arena, &segments, dir);
    try walk(arena, &segments, spec);

    const items = segments.items;

    if (items.len == 0 or std.mem.eql(u8, items[items.len - 1], "..")) {
        return error.Unsupported;
    }

    const outside = std.mem.eql(u8, items[0], "..");

    if (outside and items.len < 3) {
        return error.Unsupported;
    }

    const own = outside and folder.len > 0 and std.mem.eql(u8, items[1], folder);
    const kept = if (own) items[2..] else items;

    std.debug.assert(kept.len > 0);

    return std.mem.join(arena, "/", kept);
}

/// Adds `path`'s segments to `segments`: `.` stays, `..` climbs, once past the app's own
/// folder into the apps folder and never past that.
fn walk(
    arena: std.mem.Allocator,
    segments: *std.ArrayList([]const u8),
    path: []const u8,
) Error!void {
    std.debug.assert(segments.items.len <= segments_max);
    std.debug.assert(path.len <= 1 << 16);

    var parts = std.mem.splitScalar(u8, path, '/');

    while (parts.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            continue;
        }

        if (std.mem.eql(u8, segment, "..")) {
            try climb(arena, segments);
            continue;
        }

        if (segments.items.len == segments_max) {
            return error.Unsupported;
        }

        try segments.append(arena, segment);
    }
}

fn climb(arena: std.mem.Allocator, segments: *std.ArrayList([]const u8)) Error!void {
    std.debug.assert(segments.items.len <= segments_max);

    const items = segments.items;

    if (items.len == 0) {
        return segments.append(arena, "..");
    }

    if (std.mem.eql(u8, items[0], "..") and items.len == 1) {
        return error.Unsupported;
    }

    _ = segments.pop();

    std.debug.assert(segments.items.len < items.len or items.len == 0);
}

/// Static module paths, parsed with the same TSX grammar at build time and reload.
pub fn specs(
    comptime syntax: type,
    arena: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
) Error![]const []const u8 {
    std.debug.assert(source.len <= 1 << 24);
    std.debug.assert(filename.len > 0);

    var found: std.ArrayList([]const u8) = .empty;
    const helper = std.mem.endsWith(u8, filename, ".js") or std.mem.endsWith(u8, filename, ".ts");
    const body = frontmatter(source) orelse if (helper) source else return &.{};
    const tree = syntax.syntax.parse(arena, body, filename) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        return error.Unsupported;
    };

    for (tree.statements) |statement| {
        switch (statement.type) {
            .ImportDeclaration, .ExportNamedDeclaration, .ExportAllDeclaration => {},
            else => continue,
        }

        const literal = statement.source orelse continue;
        const spec = literal.value.string;

        if (!std.mem.endsWith(u8, spec, ".publr") and !std.mem.endsWith(u8, spec, ".js") and
            !std.mem.endsWith(u8, spec, ".ts")) continue;

        if (found.items.len == imports_max) {
            return error.Unsupported;
        }

        try found.append(arena, spec);
    }

    return found.items;
}

fn frontmatter(source: []const u8) ?[]const u8 {
    std.debug.assert(source.len <= 1 << 24);

    const start = std.mem.trimStart(u8, source, " \t\r\n");

    if (!std.mem.startsWith(u8, start, "---")) {
        return null;
    }

    const after = start[3..];
    const end = std.mem.indexOf(u8, after, "\n---") orelse return null;

    std.debug.assert(end <= after.len);

    return after[0..end];
}

const Case = struct { wanted: []const u8, from: []const u8, spec: []const u8 };

test "an import resolves inside the app, out to the apps folder, and back into the app" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]Case{
        .{ .wanted = "layouts/b.publr", .from = "content/a.publr", .spec = "../layouts/b.publr" },
        .{ .wanted = "content/x.publr", .from = "content/a.publr", .spec = "./x.publr" },
        .{
            .wanted = "../shared/a.publr",
            .from = "layouts/b.publr",
            .spec = "../../shared/a.publr",
        },
        .{ .wanted = "../shared/mark.publr", .from = "../shared/nav.publr", .spec = "mark.publr" },
        .{
            .wanted = "layouts/b.publr",
            .from = "../shared/a.publr",
            .spec = "../www/layouts/b.publr",
        },
    };

    for (cases) |case| {
        const resolved = try resolve(arena, case.from, case.spec, "www");

        try std.testing.expectEqualStrings(case.wanted, resolved);
    }

    const other = try resolve(arena, "layouts/a.publr", "../../www/base.publr", "waitlist");

    try std.testing.expectEqualStrings("../www/base.publr", other);
}

test "an import may not leave the apps folder, nor name the apps folder itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const refused = [_][2][]const u8{
        .{ "layouts/a.publr", "../../../x.publr" },
        .{ "layouts/a.publr", "../../x.publr" },
        .{ "../shared/a.publr", "../../x.publr" },
    };

    for (refused) |pair| {
        try std.testing.expectError(error.Unsupported, resolve(arena, pair[0], pair[1], "www"));
    }
}

test "the frontmatter's .publr imports are listed, nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\---
        \\// a comment
        \\import Base from '../layouts/base.publr';
        \\import Nav from "../../shared/nav.publr"
        \\import Disclosure from '../interactive/Disclosure.ptsx';
        \\const post = Publr.build.getEntry();
        \\---
        \\<p>import Not from 'a.publr'</p>
    ;
    const found = try specs(@import("pjsx_syntax").template_syntax, arena, source, "index.publr");

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("../layouts/base.publr", found[0]);
    try std.testing.expectEqualStrings("../../shared/nav.publr", found[1]);
    try std.testing.expectEqual(
        @as(usize, 0),
        (try specs(
            @import("pjsx_syntax").template_syntax,
            arena,
            "<p>no frontmatter</p>",
            "index.publr",
        )).len,
    );
}

test "multiline helper imports and reexports use module grammar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const found = try specs(@import("pjsx_syntax").template_syntax, arena_state.allocator(),
        \\import {
        \\  seed,
        \\} from './seed.ts'; // trailing comment
        \\export { seed as generate } from './seed.ts'; import './setup.js';
        \\const text = "import fake from './fake.js'";
    , "lib/helpers.js");
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("./setup.js", found[2]);
}
