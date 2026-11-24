//! A page an installed plugin described, put together: its markup with each placeholder
//! (`<publr-drawn n="3">`, `sdk/plugin/view_wire.zig`) replaced by what the host drew for
//! that component, whose own markup may hold placeholders in turn. Attributes a writer put
//! on a placeholder (a list's row key, forwarded `data-part`, a slot's classes) move onto
//! the root the component drew. Everything here is text the plugin chose: a placeholder that
//! is malformed, names no component, or names one drawn after the markup it is in, ends the
//! page; so does a page past its size or its count of replacements.
const std = @import("std");
const view_wire = @import("../sdk/plugin/view_wire.zig");

pub const Error = error{ Invalid, OutOfMemory };

/// How deep components nest, and how many placeholders one page replaces.
pub const depth_max: u32 = 64;
pub const replacements_max: u32 = 1 << 18;
pub const attributes_max: u32 = 64;

const open = "<" ++ view_wire.placeholder_tag;

/// One attribute of a tag: its value as written, still escaped; null for a bare one.
const Attribute = struct {
    name: []const u8,
    value: ?[]const u8,
    /// Where it is in the tag, a space before it included.
    start: u32,
    end: u32,
};

/// A tag's attributes, and where the tag closes (`>` or `/>`).
const Tag = struct {
    attributes: [attributes_max]Attribute = undefined,
    count: u32 = 0,
    close: u32 = 0,
    end: u32 = 0,

    fn named(tag: *const Tag, name: []const u8) ?u32 {
        std.debug.assert(name.len > 0);
        std.debug.assert(tag.count <= attributes_max);

        for (tag.attributes[0..tag.count], 0..) |attribute, index| {
            if (std.mem.eql(u8, attribute.name, name)) {
                return @intCast(index);
            }
        }

        return null;
    }
};

/// The tag whose name ends at `from` in `text`: its attributes read up to its `>`.
fn tag_at(text: []const u8, from: u32) Error!Tag {
    var tag: Tag = .{};
    var at: u32 = from;

    std.debug.assert(from <= text.len);

    while (at < text.len) {
        while (at < text.len and std.ascii.isWhitespace(text[at])) {
            at += 1;
        }

        if (at >= text.len) {
            break;
        }

        if (text[at] == '>' or (text[at] == '/' and at + 1 < text.len and text[at + 1] == '>')) {
            tag.close = at;
            tag.end = if (text[at] == '>') at + 1 else at + 2;

            return tag;
        }

        if (tag.count == attributes_max) {
            return error.Invalid;
        }

        const attribute = try attribute_at(text, at);

        // The space before it belongs to it: taking it out leaves the tag well formed.
        tag.attributes[tag.count] = attribute;
        tag.attributes[tag.count].start = if (at > from) at - 1 else at;
        tag.count += 1;
        at = attribute.end;
    }

    return error.Invalid;
}

fn ends_name(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '=' or byte == '>';
}

/// Whether `byte` ends a value: its quote, or for one with none a space or the tag's end.
fn ends_value(byte: u8, quote: ?u8) bool {
    if (quote) |closing| {
        return byte == closing;
    }

    return std.ascii.isWhitespace(byte) or byte == '>';
}

fn attribute_at(text: []const u8, from: u32) Error!Attribute {
    var at: u32 = from;

    std.debug.assert(from < text.len);

    while (at < text.len and !ends_name(text[at])) {
        at += 1;
    }

    const name = text[from..at];

    if (name.len == 0 or at >= text.len) {
        return error.Invalid;
    }

    if (text[at] != '=') {
        return .{
            .name = name,
            .value = null,
            .start = from,
            .end = at,
        };
    }

    at += 1;

    if (at >= text.len) {
        return error.Invalid;
    }

    const quoted = text[at] == '"' or text[at] == '\'';
    const first: u32 = if (quoted) at + 1 else at;
    var last: u32 = first;

    while (last < text.len and !ends_value(text[last], if (quoted) text[at] else null)) {
        last += 1;
    }

    if (last >= text.len) {
        return error.Invalid;
    }

    return .{
        .name = name,
        .value = text[first..last],
        .start = from,
        .end = if (quoted) last + 1 else last,
    };
}

/// The next placeholder of `text` at or after `from`.
const Placed = struct {
    start: u32,
    tag: Tag,
    number: u32,
};

fn next_placed(text: []const u8, from: u32) Error!?Placed {
    var at: usize = from;

    std.debug.assert(from <= text.len);

    while (std.mem.indexOfPos(u8, text, at, open)) |start| {
        const after = start + open.len;

        at = after;

        if (after >= text.len) {
            return error.Invalid;
        }

        // A longer tag's name only begins like it.
        if (!std.ascii.isWhitespace(text[after]) and text[after] != '>') {
            continue;
        }

        const tag = try tag_at(text, @intCast(after));
        const index = tag.named(view_wire.placeholder_number) orelse return error.Invalid;
        const digits = tag.attributes[index].value orelse return error.Invalid;
        const number = std.fmt.parseInt(u32, digits, 10) catch return error.Invalid;

        std.debug.assert(tag.end > after);

        return .{
            .start = @intCast(start),
            .tag = tag,
            .number = number,
        };
    }

    return null;
}

/// Where the first element of `html` opens, after its name; null for markup with none.
fn root_of(html: []const u8) ?u32 {
    var at: usize = 0;

    std.debug.assert(html.len <= view_wire.markup_bytes_max);

    while (std.mem.indexOfScalarPos(u8, html, at, '<')) |start| {
        at = start + 1;

        if (at < html.len and std.ascii.isAlphabetic(html[at])) {
            while (at < html.len and !ends_name(html[at]) and html[at] != '/') {
                at += 1;
            }

            return @intCast(at);
        }
    }

    return null;
}

/// How a value given again joins the one a root has: classes and styles and the runtime's
/// lists add up, anything else is replaced.
fn joiner(name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    if (std.mem.eql(u8, name, "class")) {
        return " ";
    }

    for ([_][]const u8{ "style", "data-p-on", "data-p-ref", "data-p-bind" }) |listed| {
        if (std.mem.eql(u8, name, listed)) {
            return ";";
        }
    }

    return null;
}

fn write_value(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(value.len <= view_wire.markup_bytes_max);

    // A value from a single-quoted attribute may hold a double quote.
    for (value) |byte| {
        if (byte == '"') {
            try writer.writeAll("&quot;");
        } else {
            try writer.writeByte(byte);
        }
    }
}

/// The opening tag of `html`'s root with the placeholder's other attributes on it, and
/// where the rest of `html` begins; null when it has no element to carry them.
fn rooted(arena: std.mem.Allocator, html: []const u8, given: *const Tag) Error!?Rooted {
    const name_end = root_of(html) orelse return null;
    const root = try tag_at(html, name_end);
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    var replaced: [attributes_max]bool = @splat(false);
    var added: std.Io.Writer.Allocating = .init(arena);

    std.debug.assert(root.end <= html.len);

    for (given.attributes[0..given.count]) |attribute| {
        if (std.mem.eql(u8, attribute.name, view_wire.placeholder_number)) {
            continue;
        }

        added.writer.print(" {s}", .{attribute.name}) catch return error.OutOfMemory;

        const value = attribute.value orelse continue;
        const existing = root.named(attribute.name);

        added.writer.writeAll("=\"") catch return error.OutOfMemory;

        if (existing) |index| {
            replaced[index] = true;

            const before = root.attributes[index].value orelse "";

            if (joiner(attribute.name)) |between| {
                write_value(&added.writer, before) catch return error.OutOfMemory;

                if (before.len > 0 and value.len > 0) {
                    added.writer.writeAll(between) catch return error.OutOfMemory;
                }
            }
        }

        write_value(&added.writer, value) catch return error.OutOfMemory;
        added.writer.writeByte('"') catch return error.OutOfMemory;
    }

    var at: u32 = 0;

    for (root.attributes[0..root.count], 0..) |attribute, index| {
        if (replaced[index]) {
            writer.writeAll(html[at..attribute.start]) catch return error.OutOfMemory;
            at = attribute.end;
        }
    }

    writer.writeAll(html[at..root.close]) catch return error.OutOfMemory;
    writer.writeAll(added.written()) catch return error.OutOfMemory;
    writer.writeAll(html[root.close..root.end]) catch return error.OutOfMemory;

    return .{
        .head = out.written(),
        .rest = html[root.end..],
    };
}

const Rooted = struct {
    head: []const u8,
    rest: []const u8,
};

/// Markup being written: placeholders in it name components drawn before `below`.
const Frame = struct {
    text: []const u8,
    at: u32 = 0,
    below: u32,
};

/// `markup` with every placeholder replaced by what was drawn for its component, at any
/// depth: `drawn[n]` is component `n`'s markup, which may only hold placeholders for
/// components before it. At most `bytes_max` bytes.
pub fn expand(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    markup: []const u8,
    drawn: []const []const u8,
    bytes_max: u32,
) Error!void {
    var stack: [depth_max * 2]Frame = undefined;
    var depth: u32 = 1;
    var replacements: u32 = 0;
    var written: u64 = 0;

    std.debug.assert(drawn.len <= view_wire.components_max);
    std.debug.assert(bytes_max > 0);

    stack[0] = .{
        .text = markup,
        .below = @intCast(drawn.len),
    };

    while (depth > 0) {
        const frame = &stack[depth - 1];
        const placed = try next_placed(frame.text, frame.at) orelse {
            written += frame.text.len - frame.at;

            if (written > bytes_max) {
                return error.Invalid;
            }

            writer.writeAll(frame.text[frame.at..]) catch return error.OutOfMemory;
            depth -= 1;
            continue;
        };

        written += placed.start - frame.at;
        replacements += 1;

        const refused = placed.number >= frame.below or replacements > replacements_max;

        if (refused or written > bytes_max or depth + 2 > stack.len) {
            return error.Invalid;
        }

        writer.writeAll(frame.text[frame.at..placed.start]) catch return error.OutOfMemory;
        frame.at = placed.tag.end;

        const html = drawn[placed.number];
        const parts = if (placed.tag.count > 1) try rooted(arena, html, &placed.tag) else null;

        // The rest first: the stack's top is what is written next.
        stack[depth] = .{
            .text = if (parts) |split| split.rest else html,
            .below = placed.number,
        };
        depth += 1;

        if (parts) |split| {
            stack[depth] = .{
                .text = split.head,
                .below = placed.number,
            };
            depth += 1;
        }
    }

    std.debug.assert(written <= bytes_max);
}

fn expanded(arena: std.mem.Allocator, markup: []const u8, drawn: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);

    try expand(arena, &out.writer, markup, drawn, 1 << 16);

    return out.written();
}

test "placeholders are replaced at any depth, attributes moved onto the root drawn" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const drawn = [_][]const u8{
        "<span class=\"text\">Tea</span>",
        "<td class=\"cell\" data-p-bind=\"a:$a\"><publr-drawn n=\"0\"></td>",
        "<publr-drawn n=\"1\" role=\"cell\">",
    };

    try std.testing.expectEqualStrings(
        "<tr><td class=\"cell\" data-p-bind=\"a:$a\"><span class=\"text\">Tea</span></td></tr>",
        try expanded(arena, "<tr><publr-drawn n=\"1\"></tr>", &drawn),
    );
    // A row's key, a class and a binding given again; a root that is a placeholder passes
    // them on.
    try std.testing.expectEqualStrings(
        "<td role=\"cell\" data-p-for-key=\"&quot;a&quot;\" class=\"cell wide\"" ++
            " data-p-bind=\"a:$a;b:$b\"><span class=\"text\">Tea</span></td>",
        try expanded(arena, "<publr-drawn data-p-for-key=\"&quot;a&quot;\" n=\"2\"" ++
            " class='wide' data-p-bind=\"b:$b\">", &drawn),
    );
    try std.testing.expectEqualStrings(
        "a<publr-drawn-more>b",
        try expanded(arena, "a<publr-drawn-more>b", &drawn),
    );
    // Markup with no element carries no attributes.
    try std.testing.expectEqualStrings("Tea", try expanded(arena, "<publr-drawn n=\"0\" " ++
        "hidden>", &.{"Tea"}));
}

test "a hostile page ends: no component, one drawn later, no end, too deep, too large" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn n=\"1\">", &.{"a"}));
    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn>", &.{"a"}));
    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn n=\"0\"", &.{"a"}));
    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn n=\"-1\">", &.{"a"}));
    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn n=\"0\">", &.{
        "<publr-drawn n=\"0\">",
    }));
    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn n=\"1\">", &.{
        "<publr-drawn n=\"1\">",
        "<publr-drawn n=\"0\">",
    }));

    // Each component names the one before it twice: the page's size ends it.
    var chain: [21][]const u8 = undefined;

    chain[0] = "0123456789abcdef";

    for (chain[1..], 1..) |*one, index| {
        one.* = try std.fmt.allocPrint(arena, "<publr-drawn n=\"{d}\"><publr-drawn n=\"{d}\">", .{
            index - 1,
            index - 1,
        });
    }

    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn n=\"20\">", &chain));

    // Nested past the depth a page may have.
    var deep: [depth_max * 2 + 2][]const u8 = undefined;

    deep[0] = "x";

    for (deep[1..], 1..) |*one, index| {
        one.* = try std.fmt.allocPrint(arena, "<publr-drawn n=\"{d}\">", .{index - 1});
    }

    try std.testing.expectError(error.Invalid, expanded(arena, "<publr-drawn n=\"129\">", &deep));
}
