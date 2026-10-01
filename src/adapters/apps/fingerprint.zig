const std = @import("std");
const spec_module = @import("spec.zig");

const Spec = spec_module.Spec;
const File = spec_module.File;

pub const version_len: u32 = 16;
pub const assets_max = spec_module.assets_max;

/// An embedded asset under the fingerprint, owned by the app.
pub const Asset = struct { path: []const u8, data: []const u8 };

/// The generated code and the CSS as one token: `?v=` on every generated URL.
pub fn stamp(spec: *const Spec, css: []const u8) [version_len]u8 {
    std.debug.assert(spec.assets.len <= assets_max);
    std.debug.assert(spec.assets.len > 0);

    var hash = std.hash.Fnv1a_64.init();
    var out: [version_len]u8 = undefined;

    for (spec.assets) |file| {
        hash.update(file.path);
        hash.update(file.data);
    }

    hash.update(css);
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{hash.final()}) catch unreachable;

    return out;
}

/// Every template's path and text, the fingerprint, the app's address and core's own source
/// (`engine_stamp`: a Publr that renders differently builds every page again), as one stamp.
pub fn build_stamp(
    spec: *const Spec,
    version: *const [version_len]u8,
    url: []const u8,
) [version_len]u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(spec.name.len > 0);

    var hash = std.hash.Fnv1a_64.init();
    var out: [version_len]u8 = undefined;

    for (spec.templates) |file| {
        hash.update(file.path);
        hash.update(file.data);
    }

    hash.update(version);
    hash.update(url);
    hash.update(spec_module.engine_stamp);
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{hash.final()}) catch unreachable;

    return out;
}

/// The embedded assets under the fingerprint: every `"./x.js"` import in a JS file becomes
/// `"./x.js?v=<token>"`, so a module reached through another is as immutable as the one
/// the page linked. Everything else is embedded as it is.
pub fn rewrite(
    gpa: std.mem.Allocator,
    files: []const File,
    version: *const [version_len]u8,
) ![]const Asset {
    std.debug.assert(files.len <= assets_max);
    std.debug.assert(version.len == version_len);

    const rewritten = try gpa.alloc(Asset, files.len);
    var done: u32 = 0;
    errdefer {
        for (rewritten[0..done]) |file| {
            gpa.free(file.data);
        }

        gpa.free(rewritten);
    }

    for (files, rewritten) |embedded, *out| {
        out.* = .{
            .path = embedded.path,
            .data = try fingerprint_imports(gpa, files, embedded, version),
        };
        done += 1;
    }

    return rewritten;
}

fn fingerprint_imports(
    gpa: std.mem.Allocator,
    files: []const File,
    embedded: File,
    version: *const [version_len]u8,
) ![]const u8 {
    std.debug.assert(embedded.path.len > 0);
    std.debug.assert(version.len == version_len);

    if (!std.mem.endsWith(u8, embedded.path, ".js")) {
        return gpa.dupe(u8, embedded.data);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var data: []const u8 = embedded.data;

    for (files) |sibling| {
        if (!std.mem.endsWith(u8, sibling.path, ".js")) {
            continue;
        }

        for ([_]u8{ '"', '\'' }) |quote| {
            const bare = try std.fmt.allocPrint(arena, "{c}./{s}{c}", .{
                quote,
                sibling.path,
                quote,
            });
            const stamped = try std.fmt.allocPrint(arena, "{c}./{s}?v={s}{c}", .{
                quote,
                sibling.path,
                version,
                quote,
            });

            data = try std.mem.replaceOwned(u8, arena, data, bare, stamped);
        }
    }

    return gpa.dupe(u8, data);
}

pub fn free(gpa: std.mem.Allocator, assets: []const Asset) void {
    std.debug.assert(assets.len <= assets_max);

    for (assets) |file| {
        gpa.free(file.data);
    }

    gpa.free(assets);
}

/// The JS files `root` imports, transitively, breadth first, each once, by path.
pub fn imports_of(
    gpa: std.mem.Allocator,
    assets: []const Asset,
    root: []const u8,
) ![]const []const u8 {
    std.debug.assert(root.len > 0);
    std.debug.assert(assets.len <= assets_max);

    var reached: [assets_max][]const u8 = undefined;
    var count: u32 = 0;
    var next: u32 = 0;

    reached[0] = root;
    count += 1;

    while (next < count) : (next += 1) {
        const data = find(assets, reached[next]) orelse continue;

        for (assets) |candidate| {
            const already = contains(reached[0..count], candidate.path);
            const imported = std.mem.indexOf(u8, data, candidate.path) != null;

            if (std.mem.endsWith(u8, candidate.path, ".js") and imported and !already) {
                reached[count] = candidate.path;
                count += 1;
            }
        }
    }

    return gpa.dupe([]const u8, reached[1..count]);
}

pub fn find(assets: []const Asset, path: []const u8) ?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(assets.len <= assets_max);

    for (assets) |file| {
        if (std.mem.eql(u8, file.path, path)) {
            return file.data;
        }
    }

    return null;
}

fn contains(list: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);
    std.debug.assert(list.len <= assets_max);

    for (list) |item| {
        if (std.mem.eql(u8, item, wanted)) {
            return true;
        }
    }

    return false;
}

const test_files = [_]File{
    .{ .path = "a.js", .data = "import './b.js';" },
    .{ .path = "b.js", .data = "export const bee = 1;" },
    .{ .path = "c.css", .data = "import './b.js';" },
};

const test_spec: Spec = .{
    .name = "test",
    .label = "test",
    .folder = "test",
    .mount = .{ .path = "/" },
    .roles = &.{},
    .plugins = null,
    .templates = &.{.{ .path = "content/index.publr", .data = "<p>hi</p>" }},
    .assets = &test_files,
    .tokens = .{ .tokens = &.{} },
    .style_css = "",
    .interactive_classes = "",
    .pjsx_components = &.{},
    .pjsx_renders = &.{},
    .middleware = null,
};

test "the fingerprint follows the stylesheet; the build stamp the fingerprint and the address" {
    const one = stamp(&test_spec, "a{}");
    const two = stamp(&test_spec, "b{}");

    try std.testing.expect(!std.mem.eql(u8, &one, &two));
    try std.testing.expectEqualStrings(&one, &stamp(&test_spec, "a{}"));

    const same = build_stamp(&test_spec, &one, "http://a");

    try std.testing.expectEqualStrings(&same, &build_stamp(&test_spec, &one, "http://a"));
    try std.testing.expect(!std.mem.eql(u8, &same, &build_stamp(&test_spec, &two, "http://a")));
    try std.testing.expect(!std.mem.eql(u8, &same, &build_stamp(&test_spec, &one, "http://b")));
}

test "relative imports between scripts carry the fingerprint; other files are untouched" {
    const version: [version_len]u8 = "0123456789abcdef".*;
    const rewritten = try rewrite(std.testing.allocator, &test_files, &version);
    defer free(std.testing.allocator, rewritten);

    try std.testing.expectEqualStrings("import './b.js?v=0123456789abcdef';", rewritten[0].data);
    try std.testing.expectEqualStrings("import './b.js';", rewritten[2].data);

    const imports = try imports_of(std.testing.allocator, rewritten, "a.js");
    defer std.testing.allocator.free(imports);

    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("b.js", imports[0]);
}

fn check_allocation_failure(gpa: std.mem.Allocator) !void {
    const version: [version_len]u8 = "0123456789abcdef".*;
    const rewritten = try rewrite(gpa, &test_files, &version);
    defer free(gpa, rewritten);
}

test "rewriting frees the full allocation after every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_allocation_failure,
        .{},
    );
}
