//! A run of Markdown text (a paragraph, a heading, a table cell) written as HTML. Read
//! into tokens over the pairs `spans.zig` finds, emphasis paired by `emphasis.zig`, then
//! written: three passes, no recursion.

const std = @import("std");
const escape = @import("escape.zig");
const spans_module = @import("spans.zig");
const emphasis = @import("emphasis.zig");
const link = @import("link.zig");
const token_module = @import("token.zig");

const Token = token_module.Token;
const Writer = std.Io.Writer;

pub const Options = escape.Options;
pub const Error = Writer.Error || std.mem.Allocator.Error;

pub fn write(
    arena: std.mem.Allocator,
    writer: *Writer,
    input: []const u8,
    options: Options,
) Error!void {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    const spans = try spans_module.find(arena, input);
    const tokens = try read(arena, input, spans);

    try emphasis.pair(arena, tokens);

    var at: u32 = 0;

    for (tokens) |*token| {
        std.debug.assert(token.start >= at);

        try escape.text(writer, input[at..token.start], options);
        try write_token(writer, input, token, options);
        at = token.end;
    }

    try escape.text(writer, input[at..], options);
}

const Reader = struct {
    arena: std.mem.Allocator,
    input: []const u8,
    spans: spans_module.Spans,
    tokens: std.ArrayList(Token) = .empty,
    next_code: u32 = 0,
    next_bracket: u32 = 0,
    /// The open link's `]` and the end of its `(…)`.
    link_close: ?u32 = null,
    link_end: u32 = 0,
    destinations: link.Memo = .{},
};

fn read(arena: std.mem.Allocator, input: []const u8, spans: spans_module.Spans) ![]Token {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    var reader: Reader = .{
        .arena = arena,
        .input = input,
        .spans = spans,
    };
    var index: u32 = 0;

    while (index < input.len) {
        const next = try step(&reader, index);

        std.debug.assert(next > index);

        index = next;
    }

    return reader.tokens.items;
}

/// Reads what starts at `index`, adds its token when it is one, and answers where the next
/// read starts.
fn step(reader: *Reader, index: u32) !u32 {
    const input = reader.input;

    std.debug.assert(index < input.len);

    if (reader.link_close == index) {
        reader.link_close = null;
        return add(reader, .{
            .kind = .link_close,
            .start = index,
            .end = reader.link_end,
        });
    }

    const codes = reader.spans.code;

    if (reader.next_code < codes.len and codes[reader.next_code].open == index) {
        const code = codes[reader.next_code];
        reader.next_code += 1;
        return add(reader, .{
            .kind = .code,
            .start = index,
            .end = code.close + code.len,
            .inner_start = index + code.len,
            .inner_end = code.close,
        });
    }

    return switch (input[index]) {
        '\\' => backslash(reader, index),
        '`' => run_end(input, index),
        '<' => angle(reader, index),
        '!', '[' => bracket(reader, index),
        '*', '_', '~' => delimiter(reader, index),
        ' ' => spaces(reader, index),
        else => index + 1,
    };
}

/// Adds `token`, unless it would reach past the open link's `]`: then its first character
/// is text and the read goes on after it.
fn add(reader: *Reader, token: Token) !u32 {
    std.debug.assert(token.end > token.start);
    std.debug.assert(token.end <= reader.input.len);

    if (reader.link_close) |close| {
        if (token.kind != .link_close and token.end > close) {
            return token.start + 1;
        }
    }

    try reader.tokens.append(reader.arena, token);

    return token.end;
}

fn run_end(input: []const u8, index: u32) u32 {
    std.debug.assert(index < input.len);

    var end = index;

    while (end < input.len and input[end] == input[index]) {
        end += 1;
    }

    std.debug.assert(end > index);

    return end;
}

fn backslash(reader: *Reader, index: u32) !u32 {
    const input = reader.input;

    std.debug.assert(input[index] == '\\');

    if (index + 1 == input.len) {
        return index + 1;
    }

    const next = input[index + 1];

    if (next == '\n') {
        return add(reader, .{
            .kind = .hard_break,
            .start = index,
            .end = index + 2,
        });
    }

    if (!std.ascii.isPrint(next) or std.ascii.isAlphanumeric(next) or next == ' ') {
        return index + 1;
    }

    return add(reader, .{
        .kind = .escape,
        .start = index,
        .end = index + 2,
    });
}

/// `<https://…>`, `<name@host>`, or an inline tag; else a `<` that is text.
fn angle(reader: *Reader, index: u32) !u32 {
    const input = reader.input;

    std.debug.assert(input[index] == '<');

    const found = std.mem.indexOfAnyPos(u8, input, index + 1, "<>\n") orelse return index + 1;
    const close: u32 = @intCast(found);

    if (input[close] != '>') {
        return index + 1;
    }

    const inside = input[index + 1 .. close];

    if (link.autolink(inside)) |href| {
        return add(reader, .{
            .kind = .autolink,
            .start = index,
            .end = close + 1,
            .inner_start = index + 1,
            .inner_end = close,
            .href = href,
        });
    }

    if (!link.is_tag(inside)) {
        return index + 1;
    }

    return add(reader, .{
        .kind = .html,
        .start = index,
        .end = close + 1,
    });
}

/// `![alt](src)` whole, or the `[` of `[text](href)`, when the bracket's pair is followed
/// by a destination; else text. A link inside a link's text is text.
fn bracket(reader: *Reader, index: u32) !u32 {
    const input = reader.input;
    const image = input[index] == '!';
    const open = if (image) index + 1 else index;

    std.debug.assert(input[index] == '!' or input[index] == '[');

    if (open >= input.len or input[open] != '[' or (!image and reader.link_close != null)) {
        return index + 1;
    }

    const close = pair_of(reader, open) orelse return index + 1;
    const target = link.destination(&reader.destinations, input, close + 1) orelse {
        return index + 1;
    };

    if (image) {
        return add(reader, .{
            .kind = .image,
            .start = index,
            .end = target.end,
            .inner_start = open + 1,
            .inner_end = close,
            .href = target.href,
            .title = target.title,
        });
    }

    reader.link_close = close;
    reader.link_end = target.end;

    return add(reader, .{
        .kind = .link_open,
        .start = index,
        .end = index + 1,
        .href = target.href,
        .title = target.title,
    });
}

/// The `]` pairing the `[` at `open`; brackets are visited in order, so a cursor finds it.
fn pair_of(reader: *Reader, open: u32) ?u32 {
    const brackets = reader.spans.brackets;

    std.debug.assert(reader.input[open] == '[');

    while (reader.next_bracket < brackets.len and brackets[reader.next_bracket].open < open) {
        reader.next_bracket += 1;
    }

    if (reader.next_bracket == brackets.len or brackets[reader.next_bracket].open != open) {
        return null;
    }

    const close = brackets[reader.next_bracket].close;

    std.debug.assert(close > open);

    return close;
}

/// A run of `*` or `_`, or exactly `~~`, with what it may do by what is on either side.
fn delimiter(reader: *Reader, index: u32) !u32 {
    const input = reader.input;
    const marker = input[index];
    const end = run_end(input, index);
    const len = end - index;

    std.debug.assert(len > 0);

    if (marker == '~' and len != 2) {
        return end;
    }

    const before: u8 = if (index == 0) ' ' else input[index - 1];
    const after: u8 = if (end == input.len) ' ' else input[end];
    const left = !is_space(after) and (!is_punctuation(after) or is_space(before) or
        is_punctuation(before));
    const right = !is_space(before) and (!is_punctuation(before) or is_space(after) or
        is_punctuation(after));
    const can_open = if (marker == '_') left and (!right or is_punctuation(before)) else left;
    const can_close = if (marker == '_') right and (!left or is_punctuation(after)) else right;

    if (!can_open and !can_close) {
        return end;
    }

    return add(reader, .{
        .kind = .delimiter,
        .start = index,
        .end = end,
        .marker = marker,
        .can_open = can_open,
        .can_close = can_close,
        .remaining = len,
    });
}

/// Two or more spaces before a line's end break the line.
fn spaces(reader: *Reader, index: u32) !u32 {
    const input = reader.input;
    const end = run_end(input, index);

    std.debug.assert(input[index] == ' ');

    if (end - index < 2 or end == input.len or input[end] != '\n') {
        return end;
    }

    return add(reader, .{
        .kind = .hard_break,
        .start = index,
        .end = end + 1,
    });
}

fn is_space(char: u8) bool {
    return char == ' ' or char == '\n' or char == '\t' or char == '\r';
}

fn is_punctuation(char: u8) bool {
    return std.ascii.isPrint(char) and !std.ascii.isAlphanumeric(char) and char != ' ';
}

fn write_token(writer: *Writer, input: []const u8, token: *const Token, options: Options) !void {
    std.debug.assert(token.end <= input.len);
    std.debug.assert(token.start < token.end);

    switch (token.kind) {
        .code => {
            try writer.writeAll("<code>");
            const code = code_text(input[token.inner_start..token.inner_end]);
            try escape.literal(writer, code, options);
            try writer.writeAll("</code>");
        },
        .html => try escape.raw(writer, input[token.start..token.end], options),
        .autolink => try link.write_autolink(writer, token.href, options),
        .escape => try escape.literal(writer, input[token.start + 1 .. token.end], options),
        .hard_break => try writer.writeAll("<br />\n"),
        .link_open => try link.write_open(writer, token.href, token.title, options),
        .link_close => try writer.writeAll("</a>"),
        .image => try link.write_image(writer, .{
            .src = token.href,
            .alt = input[token.inner_start..token.inner_end],
            .title = token.title,
        }, options),
        .delimiter => try write_delimiter(writer, token),
    }
}

/// A code span's text: one space trimmed from each side when both have one and it is not
/// all spaces.
fn code_text(text: []const u8) []const u8 {
    const padded = text.len >= 2 and text[0] == ' ' and text[text.len - 1] == ' ';
    const blank = std.mem.trim(u8, text, " ").len == 0;

    if (padded and !blank) {
        return text[1 .. text.len - 1];
    }

    std.debug.assert(!padded or blank);

    return text;
}

fn write_delimiter(writer: *Writer, token: *const Token) !void {
    std.debug.assert(token.kind == .delimiter);
    std.debug.assert(token.opens_len <= token_module.tags_per_run_max);

    for (token.closes[0..token.closes_len]) |tag| {
        try writer.print("</{s}>", .{tag.name()});
    }

    try writer.splatByteAll(token.marker, token.remaining);

    for (token.opens[0..token.opens_len]) |tag| {
        try writer.print("<{s}>", .{tag.name()});
    }
}

test {
    _ = @import("inline_tests.zig");
}
