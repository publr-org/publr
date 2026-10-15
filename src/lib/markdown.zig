//! Markdown written as HTML: CommonMark's common core with GitHub's tables and
//! strikethrough. Read line by line against a stack of open quotes and lists, one leaf
//! block open at a time; inline text goes to `markdown/inline.zig`. No recursion; quotes
//! and lists together nest `depth_max` deep, deeper markers read as text. What a record
//! holds goes through `sanitize` after this; a page's own file does not.

const std = @import("std");
const escape = @import("markdown/escape.zig");
const inline_text = @import("markdown/inline.zig");
const leaf = @import("markdown/leaf.zig");

pub const Options = escape.Options;
pub const input_bytes_max: u32 = 4 << 20;
pub const depth_max: u32 = 16;
pub const Error = error{TooLong} || inline_text.Error;

const Writer = std.Io.Writer;
const tab_width: u32 = 4;

pub fn to_html(arena: std.mem.Allocator, input: []const u8, options: Options) Error![]const u8 {
    if (input.len > input_bytes_max) {
        return error.TooLong;
    }

    var out: Writer.Allocating = .init(arena);
    var builder: Builder = .{
        .arena = arena,
        .writer = &out.writer,
        .options = options,
    };
    var lines = std.mem.splitScalar(u8, input, '\n');

    while (lines.next()) |raw| {
        try builder.line(try expand_tabs(arena, std.mem.trimEnd(u8, raw, "\r")));
    }

    try builder.close_leaf();
    try builder.close_to(0);

    std.debug.assert(builder.depth == 0);

    return out.written();
}

/// Leading tabs read as four spaces, so indentation is counted in one unit.
fn expand_tabs(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    const lead = std.mem.indexOfNone(u8, line, " \t") orelse line.len;

    if (std.mem.indexOfScalar(u8, line[0..lead], '\t') == null) {
        return line;
    }

    var out: std.ArrayList(u8) = .empty;

    for (line[0..lead]) |char| {
        try out.appendNTimes(arena, ' ', if (char == '\t') tab_width else 1);
    }

    try out.appendSlice(arena, line[lead..]);

    std.debug.assert(out.items.len >= line.len);

    return out.items;
}

const Container = struct {
    kind: enum { quote, list },
    ordered: bool = false,
    marker: u8 = 0,
    content_indent: u32 = 0,
    /// Blocks written in the open item; its first paragraph goes without `<p>`.
    item_blocks: u32 = 0,
};

const Leaf = union(enum) {
    none,
    paragraph,
    fence: leaf.Fence,
    html,
    table: u32,
};

const Builder = struct {
    arena: std.mem.Allocator,
    writer: *Writer,
    options: Options,
    containers: [depth_max]Container = undefined,
    depth: u32 = 0,
    leaf: Leaf = .none,
    paragraph: std.ArrayList(u8) = .empty,
    paragraph_lines: u32 = 0,
    paragraph_bare: bool = false,
    /// A bare paragraph was the last thing written; the next block in its item starts on a
    /// line of its own.
    after_bare: bool = false,
    table_rows: u32 = 0,

    fn line(builder: *Builder, text: []const u8) Error!void {
        std.debug.assert(builder.depth <= depth_max);

        var rest = text;
        var matched: u32 = 0;

        while (matched < builder.depth) : (matched += 1) {
            rest = continued(builder.containers[matched], rest) orelse break;
        }

        if (try builder.continue_leaf(matched, rest)) {
            return;
        }

        rest = try builder.close_unmatched(matched, rest);
        rest = try builder.open_containers(rest);

        try builder.leaf_line(rest);

        std.debug.assert(builder.depth <= depth_max);
    }

    /// The line inside `container`, or null when the line leaves it.
    fn continued(container: Container, rest: []const u8) ?[]const u8 {
        if (container.kind == .quote) {
            return leaf.quote(rest);
        }

        if (leaf.is_blank(rest)) {
            return "";
        }

        if (leaf.indent(rest) < container.content_indent) {
            return null;
        }

        std.debug.assert(container.content_indent <= rest.len);

        return rest[container.content_indent..];
    }

    /// A fence's, an HTML block's or a table's next line, or a paragraph's lazy one; true
    /// when the line is taken.
    fn continue_leaf(builder: *Builder, matched: u32, rest: []const u8) Error!bool {
        const inside = matched == builder.depth;

        std.debug.assert(matched <= builder.depth);

        switch (builder.leaf) {
            .fence => |fence| {
                if (!inside or leaf.fence_closes(rest, fence)) {
                    try builder.close_leaf();
                    return inside;
                }

                const strip = @min(leaf.indent(rest), fence.indent);

                try escape.literal(builder.writer, rest[strip..], builder.options);
                try builder.writer.writeByte('\n');
                return true;
            },
            .html => {
                if (!inside or leaf.is_blank(rest)) {
                    builder.leaf = .none;
                    return inside;
                }

                try escape.raw(builder.writer, rest, builder.options);
                try builder.writer.writeByte('\n');
                return true;
            },
            .table => {
                const row = inside and !leaf.is_blank(rest) and
                    std.mem.indexOfScalar(u8, rest, '|') != null;

                if (!row) {
                    try builder.close_leaf();
                    return false;
                }

                try builder.table_row(rest, "td");
                return true;
            },
            .paragraph => {
                if (inside or leaf.starts_block(rest)) {
                    return false;
                }

                try builder.paragraph_line(rest);
                return true;
            },
            .none => return false,
        }
    }

    /// Closes what the line left; a list item at the level of the list it left starts
    /// the next item of that list instead. Returns what follows.
    fn close_unmatched(builder: *Builder, matched: u32, rest: []const u8) Error![]const u8 {
        if (matched == builder.depth) {
            return rest;
        }

        try builder.close_leaf();
        try builder.close_to(matched + 1);

        const list = &builder.containers[matched];
        const next = if (list.kind == .list and !leaf.is_rule(rest)) leaf.item(rest) else null;

        if (next) |found| {
            if (found.ordered == list.ordered and found.marker == list.marker) {
                builder.after_bare = false;
                try builder.writer.writeAll("</li>\n<li>");
                list.content_indent = found.content_indent;
                list.item_blocks = 0;
                return found.content;
            }
        }

        try builder.close_to(matched);

        std.debug.assert(builder.depth == matched);

        return rest;
    }

    fn open_containers(builder: *Builder, text: []const u8) Error![]const u8 {
        var rest = text;

        while (builder.depth < depth_max and !leaf.is_blank(rest)) {
            if (leaf.quote(rest)) |after| {
                try builder.open(.{
                    .kind = .quote,
                }, "<blockquote>\n");
                rest = after;
                continue;
            }

            const found = (if (leaf.is_rule(rest)) null else leaf.item(rest)) orelse break;
            const interrupts = found.content.len > 0 and (!found.ordered or found.start == 1);

            if (builder.leaf == .paragraph and !interrupts) {
                break;
            }

            try builder.open_list(found);
            rest = found.content;
        }

        std.debug.assert(builder.depth <= depth_max);

        return rest;
    }

    fn open_list(builder: *Builder, found: leaf.Item) Error!void {
        std.debug.assert(builder.depth < depth_max);

        const container: Container = .{
            .kind = .list,
            .ordered = found.ordered,
            .marker = found.marker,
            .content_indent = found.content_indent,
        };

        if (!found.ordered) {
            return builder.open(container, "<ul>\n<li>");
        }

        if (found.start == 1) {
            return builder.open(container, "<ol>\n<li>");
        }

        try builder.open(container, "");
        try builder.writer.print("<ol start=\"{d}\">\n<li>", .{found.start});
    }

    fn open(builder: *Builder, container: Container, tag: []const u8) Error!void {
        std.debug.assert(builder.depth < depth_max);

        try builder.close_leaf();
        try builder.note_block();
        builder.containers[builder.depth] = container;
        builder.depth += 1;
        try builder.writer.writeAll(tag);
    }

    /// Closes every container from the innermost down to `depth`.
    fn close_to(builder: *Builder, depth: u32) Error!void {
        std.debug.assert(depth <= builder.depth);

        builder.after_bare = false;

        while (builder.depth > depth) {
            builder.depth -= 1;

            const container = builder.containers[builder.depth];
            const tag = switch (container.kind) {
                .quote => "</blockquote>\n",
                .list => if (container.ordered) "</li>\n</ol>\n" else "</li>\n</ul>\n",
            };

            try builder.writer.writeAll(tag);
        }

        std.debug.assert(builder.depth == depth);
    }

    /// Counts a block in the open list item, when the innermost container is one.
    fn note_block(builder: *Builder) Error!void {
        if (builder.after_bare) {
            builder.after_bare = false;
            try builder.writer.writeByte('\n');
        }

        if (builder.depth == 0) {
            return;
        }

        const innermost = &builder.containers[builder.depth - 1];

        std.debug.assert(innermost.item_blocks < std.math.maxInt(u32));

        if (innermost.kind == .list) {
            innermost.item_blocks += 1;
        }
    }

    fn in_fresh_item(builder: *const Builder) bool {
        if (builder.depth == 0) {
            return false;
        }

        const innermost = builder.containers[builder.depth - 1];

        std.debug.assert(builder.depth <= depth_max);

        return innermost.kind == .list and innermost.item_blocks == 0;
    }

    fn leaf_line(builder: *Builder, rest: []const u8) Error!void {
        if (leaf.is_blank(rest)) {
            return builder.close_leaf();
        }

        if (builder.leaf == .paragraph) {
            if (builder.paragraph_lines == 1 and try builder.table_starts(rest)) {
                return;
            }

            // Quotes and the items that may interrupt it were opened already; HTML may not.
            const interrupts = leaf.heading(rest) != null or leaf.is_rule(rest) or
                leaf.fence_open(rest) != null;

            if (!interrupts) {
                return builder.paragraph_line(rest);
            }

            try builder.close_leaf();
        }

        std.debug.assert(builder.leaf == .none);

        try builder.block_line(rest);
    }

    fn block_line(builder: *Builder, rest: []const u8) Error!void {
        std.debug.assert(builder.leaf == .none);

        if (leaf.heading(rest)) |found| {
            try builder.note_block();
            try builder.writer.print("<h{d}>", .{found.level});
            try inline_text.write(builder.arena, builder.writer, found.text, builder.options);
            return builder.writer.print("</h{d}>\n", .{found.level});
        }

        if (leaf.is_rule(rest)) {
            try builder.note_block();
            return builder.writer.writeAll("<hr />\n");
        }

        if (leaf.fence_open(rest)) |fence| {
            try builder.note_block();
            builder.leaf = .{
                .fence = fence,
            };
            return builder.write_fence_open(fence);
        }

        if (leaf.html_start(rest)) {
            try builder.note_block();
            builder.leaf = .html;
            try escape.raw(builder.writer, std.mem.trimStart(u8, rest, " "), builder.options);
            return builder.writer.writeByte('\n');
        }

        builder.paragraph_bare = builder.in_fresh_item();
        try builder.note_block();
        builder.leaf = .paragraph;
        try builder.paragraph_line(rest);
    }

    fn write_fence_open(builder: *Builder, fence: leaf.Fence) Error!void {
        std.debug.assert(fence.len >= 3);

        if (fence.language.len == 0) {
            return builder.writer.writeAll("<pre><code>");
        }

        try builder.writer.writeAll("<pre><code class=\"language-");
        try escape.text(builder.writer, fence.language, builder.options);
        try builder.writer.writeAll("\">");
    }

    fn paragraph_line(builder: *Builder, rest: []const u8) Error!void {
        std.debug.assert(builder.leaf == .paragraph);

        if (builder.paragraph_lines > 0) {
            try builder.paragraph.append(builder.arena, '\n');
        }

        try builder.paragraph.appendSlice(builder.arena, std.mem.trimStart(u8, rest, " "));
        builder.paragraph_lines += 1;
    }

    /// A paragraph of one line followed by a delimiter row with as many cells is a table's
    /// header.
    fn table_starts(builder: *Builder, rest: []const u8) Error!bool {
        std.debug.assert(builder.paragraph_lines == 1);

        const header = try leaf.cells(builder.arena, builder.paragraph.items);
        const delimiters = try leaf.cells(builder.arena, rest);
        const piped = std.mem.indexOfScalar(u8, builder.paragraph.items, '|') != null;

        if (!piped or !leaf.is_delimiter_row(delimiters) or delimiters.len != header.len) {
            return false;
        }

        builder.leaf = .{
            .table = @intCast(header.len),
        };
        builder.table_rows = 0;
        try builder.writer.writeAll("<table>\n<thead>\n");
        try builder.table_row(builder.paragraph.items, "th");
        try builder.writer.writeAll("</thead>\n");
        builder.paragraph.clearRetainingCapacity();
        builder.paragraph_lines = 0;

        return true;
    }

    fn table_row(builder: *Builder, rest: []const u8, cell_tag: []const u8) Error!void {
        const columns = builder.leaf.table;
        const row = try leaf.cells(builder.arena, rest);

        std.debug.assert(columns > 0 and columns <= leaf.columns_max);

        if (std.mem.eql(u8, cell_tag, "td") and builder.table_rows == 0) {
            try builder.writer.writeAll("<tbody>\n");
        }

        try builder.writer.writeAll("<tr>\n");

        for (0..columns) |index| {
            try builder.writer.print("<{s}>", .{cell_tag});

            if (index < row.len) {
                try inline_text.write(builder.arena, builder.writer, row[index], builder.options);
            }

            try builder.writer.print("</{s}>\n", .{cell_tag});
        }

        try builder.writer.writeAll("</tr>\n");
        builder.table_rows += @intFromBool(std.mem.eql(u8, cell_tag, "td"));
    }

    fn close_leaf(builder: *Builder) Error!void {
        const closing = builder.leaf;

        builder.leaf = .none;

        switch (closing) {
            .none, .html => {},
            .fence => try builder.writer.writeAll("</code></pre>\n"),
            .table => {
                const body = if (builder.table_rows > 0) "</tbody>\n" else "";
                try builder.writer.print("{s}</table>\n", .{body});
            },
            .paragraph => try builder.write_paragraph(),
        }

        std.debug.assert(builder.leaf == .none);
    }

    fn write_paragraph(builder: *Builder) Error!void {
        const text = std.mem.trimEnd(u8, builder.paragraph.items, " \t");
        const bare = builder.paragraph_bare;

        std.debug.assert(builder.paragraph_lines > 0);

        if (!bare) {
            try builder.writer.writeAll("<p>");
        }

        try inline_text.write(builder.arena, builder.writer, text, builder.options);
        try builder.writer.writeAll(if (bare) "" else "</p>\n");

        builder.paragraph.clearRetainingCapacity();
        builder.paragraph_lines = 0;
        builder.paragraph_bare = false;
        builder.after_bare = bare;
    }
};

test {
    _ = @import("markdown/tests.zig");
    _ = @import("markdown/token.zig");
    _ = @import("markdown/spans.zig");
    _ = @import("markdown/emphasis.zig");
    _ = @import("markdown/link.zig");
    _ = @import("markdown/leaf.zig");
}
