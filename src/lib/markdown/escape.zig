//! Text and attribute values written so they cannot become markup. An entity the author
//! wrote (`&amp;`, `&#169;`) is kept; braces become entities when the output is a page's
//! source, where `{` would start an expression.

const std = @import("std");

pub const Options = struct {
    /// `{` and `}` written as `&#123;` and `&#125;`.
    braces_as_text: bool = false,
};

const Writer = std.Io.Writer;

const entity_len_max: u32 = 32;

pub fn text(writer: *Writer, input: []const u8, options: Options) Writer.Error!void {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    var index: u32 = 0;

    while (index < input.len) : (index += 1) {
        const char = input[index];

        if (char == '&' and entity_len(input[index..]) > 0) {
            try writer.writeByte('&');
            continue;
        }

        try write_char(writer, char, options);
    }

    std.debug.assert(index == input.len);
}

/// Like `text`, and every newline kept; for a code block.
pub fn literal(writer: *Writer, input: []const u8, options: Options) Writer.Error!void {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    for (input) |char| {
        try write_char(writer, char, options);
    }
}

/// Markup the author wrote, kept as it is, but for braces in a page's source.
pub fn raw(writer: *Writer, input: []const u8, options: Options) Writer.Error!void {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    if (!options.braces_as_text) {
        return writer.writeAll(input);
    }

    for (input) |char| {
        switch (char) {
            '{' => try writer.writeAll("&#123;"),
            '}' => try writer.writeAll("&#125;"),
            else => try writer.writeByte(char),
        }
    }

    std.debug.assert(options.braces_as_text);
}

fn write_char(writer: *Writer, char: u8, options: Options) Writer.Error!void {
    std.debug.assert(writer.buffer.len > 0 or writer.end == 0);

    const entity: ?[]const u8 = switch (char) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '{' => if (options.braces_as_text) "&#123;" else null,
        '}' => if (options.braces_as_text) "&#125;" else null,
        else => null,
    };

    if (entity) |text_entity| {
        return writer.writeAll(text_entity);
    }

    try writer.writeByte(char);
}

/// The length of the entity `input` starts with (`&name;`, `&#123;`, `&#x1F;`), else 0.
pub fn entity_len(input: []const u8) u32 {
    std.debug.assert(input.len > 0);
    std.debug.assert(input[0] == '&');

    var index: u32 = 1;
    const numeric = input.len > 1 and input[1] == '#';

    if (numeric) {
        index += 1;
    }

    const start = index;

    while (index < input.len and index < entity_len_max) : (index += 1) {
        const char = input[index];
        const allowed = std.ascii.isAlphanumeric(char);

        if (!allowed) {
            break;
        }
    }

    if (index == start or index >= input.len or input[index] != ';') {
        return 0;
    }

    return index + 1;
}

test "text escapes markup, keeps entities, and braces only for a page" {
    var buffer: [256]u8 = undefined;
    var writer: Writer = .fixed(&buffer);

    try text(&writer, "a < b & c &amp; {d} \"e\"", .{});
    try std.testing.expectEqualStrings(
        "a &lt; b &amp; c &amp; {d} &quot;e&quot;",
        writer.buffered(),
    );

    writer = .fixed(&buffer);
    try text(&writer, "{x} &#169; &#xA9; & ;", .{
        .braces_as_text = true,
    });
    try std.testing.expectEqualStrings("&#123;x&#125; &#169; &#xA9; &amp; ;", writer.buffered());

    writer = .fixed(&buffer);
    try raw(&writer, "<b class=\"{x}\">", .{
        .braces_as_text = true,
    });
    try std.testing.expectEqualStrings("<b class=\"&#123;x&#125;\">", writer.buffered());

    writer = .fixed(&buffer);
    try literal(&writer, "&amp; <\n", .{});
    try std.testing.expectEqualStrings("&amp;amp; &lt;\n", writer.buffered());
}

test "entity_len reads names and numbers only up to a semicolon" {
    try std.testing.expectEqual(@as(u32, 5), entity_len("&amp;"));
    try std.testing.expectEqual(@as(u32, 6), entity_len("&#169; x"));
    try std.testing.expectEqual(@as(u32, 0), entity_len("&amp"));
    try std.testing.expectEqual(@as(u32, 0), entity_len("& x;"));
    try std.testing.expectEqual(@as(u32, 0), entity_len("&#;"));
    try std.testing.expectEqual(@as(u32, 0), entity_len("&"));
}
