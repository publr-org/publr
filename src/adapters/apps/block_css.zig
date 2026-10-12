//! The classes a page carries that its stylesheet does not style: what the block editor's
//! blocks write into a record, and what a template override holds. The app's sheet is made
//! from its templates when it loads, so it never sees them; each page gets their rules here,
//! compiled with the app's tokens, in a `<style>` at the end of its head. Classes the
//! templates name are written as their short names, which no utility matches.
const std = @import("std");
const jit = @import("publr_jit");
const state = @import("state.zig");
const spec_module = @import("spec.zig");

const App = state.App;

/// More than this many distinct classes on one page and the rest go unstyled: a bound, far
/// above what a designed page carries.
const classes_max: u32 = 2048;
const class_bytes_max: u32 = 256;
const attribute = " class=\"";
const head_end = "</head>";

/// `html` with the rules its blocks' classes need, or as it is when they need none.
pub fn apply(arena: std.mem.Allocator, app: *const App, html: []const u8) ![]const u8 {
    std.debug.assert(app.spec.name.len > 0);

    const head = std.mem.indexOf(u8, html, head_end) orelse return html;
    const classes = try collect(arena, html[head..]);

    if (classes.len == 0) {
        return html;
    }

    const css = jit.compile(arena, app.spec.tokens, classes, .{
        .minify = spec_module.minify,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return html,
    };

    // The output is always a utilities layer; a rule inside it is a second brace.
    if (std.mem.count(u8, css, "{") < 2) {
        return html;
    }

    std.debug.assert(head < html.len);

    return std.mem.concat(arena, u8, &.{
        html[0..head],
        "<style data-publr-blocks>",
        css,
        "</style>",
        html[head..],
    });
}

/// Every distinct class in the body's `class` attributes, in the order met.
fn collect(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    std.debug.assert(std.mem.startsWith(u8, body, head_end));

    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var rest = body;

    while (std.mem.indexOf(u8, rest, attribute)) |at| {
        const start = at + attribute.len;
        const end = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse break;
        var tokens = std.mem.tokenizeAny(u8, rest[start..end], " \t\r\n");

        while (tokens.next()) |written| {
            if (seen.count() >= classes_max) {
                break;
            }

            if (written.len <= class_bytes_max) {
                try seen.put(arena, try unescaped(arena, written), {});
            }
        }

        rest = rest[end..];
    }

    std.debug.assert(seen.count() <= classes_max);

    return seen.keys();
}

/// A class as the browser reads it: the markup writes `[&_em]:not-italic` as
/// `[&amp;_em]:not-italic`.
fn unescaped(arena: std.mem.Allocator, written: []const u8) ![]const u8 {
    std.debug.assert(written.len <= class_bytes_max);

    if (std.mem.indexOfScalar(u8, written, '&') == null) {
        return written;
    }

    var out: std.ArrayList(u8) = .empty;
    var rest = written;
    const entities = [_][2][]const u8{
        .{ "&amp;", "&" },
        .{ "&quot;", "\"" },
        .{ "&#39;", "'" },
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
    };

    outer: while (rest.len > 0) {
        for (entities) |entity| {
            if (std.mem.startsWith(u8, rest, entity[0])) {
                try out.appendSlice(arena, entity[1]);
                rest = rest[entity[0].len..];
                continue :outer;
            }
        }

        try out.append(arena, rest[0]);
        rest = rest[1..];
    }

    std.debug.assert(out.items.len <= written.len);

    return out.items;
}

test "a class only a record names gets its rule; a short name does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try collect(arena, "</head><body class=\"Q bH\"><h2 class=\"text-7xl  p-4\">" ++
        "</h2><p class=\"p-4 [&amp;_em]:not-italic\"></p></body>");

    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expectEqualStrings("[&_em]:not-italic", found[4]);
    try std.testing.expectEqualStrings("text-7xl", found[2]);

    const css = try jit.compile(arena, jit.default_theme, found, .{});

    try std.testing.expect(std.mem.indexOf(u8, css, ".text-7xl") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bH") == null);
}
