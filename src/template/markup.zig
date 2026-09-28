//! The body of a template: markup passed through verbatim, tags with their attributes
//! and children, `<slot />`, and the hand-off to components and `{...}` constructs.

const std = @import("std");
const ast = @import("ast.zig");
const compile = @import("compile.zig");
const expression = @import("expression.zig");
const blocks = @import("blocks.zig");
const components = @import("components.zig");

const Compiler = compile.Compiler;
const Error = compile.Error;
const Node = ast.Node;

pub const attributes_max: u32 = 128;

const void_elements = [_][]const u8{
    "area",  "base", "br",   "col",    "embed", "hr",  "img",
    "input", "link", "meta", "source", "track", "wbr",
};

/// Reads markup until the end of the source, or until `</close>` when inside an element.
pub fn parse(compiler: *Compiler, close: ?[]const u8) Error!void {
    try compiler.descend();
    defer compiler.ascend();

    std.debug.assert(compiler.depth > 0);

    while (compiler.position < compiler.source.len) {
        const rest = compiler.source[compiler.position..];

        if (std.mem.startsWith(u8, rest, "</")) {
            const closed = try closing_tag(compiler, rest, close);

            if (closed) {
                return;
            }

            continue;
        }

        if (try passthrough(compiler, rest)) {
            continue;
        }

        if (starts_with_tag(rest, "slot")) {
            try slot_tag(compiler, rest);
            continue;
        }

        if (std.mem.startsWith(u8, rest, "{/*")) {
            const end = std.mem.indexOf(u8, rest, "*/}") orelse {
                return compiler.fail("unterminated JS comment", .{});
            };
            compiler.position += @intCast(end + "*/}".len);
            continue;
        }

        if (rest[0] == '{') {
            const end = try expression.expression_end(compiler, rest, 0);
            compiler.position += end + 1;
            try blocks.child(compiler, rest[1..end]);
            continue;
        }

        if (rest[0] == '<' and rest.len > 1 and std.ascii.isAlphabetic(rest[1])) {
            try tag(compiler);
            continue;
        }

        try text_run(compiler, rest);
    }

    if (close) |expected| {
        return compiler.fail("missing </{s}>", .{expected});
    }
}

/// `</name>`: true when it closes the element being read; a stray one is refused.
fn closing_tag(compiler: *Compiler, rest: []const u8, close: ?[]const u8) Error!bool {
    std.debug.assert(std.mem.startsWith(u8, rest, "</"));

    const end = std.mem.indexOfScalar(u8, rest, '>') orelse {
        return compiler.fail("unterminated closing tag: {s}", .{compiler.excerpt(rest)});
    };
    const name = std.mem.trim(u8, rest[2..end], " \t\r\n");
    const expected = close orelse {
        return compiler.fail("stray closing tag </{s}>", .{name});
    };

    if (!std.mem.eql(u8, name, expected)) {
        return compiler.fail("</{s}> closes an open <{s}>", .{ name, expected });
    }

    compiler.position += @intCast(end + 1);

    std.debug.assert(compiler.position <= compiler.source.len);

    return true;
}

/// Comments, declarations, `<script>` and `<style>` go through untouched.
fn passthrough(compiler: *Compiler, rest: []const u8) Error!bool {
    std.debug.assert(rest.len > 0);

    if (std.mem.startsWith(u8, rest, "<!--")) {
        const end = std.mem.indexOf(u8, rest, "-->") orelse {
            return compiler.fail("unterminated comment: {s}", .{compiler.excerpt(rest)});
        };

        try take_static(compiler, rest, @intCast(end + 3));

        return true;
    }

    if (std.mem.startsWith(u8, rest, "<!")) {
        const end = std.mem.indexOfScalar(u8, rest, '>') orelse {
            return compiler.fail("unterminated declaration: {s}", .{compiler.excerpt(rest)});
        };

        try take_static(compiler, rest, @intCast(end + 1));

        return true;
    }

    const script = starts_with_tag(rest, "script");
    const style = starts_with_tag(rest, "style");

    if (script or style) {
        const closing: []const u8 = if (script) "</script>" else "</style>";
        const end = std.mem.indexOf(u8, rest, closing) orelse {
            return compiler.fail("unterminated {s}", .{closing[2 .. closing.len - 1]});
        };

        try take_static(compiler, rest, @intCast(end + closing.len));

        return true;
    }

    return false;
}

fn take_static(compiler: *Compiler, rest: []const u8, len: u32) Error!void {
    std.debug.assert(len <= rest.len);
    std.debug.assert(len > 0);

    try compiler.static(rest[0..len]);
    compiler.position += len;
}

/// Text up to the next `<` or `{`.
fn text_run(compiler: *Compiler, rest: []const u8) Error!void {
    std.debug.assert(rest.len > 0);

    var len: u32 = 1;

    while (len < rest.len and rest[len] != '<' and rest[len] != '{') len += 1;

    std.debug.assert(len <= rest.len);

    try take_static(compiler, rest, len);
}

fn slot_tag(compiler: *Compiler, rest: []const u8) Error!void {
    std.debug.assert(starts_with_tag(rest, "slot"));

    const end = std.mem.indexOfScalar(u8, rest, '>') orelse {
        return compiler.fail("unterminated <slot>", .{});
    };

    if (std.mem.indexOf(u8, rest[0..end], "name=") != null) {
        return compiler.fail(
            "<slot name> — there are no named slots; what a call site must supply is a " ++
                "prop: {{props.name ?? \"…\"}}",
            .{},
        );
    }

    compiler.position += @intCast(end + 1);

    if (std.mem.startsWith(u8, compiler.source[compiler.position..], "</slot>")) {
        compiler.position += "</slot>".len;
    }

    if (compiler.template.kind != .layout) {
        return compiler.fail("<slot /> belongs in a layout or component, not a page", .{});
    }

    if (compiler.template.reads_request) {
        return compiler.fail(
            "<slot /> — a dynamic island has no children, only a fallback it replaces; " ++
                "what a call site must supply is a prop",
            .{},
        );
    }

    try compiler.push(.slot);
}

/// Parses `text` as markup in the current scope, then resumes the outer text.
pub fn parse_sub(compiler: *Compiler, text: []const u8) Error!void {
    const outer_source = compiler.source;
    const outer_position = compiler.position;

    std.debug.assert(outer_position <= outer_source.len);

    compiler.source = text;
    compiler.position = 0;
    try parse(compiler, null);
    compiler.source = outer_source;
    compiler.position = outer_position;
}

/// Parses into a fresh list, returning it, with the outer list restored.
pub fn sub_list(compiler: *Compiler, text: []const u8) Error![]const Node {
    var list: std.ArrayList(Node) = .empty;
    const outer = compiler.out;

    try compiler.flush();
    compiler.out = &list;
    try parse_sub(compiler, text);
    try compiler.flush();
    compiler.out = outer;

    std.debug.assert(compiler.out == outer);

    return list.items;
}

/// The children of an open component tag through `</Name>`, into a fresh list.
pub fn children_list(compiler: *Compiler, name: []const u8) Error![]const Node {
    std.debug.assert(name.len > 0);

    var list: std.ArrayList(Node) = .empty;
    const outer = compiler.out;

    try compiler.flush();
    compiler.out = &list;
    try parse(compiler, name);
    try compiler.flush();
    compiler.out = outer;

    std.debug.assert(compiler.out == outer);

    return list.items;
}

/// The source between the current position and `</Name>`, the position left past the
/// closing tag. (A component does not nest inside itself.)
pub fn take_children(compiler: *Compiler, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    const closer = try std.fmt.allocPrint(compiler.arena, "</{s}>", .{name});
    const rest = compiler.source[compiler.position..];
    const end = std.mem.indexOf(u8, rest, closer) orelse {
        return compiler.fail("missing {s}", .{closer});
    };
    const source = rest[0..end];

    compiler.position += @intCast(end + closer.len);

    std.debug.assert(compiler.position <= compiler.source.len);

    return source;
}

/// The children of `name`, with whitespace preserved verbatim when the element is one
/// whose whitespace is content.
fn parse_children(compiler: *Compiler, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    if (!literal_text(name)) {
        return parse(compiler, name);
    }

    try compiler.flush();
    compiler.literal_depth += 1;
    try parse(compiler, name);
    try compiler.flush();
    compiler.literal_depth -= 1;
    compiler.pending_space = false;
}

fn literal_text(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for ([_][]const u8{ "pre", "textarea", "script", "style" }) |kept| {
        if (std.mem.eql(u8, name, kept)) {
            return true;
        }
    }

    return false;
}

pub const Attr = struct {
    name: []const u8,
    /// The attribute as written, for literals and bare names; null for `={expr}`.
    verbatim: ?[]const u8,
    /// The literal value without quotes.
    literal: ?[]const u8,
    /// The expression text inside `{}`.
    expression: ?[]const u8,
};

/// One `<tag ...>` with its attributes and, unless void or self-closing, its children
/// through the matching close tag.
fn tag(compiler: *Compiler) Error!void {
    const source = compiler.source;
    const start = compiler.position;
    var index = start + 1;

    std.debug.assert(source[start] == '<');

    while (index < source.len and is_tag_char(source[index])) index += 1;

    const name = source[start + 1 .. index];
    compiler.position = index;

    var attributes: std.ArrayList(Attr) = .empty;
    const self_closing = try read_attributes(compiler, name, &attributes);

    if (std.ascii.isUpper(name[0])) {
        return components.component(compiler, name, attributes.items, self_closing);
    }

    try compiler.static("<");
    try compiler.static(name);

    const set_html = try write_attributes(compiler, name, attributes.items);

    try compiler.static(">");

    if (is_void(name)) {
        return;
    }

    if (set_html) |raw| {
        try write_raw(compiler, raw);
    }

    if (!self_closing) {
        try parse_children(compiler, name);
    }

    // Everything the head owes the page is written where the app closes it; what
    // that is exactly is the host's to decide.
    if (set_html == null and std.mem.eql(u8, name, "head")) {
        compiler.template.has_head = true;
        try compiler.push(.head_assets);
    }

    try compiler.static("</");
    try compiler.static(name);
    try compiler.static(">");
}

fn is_void(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (void_elements) |void_tag| {
        if (std.mem.eql(u8, name, void_tag)) {
            return true;
        }
    }

    return false;
}

fn is_tag_char(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == ':' or byte == '.' or
        byte == '_';
}

/// The attributes after a tag name, up to `>` or `/>`; whether the tag self-closed.
fn read_attributes(
    compiler: *Compiler,
    name: []const u8,
    attributes: *std.ArrayList(Attr),
) Error!bool {
    std.debug.assert(name.len > 0);

    const source = compiler.source;

    while (true) {
        skip_whitespace(compiler);

        if (compiler.position >= source.len) {
            return compiler.fail("unterminated <{s}>", .{name});
        }

        if (source[compiler.position] == '>') {
            compiler.position += 1;

            return false;
        }

        if (std.mem.startsWith(u8, source[compiler.position..], "/>")) {
            compiler.position += 2;

            return true;
        }

        if (attributes.items.len == attributes_max) {
            return compiler.fail("<{s}> has more than {d} attributes", .{ name, attributes_max });
        }

        try attributes.append(compiler.arena, try read_attribute(compiler, name));
    }
}

fn skip_whitespace(compiler: *Compiler) void {
    const source = compiler.source;

    std.debug.assert(compiler.position <= source.len);

    while (compiler.position < source.len and std.ascii.isWhitespace(source[compiler.position])) {
        compiler.position += 1;
    }
}

fn read_attribute(compiler: *Compiler, name: []const u8) Error!Attr {
    const source = compiler.source;
    const start = compiler.position;

    std.debug.assert(start < source.len);

    while (compiler.position < source.len and is_attribute_char(source[compiler.position])) {
        compiler.position += 1;
    }

    const attr_name = source[start..compiler.position];

    if (attr_name.len == 0) {
        return compiler.fail(
            "malformed attribute in <{s}>: {s}",
            .{ name, compiler.excerpt(source[compiler.position..]) },
        );
    }

    if (compiler.position >= source.len or source[compiler.position] != '=') {
        return .{ .name = attr_name, .verbatim = attr_name, .literal = null, .expression = null };
    }

    compiler.position += 1;

    if (compiler.position >= source.len) {
        return compiler.fail("unterminated attribute {s}", .{attr_name});
    }

    const quote = source[compiler.position];

    if (quote == '"' or quote == '\'') {
        const end = std.mem.indexOfScalarPos(u8, source, compiler.position + 1, quote) orelse {
            return compiler.fail("unterminated attribute value: {s}", .{attr_name});
        };
        const attr: Attr = .{
            .name = attr_name,
            .verbatim = source[start .. end + 1],
            .literal = source[compiler.position + 1 .. end],
            .expression = null,
        };
        compiler.position = @intCast(end + 1);

        return attr;
    }

    if (quote == '{') {
        const end = try expression.expression_end(compiler, source[compiler.position..], 0);
        const attr: Attr = .{
            .name = attr_name,
            .verbatim = null,
            .literal = null,
            .expression = source[compiler.position + 1 .. compiler.position + end],
        };
        compiler.position += end + 1;

        return attr;
    }

    return compiler.fail("attribute {s} needs a quoted value or {{expression}}", .{attr_name});
}

fn is_attribute_char(byte: u8) bool {
    return !std.ascii.isWhitespace(byte) and byte != '=' and byte != '>' and byte != '/';
}

/// Writes an element's attributes; returns the `set:html` expression when it has one.
fn write_attributes(
    compiler: *Compiler,
    name: []const u8,
    attributes: []const Attr,
) Error!?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(attributes.len <= attributes_max);

    var set_html: ?[]const u8 = null;

    for (attributes) |attr| {
        if (std.mem.eql(u8, attr.name, "set:html")) {
            set_html = attr.expression orelse {
                return compiler.fail("set:html takes an {{expression}}", .{});
            };
            continue;
        }

        if (attr.verbatim) |verbatim| {
            try write_literal_attribute(compiler, attr, verbatim);
            continue;
        }

        try attribute_expression(compiler, attr.name, attr.expression.?);
    }

    return set_html;
}

/// A literal attribute as written; an `/_app/...` URL is written through the host, which
/// puts it under the app's mount and appends the asset fingerprint, and `class` feeds the
/// stylesheet.
fn write_literal_attribute(compiler: *Compiler, attr: Attr, verbatim: []const u8) Error!void {
    std.debug.assert(verbatim.len > 0);
    std.debug.assert(attr.expression == null);

    if (attr.literal) |value| {
        if (std.mem.startsWith(u8, value, "/_app/")) {
            try compiler.static(" ");
            try compiler.static(attr.name);
            try compiler.static("=\"");
            try compiler.push(.{ .asset = value });
            try compiler.static("\"");

            return;
        }
    }

    try compiler.static(" ");
    try compiler.static(verbatim);

    if (std.mem.eql(u8, attr.name, "class")) {
        if (attr.literal) |classes| {
            try collect_classes(compiler, classes);
        }
    }
}

pub fn collect_classes(compiler: *Compiler, classes: []const u8) Error!void {
    std.debug.assert(compiler.template.compiling);

    var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n");

    while (tokens.next()) |class| {
        try compiler.classes.append(compiler.arena, class);
    }
}

/// ` name="..."` from an expression: strings escaped, optionals only when present,
/// booleans as bare attributes, numbers printed.
fn attribute_expression(compiler: *Compiler, name: []const u8, text: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    const value = try expression.expression(compiler, text);

    switch (value.type) {
        .boolean, .opt_string, .string, .int => {
            try compiler.push(.{ .attr = .{ .name = name, .expr = value } });
        },
        else => return compiler.fail(
            "attribute {s} has a value of type {s}, which cannot be written",
            .{ name, @tagName(value.type) },
        ),
    }
}

/// `set:html={v}`: the value written without escaping.
fn write_raw(compiler: *Compiler, text: []const u8) Error!void {
    std.debug.assert(text.len > 0);

    const value = try expression.expression(compiler, text);

    switch (value.type) {
        .string, .opt_string => try compiler.push(.{ .raw = value }),
        else => return compiler.fail(
            "set:html needs a string; got a {s}",
            .{@tagName(value.type)},
        ),
    }
}

pub fn starts_with_tag(text: []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    if (text.len < name.len + 2 or text[0] != '<') {
        return false;
    }

    if (!std.ascii.eqlIgnoreCase(text[1 .. 1 + name.len], name)) {
        return false;
    }

    const after = text[1 + name.len];

    return after == '>' or after == '/' or std.ascii.isWhitespace(after);
}

test "tags are recognised by name and delimiter, case-insensitively" {
    try std.testing.expect(starts_with_tag("<slot />", "slot"));
    try std.testing.expect(starts_with_tag("<SCRIPT>", "script"));
    try std.testing.expect(!starts_with_tag("<slotted>", "slot"));
    try std.testing.expect(!starts_with_tag("slot", "slot"));
    try std.testing.expect(is_void("br"));
    try std.testing.expect(!is_void("div"));
    try std.testing.expect(literal_text("pre"));
    try std.testing.expect(!literal_text("p"));
}
