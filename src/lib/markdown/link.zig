//! Links and the pieces of text that look like markup: a link's `(href "title")`, an
//! autolink's address, an inline tag; and how a link or an image is written.

const std = @import("std");
const escape = @import("escape.zig");

const Writer = std.Io.Writer;

/// How deep parentheses may nest inside a link's address before it is no address.
const parens_depth_max: u32 = 32;
const scheme_len_max: u32 = 32;

pub const Target = struct {
    href: []const u8,
    title: []const u8,
    /// Just past the closing `)`.
    end: u32,
};

/// The last search for a character, kept so the searches of one text, which mostly move
/// forward, look at each character about once.
const Search = struct {
    from: u32 = 0,
    found: ?u32 = null,
    valid: bool = false,

    fn next(search: *Search, input: []const u8, from: u32, set: []const u8) ?u32 {
        std.debug.assert(from <= input.len);
        std.debug.assert(set.len > 0);

        const reusable = search.valid and from >= search.from and
            (search.found == null or from <= search.found.?);

        if (!reusable) {
            const found = std.mem.indexOfAnyPos(u8, input, from, set);
            search.* = .{
                .from = from,
                .found = if (found) |at| @intCast(at) else null,
                .valid = true,
            };
        }

        return search.found;
    }
};

pub const Memo = struct {
    stop: Search = .{},
    double: Search = .{},
    single: Search = .{},
    paren: Search = .{},
};

/// `(href "title")` at `at`, the text after a link's `]`; null when it is not one.
pub fn destination(memo: *Memo, input: []const u8, at: u32) ?Target {
    std.debug.assert(at <= input.len);

    if (at == input.len or input[at] != '(') {
        return null;
    }

    var index = skip_space(input, at + 1);
    const href_end = href_end_of(memo, input, index) orelse return null;
    const angled = index < input.len and input[index] == '<';
    const href = if (angled) input[index + 1 .. href_end - 1] else input[index..href_end];

    index = skip_space(input, href_end);

    var title: []const u8 = "";

    const titled = index < input.len and index > href_end and
        std.mem.indexOfScalar(u8, "\"'(", input[index]) != null;

    if (titled) {
        const close = title_end_of(memo, input, index) orelse return null;
        title = input[index + 1 .. close];
        index = skip_space(input, close + 1);
    }

    if (index == input.len or input[index] != ')') {
        return null;
    }

    std.debug.assert(index >= href_end);

    return .{
        .href = href,
        .title = title,
        .end = index + 1,
    };
}

fn skip_space(input: []const u8, from: u32) u32 {
    std.debug.assert(from <= input.len);

    var index = from;

    while (index < input.len and (input[index] == ' ' or input[index] == '\n')) {
        index += 1;
    }

    return index;
}

/// Where an address ends: after `<…>`, or at a space or the `)` closing the parentheses it
/// opened.
fn href_end_of(memo: *Memo, input: []const u8, start: u32) ?u32 {
    std.debug.assert(start <= input.len);

    if (start < input.len and input[start] == '<') {
        const close = std.mem.indexOfAnyPos(u8, input, start + 1, "<>\n") orelse return null;

        return if (input[close] == '>') @intCast(close + 1) else null;
    }

    var depth: u32 = 0;
    var index = start;

    while (memo.stop.next(input, index, " \n()")) |stop| {
        if (input[stop] == '(') {
            depth += 1;

            if (depth > parens_depth_max) {
                return null;
            }

            index = stop + 1;
            continue;
        }

        if (input[stop] == ')' and depth > 0) {
            depth -= 1;
            index = stop + 1;
            continue;
        }

        return stop;
    }

    std.debug.assert(index <= input.len);

    return null;
}

fn title_end_of(memo: *Memo, input: []const u8, open: u32) ?u32 {
    std.debug.assert(open < input.len);

    return switch (input[open]) {
        '"' => memo.double.next(input, open + 1, "\""),
        '\'' => memo.single.next(input, open + 1, "'"),
        '(' => memo.paren.next(input, open + 1, ")"),
        else => unreachable,
    };
}

/// The address of `<https://…>` or `<name@host>`, by what is between the brackets.
pub fn autolink(inside: []const u8) ?[]const u8 {
    if (inside.len == 0 or std.mem.indexOfAny(u8, inside, " \t<") != null) {
        return null;
    }

    if (std.mem.indexOfScalar(u8, inside, ':')) |colon| {
        const scheme = inside[0..colon];
        const named = scheme.len >= 2 and scheme.len <= scheme_len_max and
            std.ascii.isAlphabetic(scheme[0]);

        for (scheme) |char| {
            const allowed = std.ascii.isAlphanumeric(char) or
                std.mem.indexOfScalar(u8, "+.-", char) != null;

            if (!allowed) {
                return null;
            }
        }

        return if (named) inside else null;
    }

    const at = std.mem.indexOfScalar(u8, inside, '@') orelse return null;
    const host = inside[at + 1 ..];

    std.debug.assert(at < inside.len);

    if (at == 0 or host.len == 0 or std.mem.indexOfScalar(u8, host, '.') == null) {
        return null;
    }

    return inside;
}

/// What is between `<` and `>` reads as a tag: `<name …>`, `</name>`, or `<!-- … --`.
pub fn is_tag(inside: []const u8) bool {
    if (inside.len == 0) {
        return false;
    }

    if (std.mem.startsWith(u8, inside, "!--")) {
        return std.mem.endsWith(u8, inside, "--");
    }

    const name = if (inside[0] == '/') inside[1..] else inside;

    std.debug.assert(name.len <= inside.len);

    return name.len > 0 and std.ascii.isAlphabetic(name[0]);
}

pub fn write_open(
    writer: *Writer,
    href: []const u8,
    title: []const u8,
    options: escape.Options,
) !void {
    std.debug.assert(href.len <= std.math.maxInt(u32));

    try writer.writeAll("<a href=\"");
    try escape.text(writer, href, options);

    if (title.len > 0) {
        try writer.writeAll("\" title=\"");
        try escape.text(writer, title, options);
    }

    try writer.writeAll("\">");
}

/// An autolink: an address with a scheme as it is, an email address as `mailto:`.
pub fn write_autolink(writer: *Writer, address: []const u8, options: escape.Options) !void {
    std.debug.assert(address.len > 0);

    const email = std.mem.indexOfScalar(u8, address, ':') == null;

    try writer.writeAll(if (email) "<a href=\"mailto:" else "<a href=\"");
    try escape.text(writer, address, options);
    try writer.writeAll("\">");
    try escape.text(writer, address, options);
    try writer.writeAll("</a>");
}

pub const Image = struct {
    src: []const u8,
    alt: []const u8,
    title: []const u8,
};

pub fn write_image(writer: *Writer, image: Image, options: escape.Options) !void {
    std.debug.assert(image.src.len <= std.math.maxInt(u32));

    try writer.writeAll("<img src=\"");
    try escape.text(writer, image.src, options);
    try writer.writeAll("\" alt=\"");
    try escape.text(writer, image.alt, options);

    if (image.title.len > 0) {
        try writer.writeAll("\" title=\"");
        try escape.text(writer, image.title, options);
    }

    try writer.writeAll("\" />");
}

test "destination reads the address, an optional title, and nested parentheses" {
    var memo: Memo = .{};
    const plain = destination(&memo, "(/docs/a)", 0).?;

    try std.testing.expectEqualStrings("/docs/a", plain.href);
    try std.testing.expectEqual(@as(u32, 9), plain.end);

    memo = .{};
    const titled = destination(&memo, "x(https://a.b/c_(d) \"The title\") y", 1).?;

    try std.testing.expectEqualStrings("https://a.b/c_(d)", titled.href);
    try std.testing.expectEqualStrings("The title", titled.title);

    memo = .{};
    const angled = destination(&memo, "(<a b.png> 'T')", 0).?;

    try std.testing.expectEqualStrings("a b.png", angled.href);
    try std.testing.expectEqualStrings("T", angled.title);

    const refused = [_][]const u8{ "(a b)", "(a", "x", "(a \"t)", "(", "(<a)" };

    for (refused) |input| {
        memo = .{};
        try std.testing.expect(destination(&memo, input, 0) == null);
    }
}

test "autolinks need a scheme or an email address; tags need a name" {
    try std.testing.expectEqualStrings("https://x.y", autolink("https://x.y").?);
    try std.testing.expectEqualStrings("me@x.y", autolink("me@x.y").?);
    try std.testing.expect(autolink("a b:c") == null);
    try std.testing.expect(autolink("x:y") == null);
    try std.testing.expect(autolink("me@host") == null);
    try std.testing.expect(autolink("") == null);
    try std.testing.expect(is_tag("span class=\"x\""));
    try std.testing.expect(is_tag("/span"));
    try std.testing.expect(is_tag("!-- note --"));
    try std.testing.expect(!is_tag(" b "));
    try std.testing.expect(!is_tag("3"));
    try std.testing.expect(!is_tag("/"));
}
