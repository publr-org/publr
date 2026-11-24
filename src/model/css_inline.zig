//! CSS written into each element's `style`, as mail apps want it: they drop `<style>` or
//! read it in part. The rules of the document's `<style>` blocks whose selectors are simple
//! (`p`, `.button`, `#footer`, `a.button`, comma lists of them) go onto every element they
//! match, before what the element's own `style` says, which keeps winning; the rest
//! (`@media`, `a:hover`, `td p`) stays in a `<style>` for the mail apps that read it.
const std = @import("std");

pub const rules_max: u32 = 512;
pub const html_bytes_max: u32 = 4 << 20;

const Simple = struct {
    tag: []const u8 = "",
    class: []const u8 = "",
    id: []const u8 = "",
};

const Rule = struct {
    selector: Simple,
    declarations: []const u8,
};

/// `html` with its simple style rules written into the elements they match.
pub fn inline_css(arena: std.mem.Allocator, html: []const u8) error{
    OutOfMemory,
    TooLarge,
}![]const u8 {
    std.debug.assert(rules_max > 0);

    if (html.len > html_bytes_max) {
        return error.TooLarge;
    }

    var rules: std.ArrayList(Rule) = .empty;
    var kept: std.ArrayList(u8) = .empty;
    const body = try styles_taken(arena, html, &rules, &kept);

    if (rules.items.len == 0) {
        return html;
    }

    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;

    while (std.mem.indexOfScalarPos(u8, body, at, '<')) |open| {
        const close = std.mem.indexOfScalarPos(u8, body, open, '>') orelse break;

        try out.appendSlice(arena, body[at..open]);
        try out.appendSlice(arena, try styled(arena, body[open .. close + 1], rules.items));
        at = @intCast(close + 1);
    }

    try out.appendSlice(arena, body[at..]);

    if (kept.items.len == 0) {
        return out.items;
    }

    return with_style(arena, out.items, kept.items);
}

/// The document without its `<style>` blocks; their simple rules in `rules`, the rest in
/// `kept`.
fn styles_taken(
    arena: std.mem.Allocator,
    html: []const u8,
    rules: *std.ArrayList(Rule),
    kept: *std.ArrayList(u8),
) error{OutOfMemory}![]const u8 {
    std.debug.assert(html.len <= html_bytes_max);

    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;

    while (std.mem.indexOfPos(u8, html, at, "<style")) |open| {
        const start = std.mem.indexOfScalarPos(u8, html, open, '>') orelse break;
        const end = std.mem.indexOfPos(u8, html, start, "</style>") orelse break;

        try out.appendSlice(arena, html[at..open]);
        try rules_of(arena, html[start + 1 .. end], rules, kept);
        at = @intCast(end + "</style>".len);
    }

    try out.appendSlice(arena, html[at..]);

    return out.items;
}

fn rules_of(
    arena: std.mem.Allocator,
    css: []const u8,
    rules: *std.ArrayList(Rule),
    kept: *std.ArrayList(u8),
) error{OutOfMemory}!void {
    std.debug.assert(css.len <= html_bytes_max);

    var at: u32 = 0;

    while (at < css.len) {
        const open = std.mem.indexOfScalarPos(u8, css, at, '{') orelse break;
        const selectors = std.mem.trim(u8, css[at..open], " \t\r\n");

        // A block inside a block (`@media`) is kept whole.
        if (std.mem.startsWith(u8, selectors, "@")) {
            const end = block_end(css, open) orelse css.len;

            try kept.appendSlice(arena, css[@intCast(at)..@intCast(end)]);
            at = @intCast(end);
            continue;
        }

        const close = std.mem.indexOfScalarPos(u8, css, open, '}') orelse css.len;
        const declarations = std.mem.trim(u8, css[open + 1 .. close], " \t\r\n;");

        at = @intCast(@min(close + 1, css.len));

        if (!try simple_rules(arena, selectors, declarations, rules)) {
            try kept.appendSlice(arena, try std.mem.concat(arena, u8, &.{
                selectors,
                "{",
                declarations,
                "}",
            }));
        }
    }
}

/// Whether every selector of the list is simple: each then a rule.
fn simple_rules(
    arena: std.mem.Allocator,
    selectors: []const u8,
    declarations: []const u8,
    rules: *std.ArrayList(Rule),
) error{OutOfMemory}!bool {
    std.debug.assert(selectors.len <= html_bytes_max);

    var parsed: std.ArrayList(Simple) = .empty;
    var each = std.mem.splitScalar(u8, selectors, ',');

    while (each.next()) |part| {
        const selector = simple_of(std.mem.trim(u8, part, " \t\r\n")) orelse return false;

        try parsed.append(arena, selector);
    }

    for (parsed.items) |selector| {
        if (rules.items.len >= rules_max) {
            return true;
        }

        try rules.append(arena, .{
            .selector = selector,
            .declarations = declarations,
        });
    }

    return true;
}

/// `p`, `.button`, `#footer`, `a.button`; null for anything else.
fn simple_of(text: []const u8) ?Simple {
    std.debug.assert(text.len <= html_bytes_max);

    if (text.len == 0) {
        return null;
    }

    for (text) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or
            char == '.' or char == '#';

        if (!allowed) {
            return null;
        }
    }

    if (text[0] == '#') {
        return .{
            .id = text[1..],
        };
    }

    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return .{
        .tag = text,
    };

    if (std.mem.indexOfScalarPos(u8, text, dot + 1, '.') != null) {
        return null;
    }

    return .{
        .tag = text[0..dot],
        .class = text[dot + 1 ..],
    };
}

fn block_end(css: []const u8, open: u64) ?u64 {
    std.debug.assert(open < css.len);

    var depth: u32 = 0;

    for (css[@intCast(open)..], @intCast(open)..) |char, index| {
        if (char == '{') {
            depth += 1;
        } else if (char == '}') {
            depth -= 1;

            if (depth == 0) {
                return index + 1;
            }
        }
    }

    return null;
}

/// One tag with the declarations of the rules matching it before its own `style`.
fn styled(arena: std.mem.Allocator, tag: []const u8, rules: []const Rule) error{
    OutOfMemory,
}![]const u8 {
    std.debug.assert(tag.len >= 2 and tag[0] == '<');

    if (tag[1] == '/' or tag[1] == '!') {
        return tag;
    }

    const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n/>") orelse return tag;
    const name = tag[1..name_end];
    var added: std.ArrayList(u8) = .empty;

    for (rules) |rule| {
        if (matches(rule.selector, name, tag)) {
            try added.appendSlice(arena, rule.declarations);
            try added.append(arena, ';');
        }
    }

    if (added.items.len == 0) {
        return tag;
    }

    if (attribute(tag, "style")) |own| {
        const at = @intFromPtr(own.ptr) - @intFromPtr(tag.ptr);

        return std.mem.concat(arena, u8, &.{ tag[0..at], added.items, own, tag[at + own.len ..] });
    }

    return std.mem.concat(arena, u8, &.{
        tag[0..name_end],
        " style=\"",
        added.items,
        "\"",
        tag[name_end..],
    });
}

fn matches(selector: Simple, name: []const u8, tag: []const u8) bool {
    std.debug.assert(tag.len > 0);

    if (selector.tag.len > 0 and !std.ascii.eqlIgnoreCase(selector.tag, name)) {
        return false;
    }

    if (selector.id.len > 0) {
        const id = attribute(tag, "id") orelse return false;

        return std.mem.eql(u8, id, selector.id);
    }

    if (selector.class.len > 0) {
        const classes = attribute(tag, "class") orelse return false;
        var each = std.mem.tokenizeAny(u8, classes, " \t\r\n");

        while (each.next()) |class| {
            if (std.mem.eql(u8, class, selector.class)) {
                return true;
            }
        }

        return false;
    }

    return selector.tag.len > 0;
}

/// An attribute's value, quoted with `"`; null when the tag has none.
fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    var at: u32 = 0;

    while (std.mem.indexOfPos(u8, tag, at, name)) |found| {
        at = @intCast(found + name.len);

        const before_ok = found > 0 and std.ascii.isWhitespace(tag[found - 1]);
        const rest = tag[at..];

        if (before_ok and std.mem.startsWith(u8, rest, "=\"")) {
            const end = std.mem.indexOfScalarPos(u8, tag, at + 2, '"') orelse return null;

            return tag[at + 2 .. end];
        }
    }

    return null;
}

/// The rules no element took back in a `<style>`, in the head when there is one.
fn with_style(arena: std.mem.Allocator, html: []const u8, css: []const u8) error{
    OutOfMemory,
}![]const u8 {
    std.debug.assert(css.len > 0);

    const block = try std.mem.concat(arena, u8, &.{ "<style>", css, "</style>" });
    const head = std.mem.indexOf(u8, html, "</head>") orelse {
        return std.mem.concat(arena, u8, &.{ block, html });
    };

    return std.mem.concat(arena, u8, &.{ html[0..head], block, html[head..] });
}

test "simple rules go into each element's style, before its own; the rest stays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const html =
        \\<html><head><style>p { color: #333 } .button, #cta { background: blue }
        \\a:hover { color: red } @media (max-width: 600px) { p { font-size: 14px } }</style>
        \\</head><body><p>Hi</p><a class="big button" href="/x">Go</a>
        \\<p id="cta" style="margin: 0">More</p></body></html>
    ;
    const out = try inline_css(arena, html);

    try std.testing.expect(std.mem.indexOf(u8, out, "<p style=\"color: #333;\">Hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<a style=\"background: blue;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "style=\"color: #333;background: blue;" ++
        "margin: 0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a:hover{color: red}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@media (max-width: 600px)") != null);
    try std.testing.expectEqualStrings("<b>x</b>", try inline_css(arena, "<b>x</b>"));
}
