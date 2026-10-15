//! A Markdown page read into the `.publr` source it stands for: the frontmatter's `layout`
//! imported and called with the other keys as props, the Markdown's HTML as its slot. From
//! there it is compiled like any page. Braces in it are text, never expressions. Pure.

const std = @import("std");
const markdown = @import("../lib/markdown.zig");

pub const keys_max: u32 = 64;
const key_len_max: u32 = 64;

pub const Result = union(enum) {
    source: []const u8,
    /// Why the page is refused, naming the line or the name.
    refused: []const u8,
};

const Prop = struct {
    key: []const u8,
    value: []const u8,
};

const Frontmatter = struct {
    layout: ?[]const u8 = null,
    props: []const Prop = &.{},
    body: []const u8,
};

pub fn translate(arena: std.mem.Allocator, rel: []const u8, text: []const u8) !Result {
    std.debug.assert(std.mem.endsWith(u8, rel, ".md"));

    if (refused_name(rel)) |reason| {
        return .{
            .refused = reason,
        };
    }

    var reason: []const u8 = "";
    const frontmatter = try read_frontmatter(arena, text, &reason) orelse return .{
        .refused = reason,
    };
    const html = markdown.to_html(arena, frontmatter.body, .{
        .braces_as_text = true,
    }) catch |err| switch (err) {
        error.TooLong => return .{
            .refused = "longer than a page may be",
        },
        else => |other| return other,
    };

    return .{
        .source = try source_of(arena, frontmatter, html),
    };
}

/// The layout a Markdown page names, for what follows imports before pages are compiled;
/// null when it names none or its frontmatter is refused (compiling it says why).
pub fn layout_of(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var reason: []const u8 = "";
    const frontmatter = try read_frontmatter(arena, text, &reason) orelse return null;

    std.debug.assert(frontmatter.body.len <= text.len);

    return frontmatter.layout;
}

fn refused_name(rel: []const u8) ?[]const u8 {
    std.debug.assert(rel.len > 0);

    if (std.mem.endsWith(u8, rel, ".dynamic.md")) {
        return "a Markdown page is static; .dynamic.md is not a name it can have";
    }

    if (std.mem.indexOfScalar(u8, rel, '[') != null) {
        return "a Markdown page has no record to fill [slug] or [...path]; " ++
            "name it for its address";
    }

    return null;
}

fn read_frontmatter(arena: std.mem.Allocator, text: []const u8, reason: *[]const u8) !?Frontmatter {
    const opened = std.mem.startsWith(u8, text, "---\n") or std.mem.startsWith(u8, text, "---\r\n");

    if (!opened) {
        return .{
            .body = text,
        };
    }

    const start = std.mem.indexOfScalar(u8, text, '\n').? + 1;
    var lines = std.mem.splitScalar(u8, text[start..], '\n');
    var props: std.ArrayList(Prop) = .empty;
    var layout: ?[]const u8 = null;
    var consumed: u32 = @intCast(start);

    while (lines.next()) |raw| {
        consumed += @intCast(raw.len + 1);

        const line = std.mem.trim(u8, raw, " \t\r");

        if (std.mem.eql(u8, line, "---")) {
            return .{
                .layout = layout,
                .props = props.items,
                .body = text[@min(consumed, text.len)..],
            };
        }

        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        const prop = read_line(line) orelse {
            reason.* = try std.fmt.allocPrint(
                arena,
                "frontmatter holds `key: value` lines only; not `{s}`",
                .{line},
            );
            return null;
        };

        const is_layout = std.mem.eql(u8, prop.key, "layout");

        if (is_layout and !is_layout_path(prop.value)) {
            reason.* = "layout names a .publr file by its relative path, " ++
                "as `layout: ../layouts/base.publr`";
            return null;
        }

        if (is_layout) {
            layout = prop.value;
        } else if (props.items.len == keys_max) {
            reason.* = "frontmatter has more keys than a page may pass to its layout";
            return null;
        } else {
            try props.append(arena, prop);
        }
    }

    std.debug.assert(consumed >= start);

    reason.* = "frontmatter opened with --- is never closed";
    return null;
}

/// `key: value`, the value plain or in matching quotes; null when the line is not one.
fn read_line(line: []const u8) ?Prop {
    std.debug.assert(line.len > 0);

    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trimEnd(u8, line[0..colon], " \t");
    var value = std.mem.trim(u8, line[colon + 1 ..], " \t");

    if (key.len == 0 or key.len > key_len_max or !is_name(key)) {
        return null;
    }

    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) {
        if (value[value.len - 1] != value[0]) {
            return null;
        }

        value = value[1 .. value.len - 1];
    } else if (value.len > 0 and std.mem.indexOfScalar(u8, "[{|>&*!", value[0]) != null) {
        return null;
    }

    return .{
        .key = key,
        .value = value,
    };
}

fn is_layout_path(path: []const u8) bool {
    const relative = std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../");

    return relative and std.mem.endsWith(u8, path, ".publr") and
        std.mem.indexOfAny(u8, path, "'\\ ") == null;
}

fn is_name(key: []const u8) bool {
    std.debug.assert(key.len > 0);

    if (!std.ascii.isLower(key[0]) and key[0] != '_') {
        return false;
    }

    for (key) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '_') {
            return false;
        }
    }

    return true;
}

fn source_of(arena: std.mem.Allocator, frontmatter: Frontmatter, html: []const u8) ![]const u8 {
    const layout = frontmatter.layout orelse {
        std.debug.assert(frontmatter.props.len <= keys_max);
        return html;
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;

    try writer.writeAll("---\nimport Layout from '");
    try writer.writeAll(layout);
    try writer.writeAll("';\n---\n<Layout");

    for (frontmatter.props) |prop| {
        try writer.print(" {s}={{", .{prop.key});
        try std.json.Stringify.value(prop.value, .{}, writer);
        try writer.writeAll("}");
    }

    try writer.writeAll(">\n");
    try writer.writeAll(html);
    try writer.writeAll("</Layout>\n");

    std.debug.assert(out.written().len > html.len);

    return out.written();
}

test "a page with a layout passes the other keys as props and its HTML as the slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try translate(arena_state.allocator(), "content/guide/install.md",
        \\---
        \\layout: ../../layouts/base.publr
        \\title: "Installing: the {quick} way"
        \\# a comment
        \\description: It's "easy"
        \\---
        \\# Install {now}
        \\
    );

    try std.testing.expectEqualStrings(
        "---\nimport Layout from '../../layouts/base.publr';\n---\n" ++
            "<Layout title={\"Installing: the {quick} way\"} " ++
            "description={\"It's \\\"easy\\\"\"}>\n" ++
            "<h1>Install &#123;now&#125;</h1>\n</Layout>\n",
        result.source,
    );
}

test "layout_of names the layout, or none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const named = try layout_of(arena, "---\nlayout: ../../shared/base.publr\n---\n# x");
    try std.testing.expectEqualStrings("../../shared/base.publr", named.?);
    try std.testing.expect(try layout_of(arena, "# x") == null);
    try std.testing.expect(try layout_of(arena, "---\nlayout: [x]\n---\n") == null);
}

test "a page without frontmatter or layout is its HTML alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare = try translate(arena, "content/a.md", "Hello *you*");
    try std.testing.expectEqualStrings("<p>Hello <em>you</em></p>\n", bare.source);

    const unlaid = try translate(arena, "content/b.md", "---\ntitle: B\n---\nText");
    try std.testing.expectEqualStrings("<p>Text</p>\n", unlaid.source);
}

test "refused: route parameters, dynamic names, frontmatter that is not key: value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refusals = [_][2][]const u8{
        .{ "content/[slug].md", "# x" },
        .{ "content/docs/[...path].md", "# x" },
        .{ "content/fresh.dynamic.md", "# x" },
        .{ "content/a.md", "---\ntitle: a\n" },
        .{ "content/a.md", "---\ntags:\n  - a\n---\n" },
        .{ "content/a.md", "---\ntags: [a, b]\n---\n" },
        .{ "content/a.md", "---\nTitle: a\n---\n" },
        .{ "content/a.md", "---\ntitle: \"a\n---\n" },
        .{ "content/a.md", "---\nlayout: base\n---\n" },
        .{ "content/a.md", "---\nlayout: ../it's.publr\n---\n" },
    };

    for (refusals) |refusal| {
        const result = try translate(arena, refusal[0], refusal[1]);
        try std.testing.expect(result == .refused);
        try std.testing.expect(result.refused.len > 0);
    }
}
