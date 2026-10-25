//! `<script type="application/ld+json" set:json={value} />`: a script whose content is a
//! value written as JSON, such as a page's structured data. Any other script is copied as it
//! is written, with no `{expressions}` filled in, and HTML a field holds (`set:html`) never
//! carries a script, so this is the one way a page writes data into one. The JSON's `<`, `>`
//! and `&` are written as `\u003c`, `\u003e` and `\u0026`: a value can never close the
//! script or open another.
const std = @import("std");
const compile = @import("compile.zig");
const expression = @import("expression.zig");
const markup = @import("markup.zig");

const Compiler = compile.Compiler;
const Error = compile.Error;

const attribute = " set:json=";
const closing = "</script>";

/// Takes the `<script>` element `rest` starts with when it sets its content with
/// `set:json`: the tag without that attribute, the value, the closing tag. False, taking
/// nothing, for any other script.
pub fn take(compiler: *Compiler, rest: []const u8) Error!bool {
    std.debug.assert(markup.starts_with_tag(rest, "script"));

    const first_close = std.mem.indexOfScalar(u8, rest, '>') orelse return false;
    const at = std.mem.indexOf(u8, rest, attribute) orelse return false;

    // Only in the opening tag: what stands before the attribute has no `>` of its own.
    if (at > first_close) {
        return false;
    }

    const value_at: u32 = @intCast(at + attribute.len);

    if (value_at >= rest.len or rest[value_at] != '{') {
        return compiler.fail("set:json takes an {{expression}}", .{});
    }

    const value_end = value_at + try expression.expression_end(compiler, rest[value_at..], 0);
    const tag_end = std.mem.indexOfScalarPos(u8, rest, value_end + 1, '>') orelse {
        return compiler.fail("unterminated <script>", .{});
    };
    const self_closing = rest[tag_end - 1] == '/';
    const end: u32 = if (self_closing)
        @intCast(tag_end + 1)
    else
        try content_end(compiler, rest, @intCast(tag_end + 1));

    try compiler.static(rest[0..at]);
    try compiler.static(std.mem.trimEnd(u8, rest[value_end + 1 .. tag_end], "/ \t\r\n"));
    try compiler.static(">");
    try markup.write_raw(compiler, .{
        .expression = rest[value_at + 1 .. value_end],
        .kind = .json,
    });
    try compiler.static(closing);
    compiler.position += end;

    return true;
}

/// Where `</script>` ends, when nothing but whitespace stands before it: the value is the
/// whole content.
fn content_end(compiler: *Compiler, rest: []const u8, from: u32) Error!u32 {
    std.debug.assert(from <= rest.len);

    const close_at = std.mem.indexOfPos(u8, rest, from, closing) orelse {
        return compiler.fail("unterminated script", .{});
    };

    if (std.mem.trim(u8, rest[from..close_at], " \t\r\n").len > 0) {
        return compiler.fail("<script set:json> takes no content of its own", .{});
    }

    return @intCast(close_at + closing.len);
}

/// JSON text, as a script may hold it.
pub fn write_json(writer: *std.Io.Writer, json: []const u8) !void {
    std.debug.assert(json.len < 1 << 30);

    for (json) |byte| {
        switch (byte) {
            '<' => try writer.writeAll("\\u003c"),
            '>' => try writer.writeAll("\\u003e"),
            '&' => try writer.writeAll("\\u0026"),
            else => try writer.writeByte(byte),
        }
    }
}

/// A string value as a JSON string, as a script may hold it.
pub fn write_string(writer: *std.Io.Writer, text: []const u8) !void {
    std.debug.assert(text.len < 1 << 30);

    try writer.writeByte('"');

    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '<' => try writer.writeAll("\\u003c"),
            '>' => try writer.writeAll("\\u003e"),
            '&' => try writer.writeAll("\\u0026"),
            0...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }

    try writer.writeByte('"');
}

test "JSON in a script never closes it" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_json(&writer, "{\"name\":\"</script><b>&\"}");
    try std.testing.expectEqualStrings(
        "{\"name\":\"\\u003c/script\\u003e\\u003cb\\u003e\\u0026\"}",
        writer.buffered(),
    );

    var string_buffer: [64]u8 = undefined;
    var string_writer: std.Io.Writer = .fixed(&string_buffer);

    try write_string(&string_writer, "a \"b\" <c>");
    try std.testing.expectEqualStrings("\"a \\\"b\\\" \\u003cc\\u003e\"", string_writer.buffered());
}
