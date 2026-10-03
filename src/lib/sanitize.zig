//! HTML from anywhere but core's own markup, made safe before it lands on a page: what a
//! plugin's filter answers and what a template prints with `set:html`. An allowlist, the
//! way `wp_kses` works: known harmless tags and attributes are kept, written out again
//! normalised; scripts, styles, frames and embeds go with everything inside them; other
//! tags go and their text stays; `on…` attributes never survive; a link or image address
//! is kept only for `http(s)`, `mailto` or a path on the site. A body may hold inline SVG,
//! kept by its own rules (`sanitize/svg.zig`). What cannot be read cleanly is written out
//! as text. No flag skips it.

const std = @import("std");
const url = @import("sanitize/url.zig");
const svg = @import("sanitize/svg.zig");

pub const Profile = enum {
    /// A short piece inside a line: emphasis, links, code.
    inline_text,
    /// A body: headings, lists, quotes, code blocks, tables, images, inline SVG.
    content,
};

pub const input_bytes_max: u32 = 4 << 20;
pub const depth_max: u32 = 64;

const inline_tags = [_][]const u8{
    "a",  "abbr", "b",    "br",    "cite", "code",   "em",  "i",   "kbd", "mark",
    "p",  "q",    "s",    "small", "span", "strong", "sub", "sup", "u",   "ul",
    "ol", "li",   "time", "del",   "ins",
};

const content_tags = [_][]const u8{
    "h1",      "h2",    "h3",     "h4",         "h5",      "h6",    "blockquote", "pre",
    "hr",      "div",   "figure", "figcaption", "img",     "table", "thead",      "tbody",
    "tfoot",   "tr",    "th",     "td",         "dl",      "dt",    "dd",         "section",
    "article", "aside", "header", "footer",     "caption",
};

/// Gone with everything inside them: what runs, styles, embeds or draws.
const dropped_whole = [_][]const u8{
    "script",   "style",    "iframe", "object", "embed",   "foreignobject", "math",      "template",
    "noscript", "textarea", "title",  "xmp",    "noembed", "noframes",      "select",    "frame",
    "frameset", "applet",   "base",   "link",   "meta",    "head",          "plaintext",
};

const void_tags = [_][]const u8{ "br", "hr", "img" };

const Kept = struct { tag: []const u8, attribute: []const u8 };

/// The attributes a tag keeps; `*` is any kept tag.
const kept_attributes = [_]Kept{
    .{ .tag = "*", .attribute = "class" },
    .{ .tag = "*", .attribute = "title" },
    .{ .tag = "*", .attribute = "lang" },
    .{ .tag = "*", .attribute = "dir" },
    .{ .tag = "a", .attribute = "href" },
    .{ .tag = "a", .attribute = "rel" },
    .{ .tag = "img", .attribute = "src" },
    .{ .tag = "img", .attribute = "alt" },
    .{ .tag = "img", .attribute = "width" },
    .{ .tag = "img", .attribute = "height" },
    .{ .tag = "th", .attribute = "colspan" },
    .{ .tag = "th", .attribute = "rowspan" },
    .{ .tag = "td", .attribute = "colspan" },
    .{ .tag = "td", .attribute = "rowspan" },
    .{ .tag = "ol", .attribute = "start" },
    .{ .tag = "time", .attribute = "datetime" },
};

const Writer = std.Io.Writer;

/// `input` made safe for `profile`.
pub fn sanitize(arena: std.mem.Allocator, input: []const u8, profile: Profile) ![]const u8 {
    std.debug.assert(depth_max > 0);

    if (input.len > input_bytes_max) {
        return error.TooLarge;
    }

    var out: Writer.Allocating = .init(arena);
    var cleaner: Cleaner = .{
        .arena = arena,
        .input = input,
        .profile = profile,
        .out = &out.writer,
    };

    try cleaner.run();

    return out.written();
}

const Cleaner = struct {
    arena: std.mem.Allocator,
    input: []const u8,
    profile: Profile,
    out: *Writer,
    at: u32 = 0,
    open: [depth_max][]const u8 = undefined,
    open_len: u32 = 0,

    fn run(cleaner: *Cleaner) !void {
        std.debug.assert(cleaner.at == 0);

        while (cleaner.at < cleaner.input.len) {
            const char = cleaner.input[cleaner.at];

            if (char == '<') {
                try cleaner.angle();
            } else {
                try text_char(cleaner.out, cleaner.input, &cleaner.at);
            }
        }

        while (cleaner.open_len > 0) {
            cleaner.open_len -= 1;
            try cleaner.out.print("</{s}>", .{cleaner.open[cleaner.open_len]});
        }
    }

    /// At a `<`: a comment or declaration (gone), a tag (kept, dropped or gone whole), or
    /// none of those (the `<` written as text).
    fn angle(cleaner: *Cleaner) !void {
        std.debug.assert(cleaner.input[cleaner.at] == '<');

        const rest = cleaner.input[cleaner.at..];

        if (std.mem.startsWith(u8, rest, "<!--")) {
            const end = std.mem.indexOf(u8, rest[4..], "-->");
            cleaner.at += if (end) |found| @intCast(found + 7) else @intCast(rest.len);
            return;
        }

        if (rest.len > 1 and (rest[1] == '!' or rest[1] == '?')) {
            const end = std.mem.indexOfScalar(u8, rest, '>') orelse rest.len - 1;
            cleaner.at += @intCast(end + 1);
            return;
        }

        const found = parse_tag(rest) orelse {
            try cleaner.out.writeAll("&lt;");
            cleaner.at += 1;
            return;
        };

        cleaner.at += found.length;
        try cleaner.element(rest, found);
    }

    fn element(cleaner: *Cleaner, rest: []const u8, found: Tag) !void {
        std.debug.assert(found.length <= rest.len);

        var name_buffer: [32]u8 = undefined;
        const name = std.ascii.lowerString(&name_buffer, found.name);
        const drawing = cleaner.in_drawing();
        const svg_title = drawing and std.mem.eql(u8, name, "title");
        const whole = listed(&dropped_whole, name) and !svg_title;
        const svg_here = std.mem.eql(u8, name, "svg") and cleaner.profile == .inline_text;

        if (!found.closing and (whole or svg_here)) {
            cleaner.skip_whole(name);
            return;
        }

        if (!cleaner.allowed(name, drawing)) {
            return;
        }

        const kept = (try cleaner.arena.dupe(u8, name));

        if (found.closing) {
            return cleaner.close(kept);
        }

        const attributes_text = rest[found.attributes_start..found.attributes_end];

        try cleaner.out.print("<{s}", .{kept});

        if (drawing or std.mem.eql(u8, kept, "svg")) {
            try cleaner.drawing_attributes(kept, attributes_text);
        } else {
            try cleaner.attributes(kept, attributes_text);
        }

        if (listed(&void_tags, kept) and !drawing) {
            try cleaner.out.writeAll(">");
            return;
        }

        if (drawing and self_closing(attributes_text)) {
            try cleaner.out.writeAll("/>");
            return;
        }

        try cleaner.out.writeAll(">");

        if (cleaner.open_len == depth_max) {
            return cleaner.out.print("</{s}>", .{kept});
        }

        cleaner.open[cleaner.open_len] = kept;
        cleaner.open_len += 1;
    }

    /// A closing tag closes the innermost open one of its name and any opened inside it;
    /// one with nothing open of its name is dropped.
    fn close(cleaner: *Cleaner, name: []const u8) !void {
        std.debug.assert(name.len > 0);

        var depth = cleaner.open_len;

        while (depth > 0) : (depth -= 1) {
            if (std.mem.eql(u8, cleaner.open[depth - 1], name)) {
                while (cleaner.open_len > depth - 1) {
                    cleaner.open_len -= 1;
                    try cleaner.out.print("</{s}>", .{cleaner.open[cleaner.open_len]});
                }

                return;
            }
        }
    }

    /// Past `</name>` of an element dropped whole, or to the end.
    fn skip_whole(cleaner: *Cleaner, name: []const u8) void {
        std.debug.assert(name.len > 0);

        const rest = cleaner.input[cleaner.at..];
        var index: u32 = 0;

        while (index + 2 + name.len <= rest.len) : (index += 1) {
            const here = rest[index..];

            const closes = here[0] == '<' and here[1] == '/';

            if (closes and std.ascii.startsWithIgnoreCase(here[2..], name)) {
                const end = std.mem.indexOfScalar(u8, here, '>') orelse here.len - 1;
                cleaner.at += index + @as(u32, @intCast(end + 1));
                return;
            }
        }

        cleaner.at = @intCast(cleaner.input.len);
    }

    /// Inside a drawing only the drawing's own elements: one of the page's would end the
    /// drawing in a browser and be read by other rules than these.
    fn allowed(cleaner: *const Cleaner, name: []const u8, drawing: bool) bool {
        std.debug.assert(name.len > 0);

        if (drawing) {
            return svg.element(name);
        }

        if (listed(&inline_tags, name)) {
            return true;
        }

        const body = listed(&content_tags, name) or std.mem.eql(u8, name, "svg");

        return cleaner.profile == .content and body;
    }

    /// Whether an `<svg>` is open: what comes next is part of a drawing.
    fn in_drawing(cleaner: *const Cleaner) bool {
        std.debug.assert(cleaner.open_len <= depth_max);

        for (cleaner.open[0..cleaner.open_len]) |name| {
            if (std.mem.eql(u8, name, "svg")) {
                return true;
            }
        }

        return false;
    }

    fn drawing_attributes(cleaner: *Cleaner, tag_name: []const u8, text: []const u8) !void {
        std.debug.assert(tag_name.len > 0);

        var reader: AttributeReader = .{ .text = text };

        while (reader.next()) |attribute| {
            var name_buffer: [32]u8 = undefined;

            if (attribute.name.len == 0 or attribute.name.len > name_buffer.len) {
                continue;
            }

            const name = std.ascii.lowerString(&name_buffer, attribute.name);
            const decoded = try url.decode(cleaner.arena, attribute.value);
            const value = try svg.attribute(cleaner.arena, tag_name, name, decoded) orelse {
                continue;
            };

            try cleaner.out.print(" {s}=\"", .{name});
            try write_escaped(cleaner.out, value);
            try cleaner.out.writeAll("\"");
        }
    }

    fn attributes(cleaner: *Cleaner, tag_name: []const u8, text: []const u8) !void {
        std.debug.assert(tag_name.len > 0);

        var reader: AttributeReader = .{ .text = text };
        var kept_rel = false;

        while (reader.next()) |attribute| {
            var name_buffer: [32]u8 = undefined;

            if (attribute.name.len > name_buffer.len) {
                continue;
            }

            const name = std.ascii.lowerString(&name_buffer, attribute.name);

            if (!kept_attribute(tag_name, name)) {
                continue;
            }

            const value = try url.decode(cleaner.arena, attribute.value);
            const is_address = std.mem.eql(u8, name, "href") or std.mem.eql(u8, name, "src");

            if (is_address and !url.safe(value)) {
                continue;
            }

            kept_rel = kept_rel or std.mem.eql(u8, name, "rel");
            try cleaner.out.print(" {s}=\"", .{name});
            try write_escaped(cleaner.out, value);
            try cleaner.out.writeAll("\"");
        }

        if (std.mem.eql(u8, tag_name, "a") and !kept_rel) {
            try cleaner.out.writeAll(" rel=\"nofollow noopener\"");
        }
    }
};

/// `<path d="…"/>`: the tag's attributes end with a `/`.
fn self_closing(attributes_text: []const u8) bool {
    std.debug.assert(attributes_text.len <= input_bytes_max);

    const trimmed = std.mem.trimEnd(u8, attributes_text, " \t\r\n");

    return trimmed.len > 0 and trimmed[trimmed.len - 1] == '/';
}

const Tag = struct {
    name: []const u8,
    closing: bool,
    attributes_start: u32,
    attributes_end: u32,
    /// From the `<` to past the `>`.
    length: u32,
};

/// A tag at the start of `text`, or null when it is not one: `<`, an optional `/`, a name
/// of letters and digits starting with a letter, attributes with their quotes closed, `>`.
fn parse_tag(text: []const u8) ?Tag {
    std.debug.assert(text.len > 0 and text[0] == '<');

    var index: u32 = 1;
    const closing = index < text.len and text[index] == '/';

    if (closing) {
        index += 1;
    }

    const name_start = index;

    while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '-')) {
        index += 1;
    }

    const name_length = index - name_start;

    if (name_length == 0 or name_length > 32 or !std.ascii.isAlphabetic(text[name_start])) {
        return null;
    }

    const attributes_start = index;
    var quote: u8 = 0;

    while (index < text.len) : (index += 1) {
        const char = text[index];

        if (quote != 0) {
            if (char == quote) quote = 0;
        } else if (char == '"' or char == '\'') {
            quote = char;
        } else if (char == '>') {
            return .{
                .name = text[name_start..attributes_start],
                .closing = closing,
                .attributes_start = attributes_start,
                .attributes_end = index,
                .length = index + 1,
            };
        } else if (char == '<') {
            return null;
        }
    }

    return null;
}

const Attribute = struct { name: []const u8, value: []const u8 };

/// `name`, `name=value`, `name="value"`, `name='value'`, separated by space or `/`.
const AttributeReader = struct {
    text: []const u8,
    at: u32 = 0,

    fn next(reader: *AttributeReader) ?Attribute {
        std.debug.assert(reader.at <= reader.text.len);

        const text = reader.text;

        while (reader.at < text.len and separator(text[reader.at])) {
            reader.at += 1;
        }

        if (reader.at >= text.len) {
            return null;
        }

        const name_start = reader.at;

        while (reader.at < text.len and !separator(text[reader.at]) and text[reader.at] != '=') {
            reader.at += 1;
        }

        const name = text[name_start..reader.at];

        if (reader.at >= text.len or text[reader.at] != '=') {
            return .{ .name = name, .value = "" };
        }

        reader.at += 1;

        return .{ .name = name, .value = reader.value() };
    }

    fn value(reader: *AttributeReader) []const u8 {
        std.debug.assert(reader.at <= reader.text.len);

        const text = reader.text;

        if (reader.at < text.len and (text[reader.at] == '"' or text[reader.at] == '\'')) {
            const quote = text[reader.at];
            const start = reader.at + 1;
            const end = std.mem.indexOfScalarPos(u8, text, start, quote) orelse text.len;

            reader.at = @intCast(@min(end + 1, text.len));
            return text[start..end];
        }

        const start = reader.at;

        while (reader.at < text.len and !std.ascii.isWhitespace(text[reader.at])) {
            reader.at += 1;
        }

        return text[start..reader.at];
    }
};

/// A character of text: `<`, `>` and `"` escaped; `&` kept only when it starts an entity.
fn text_char(out: *Writer, input: []const u8, at: *u32) !void {
    std.debug.assert(at.* < input.len);

    const char = input[at.*];

    at.* += 1;

    switch (char) {
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        '&' => {
            const entity = url.entity_length(input[at.* - 1 ..]) > 0;

            try out.writeAll(if (entity) "&" else "&amp;");
        },
        else => try out.writeByte(char),
    }
}

fn separator(char: u8) bool {
    return std.ascii.isWhitespace(char) or char == '/';
}

fn write_escaped(out: *Writer, value: []const u8) !void {
    std.debug.assert(value.len <= input_bytes_max);

    for (value) |char| {
        switch (char) {
            '&' => try out.writeAll("&amp;"),
            '"' => try out.writeAll("&quot;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            else => try out.writeByte(char),
        }
    }
}

fn kept_attribute(tag_name: []const u8, name: []const u8) bool {
    std.debug.assert(tag_name.len > 0);

    for (kept_attributes) |kept| {
        const tag_fits = std.mem.eql(u8, kept.tag, "*") or std.mem.eql(u8, kept.tag, tag_name);

        if (tag_fits and std.mem.eql(u8, kept.attribute, name)) {
            return true;
        }
    }

    return false;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

test {
    _ = @import("sanitize/tests.zig");
}
