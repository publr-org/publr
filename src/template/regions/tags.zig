//! The tags of an HTML string, read one by one: a start or end tag's name, where it sits,
//! its attributes as text, whether it closes itself. Comments and declarations are
//! skipped, and so is the text of a raw text element (script, style, textarea, title).
//! Pure.

const std = @import("std");

pub const Range = struct {
    start: u32,
    end: u32,

    pub fn of(range: Range, html: []const u8) []const u8 {
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= html.len);

        return html[range.start..range.end];
    }
};

pub const Kind = enum { start, end };

pub const Tag = struct {
    kind: Kind,
    name: []const u8,
    start: u32,
    end: u32,
    /// The text between the name and the closing `>`.
    attributes: Range,
    self_closing: bool,
};

const void_tags = [_][]const u8{
    "area",  "base", "br",   "col",   "embed",  "hr",    "img",
    "input", "link", "meta", "param", "source", "track", "wbr",
};

const raw_tags = [_][]const u8{ "script", "style", "textarea", "title" };

/// Whether an element of this name never has an inside.
pub fn is_void(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    return listed(&void_tags, name);
}

/// The tags of `html` between `at` and `end`, in order; a raw text element's text is
/// skipped, comments and declarations too.
pub const Scanner = struct {
    html: []const u8,
    at: u32,
    end: u32,

    pub fn next(scanner: *Scanner) ?Tag {
        std.debug.assert(scanner.end <= scanner.html.len);

        const html = scanner.html[0..scanner.end];

        while (scanner.at < scanner.end) {
            const found = std.mem.indexOfScalarPos(u8, html, scanner.at, '<');
            const opening: u32 = @intCast(found orelse return null);

            scanner.at = opening + 1;

            if (scanner.read_tag(opening)) |tag| {
                std.debug.assert(tag.end > tag.start);

                return tag;
            }
        }

        return null;
    }

    /// The tag at `opening`, or null after skipping what is not one.
    fn read_tag(scanner: *Scanner, opening: u32) ?Tag {
        std.debug.assert(scanner.html[opening] == '<');

        const html = scanner.html[0..scanner.end];
        const rest = html[opening..];

        if (std.mem.startsWith(u8, rest, "<!--")) {
            const close = std.mem.indexOfPos(u8, html, opening + 4, "-->");

            scanner.at = if (close) |found| @intCast(found + 3) else scanner.end;

            return null;
        }

        if (rest.len < 2) {
            return null;
        }

        if (rest[1] == '!' or rest[1] == '?') {
            const close = std.mem.indexOfScalarPos(u8, html, opening, '>');

            scanner.at = if (close) |found| @intCast(found + 1) else scanner.end;

            return null;
        }

        const closing = rest[1] == '/';
        const name_start: u32 = opening + 1 + @intFromBool(closing);

        if (name_start >= html.len or !std.ascii.isAlphabetic(html[name_start])) {
            return null;
        }

        return scanner.finish_tag(opening, name_start, if (closing) .end else .start);
    }

    fn finish_tag(scanner: *Scanner, opening: u32, name_start: u32, kind: Kind) ?Tag {
        std.debug.assert(name_start > opening);

        const html = scanner.html[0..scanner.end];
        var name_end = name_start;

        while (name_end < html.len and !name_stops(html[name_end])) {
            name_end += 1;
        }

        const closing_at = close_of(html, name_end) orelse {
            scanner.at = scanner.end;

            return null;
        };
        const self_closing = closing_at > name_end and html[closing_at - 1] == '/';
        const tag: Tag = .{
            .kind = kind,
            .name = html[name_start..name_end],
            .start = opening,
            .end = closing_at + 1,
            .attributes = .{
                .start = name_end,
                .end = closing_at,
            },
            .self_closing = self_closing,
        };

        scanner.at = closing_at + 1;

        if (kind == .start and !self_closing and listed(&raw_tags, tag.name)) {
            scanner.at = raw_end(html, scanner.at, tag.name);
        }

        std.debug.assert(scanner.at <= scanner.end);

        return tag;
    }
};

fn name_stops(char: u8) bool {
    return std.ascii.isWhitespace(char) or char == '>' or char == '/';
}

/// The `>` that ends a tag, quoted values stepped over.
fn close_of(html: []const u8, from: u32) ?u32 {
    std.debug.assert(from <= html.len);

    var at = from;
    var quote: u8 = 0;

    while (at < html.len) : (at += 1) {
        const char = html[at];

        if (quote != 0) {
            if (char == quote) {
                quote = 0;
            }
        } else if (char == '"' or char == '\'') {
            quote = char;
        } else if (char == '>') {
            return at;
        }
    }

    std.debug.assert(at == html.len);

    return null;
}

/// Where a raw text element's end tag starts: its own name, any case; the end when none.
fn raw_end(html: []const u8, from: u32, name: []const u8) u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(from <= html.len);

    var at = from;

    while (std.mem.indexOfPos(u8, html, at, "</")) |found| {
        const after = found + 2;

        if (after + name.len <= html.len and
            std.ascii.eqlIgnoreCase(html[after .. after + name.len], name))
        {
            return @intCast(found);
        }

        at = @intCast(after);
    }

    return @intCast(html.len);
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len > 0);

    for (names) |known| {
        if (std.ascii.eqlIgnoreCase(known, name)) {
            return true;
        }
    }

    return false;
}

/// An attribute's value in a tag: empty for one without a value, null when it is not there.
pub fn attribute_of(html: []const u8, tag: Tag, wanted: []const u8) ?[]const u8 {
    std.debug.assert(wanted.len > 0);
    std.debug.assert(tag.attributes.end <= html.len);

    const text = tag.attributes.of(html);
    var at: u32 = 0;

    while (at < text.len) {
        while (at < text.len and (std.ascii.isWhitespace(text[at]) or text[at] == '/')) {
            at += 1;
        }

        const name_start = at;

        while (at < text.len and !std.ascii.isWhitespace(text[at]) and text[at] != '=' and
            text[at] != '/')
        {
            at += 1;
        }

        const name = text[name_start..at];
        const value = value_at(text, &at);

        if (name.len > 0 and std.ascii.eqlIgnoreCase(name, wanted)) {
            return value;
        }

        if (name.len == 0 and value.len == 0) {
            at += 1;
        }
    }

    return null;
}

/// After an attribute's name: `="…"`, `='…'` or `=bare`, read past; empty without one.
fn value_at(text: []const u8, at: *u32) []const u8 {
    std.debug.assert(at.* <= text.len);

    if (at.* >= text.len or text[at.*] != '=') {
        return "";
    }

    at.* += 1;

    if (at.* < text.len and (text[at.*] == '"' or text[at.*] == '\'')) {
        const quote = text[at.*];
        const start = at.* + 1;
        const close = std.mem.indexOfScalarPos(u8, text, start, quote) orelse text.len;

        at.* = @intCast(@min(close + 1, text.len));

        return text[start..close];
    }

    const start = at.*;

    while (at.* < text.len and !std.ascii.isWhitespace(text[at.*])) {
        at.* += 1;
    }

    std.debug.assert(at.* >= start);

    return text[start..at.*];
}

test "Scanner: tags in order, comments and raw text skipped" {
    const html = "<!doctype html><!-- <b> --><p class='a>b'>x</p><script><i></script><br/>";
    var scanner: Scanner = .{
        .html = html,
        .at = 0,
        .end = html.len,
    };
    const expected = [_][]const u8{ "p", "p", "script", "script", "br" };

    for (expected) |name| {
        try std.testing.expectEqualStrings(name, scanner.next().?.name);
    }

    try std.testing.expect(scanner.next() == null);
}

test "attribute_of: quoted, bare, valueless, any case, and absent" {
    const html = "<div A=\"1\" b='2' c=3 d>";
    var scanner: Scanner = .{
        .html = html,
        .at = 0,
        .end = html.len,
    };
    const tag = scanner.next().?;

    try std.testing.expectEqualStrings("1", attribute_of(html, tag, "a").?);
    try std.testing.expectEqualStrings("2", attribute_of(html, tag, "b").?);
    try std.testing.expectEqualStrings("3", attribute_of(html, tag, "c").?);
    try std.testing.expectEqualStrings("", attribute_of(html, tag, "d").?);
    try std.testing.expect(attribute_of(html, tag, "e") == null);

    const unterminated = "<div e=\"never closed>";
    var stopped: Scanner = .{
        .html = unterminated,
        .at = 0,
        .end = unterminated.len,
    };

    try std.testing.expect(stopped.next() == null);
}
