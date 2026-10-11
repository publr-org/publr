//! The document a plugin's page is served as inside the plugin frame: the design system's
//! stylesheet, the bridge, then whatever the plugin drew. Its policy sandboxes it whatever
//! opens it, so even opened on its own it runs with an opaque origin: no session, no reach
//! into the admin, nothing fetched from anywhere, framed only by the admin.
const std = @import("std");
const class_merge = @import("class_merge");

pub const policy = "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox; " ++
    "default-src 'none'; " ++
    "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " ++
    "img-src 'self' data:; font-src 'self'; connect-src 'none'; form-action 'none'; " ++
    "base-uri 'none'; frame-ancestors 'self'";

/// What the frame asks of the admin, by `postMessage` to its parent: run one of the
/// plugin's operations (`publr.call`), go to another of its pages (`publr.navigate`, or a
/// link clicked), and its height, so the frame grows with what it shows. A link to another
/// site opens in a new tab.
pub const bridge = @embedFile("bridge.js");

/// The frame's document: a whole page the plugin drew with the admin's layouts gets the
/// bridge first in its head; anything else is put in a document linking the stylesheet
/// under `base`.
pub fn write(writer: *std.Io.Writer, base: []const u8, html: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(base.len == 0 or base[0] == '/');
    std.debug.assert(std.mem.indexOfAny(u8, base, "\"<>&'") == null);

    if (head_end(html)) |at| {
        try write_named(writer, html[0..at]);
        try writer.print("<script>{s}</script>", .{bridge});
        try write_named(writer, html[at..]);

        return;
    }

    try writer.writeAll("<!doctype html><html lang=\"en\" class=\"");
    try write_own(writer, "bg-background");
    try writer.print(
        "\"><head>" ++
            "<meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
            "<link rel=\"stylesheet\" href=\"{s}/admin/styles.css\">" ++
            "<script>{s}</script></head><body class=\"",
        .{ base, bridge },
    );
    try write_own(writer, "bg-background text-foreground antialiased");
    try writer.writeAll("\">");
    try write_named(writer, html);
    try writer.writeAll("</body></html>");
}

/// The frame's own few classes, by their names.
fn write_own(writer: *std.Io.Writer, classes: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(classes.len > 0);

    class_merge.write_classes(writer, &.{classes}) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.TooManyClasses => unreachable,
    };
}

/// `html` with each `class` attribute's classes by the names the admin's stylesheet styles
/// them by: the plugin drew them with the design system's classes.
fn write_named(writer: *std.Io.Writer, html: []const u8) std.Io.Writer.Error!void {
    const opening = " class=\"";
    var rest = html;

    std.debug.assert(opening.len == 8);

    while (std.mem.indexOf(u8, rest, opening)) |at| {
        const value_start = at + opening.len;
        const value_end = std.mem.indexOfScalarPos(u8, rest, value_start, '"') orelse break;
        var buffer: [class_value_max]u8 = undefined;
        const value = unescaped(rest[value_start..value_end], &buffer) orelse {
            try writer.writeAll(rest[0 .. value_end + 1]);
            rest = rest[value_end + 1 ..];
            continue;
        };

        try writer.writeAll(rest[0..value_start]);
        class_merge.write_classes(writer, &.{value}) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            error.TooManyClasses => try writer.writeAll(rest[value_start..value_end]),
        };
        try writer.writeByte('"');
        rest = rest[value_end + 1 ..];
    }

    try writer.writeAll(rest);
}

const class_value_max = 4096;

/// An attribute value with its entities read; null when it is longer than `buffer`.
fn unescaped(value: []const u8, buffer: *[class_value_max]u8) ?[]const u8 {
    const Entity = struct {
        text: []const u8,
        char: u8,
    };
    const entities = [_]Entity{
        .{
            .text = "&amp;",
            .char = '&',
        },
        .{
            .text = "&lt;",
            .char = '<',
        },
        .{
            .text = "&gt;",
            .char = '>',
        },
        .{
            .text = "&quot;",
            .char = '"',
        },
        .{
            .text = "&#39;",
            .char = '\'',
        },
    };
    var len: usize = 0;
    var at: usize = 0;

    std.debug.assert(std.mem.indexOfScalar(u8, value, '"') == null);

    if (value.len > buffer.len) {
        return null;
    }

    while (at < value.len) {
        const entity = for (entities) |entry| {
            if (std.mem.startsWith(u8, value[at..], entry.text)) break entry;
        } else null;

        if (entity) |entry| {
            buffer[len] = entry.char;
            at += entry.text.len;
        } else {
            buffer[len] = value[at];
            at += 1;
        }

        len += 1;
    }

    return buffer[0..len];
}

/// Where a whole page's `<head>` opens ends: the bridge goes first in it.
fn head_end(html: []const u8) ?u32 {
    const doctype = "<!doctype html>";

    if (html.len < doctype.len or !std.ascii.eqlIgnoreCase(html[0..doctype.len], doctype)) {
        return null;
    }

    const head = std.mem.indexOf(u8, html, "<head>") orelse return null;

    std.debug.assert(head >= doctype.len);

    return @intCast(head + "<head>".len);
}

test "a whole page gets the bridge first in its head" {
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write(&writer, "", "<!doctype html>\n<html><head><title>T</title></head></html>");

    const text = writer.buffered();

    try std.testing.expect(std.mem.startsWith(u8, text, "<!doctype html>\n<html><head><script>"));
    try std.testing.expect(std.mem.indexOf(u8, text, "</script><title>T</title>") != null);
    try std.testing.expectEqual(@as(?u32, null), head_end("<p>no page</p>"));
}

test "the frame's document links the stylesheet under the base and carries the bridge" {
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write(&writer, "/env/staging", "<p>Hello</p>");

    const text = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "/env/staging/admin/styles.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window.publr") != null);
    try std.testing.expect(std.mem.endsWith(u8, bridge, "})();\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "<p>Hello</p></body></html>"));
}

test "a plugin's classes are written by the stylesheet's names" {
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var names: [64]u8 = undefined;
    var flex: std.Io.Writer = .fixed(&names);

    try class_merge.admin.write_class(&flex, "flex");
    try write(&writer, "", "<div class=\"flex hand-made\">x</div>");

    var expected: [64]u8 = undefined;
    const written = try std.fmt.bufPrint(
        &expected,
        "<div class=\"{s} hand-made\">",
        .{flex.buffered()},
    );

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), written) != null);
}

test "the frame's policy keeps it sandboxed, offline and framed only by the admin" {
    try std.testing.expect(std.mem.startsWith(u8, policy, "sandbox allow-scripts "));
    try std.testing.expect(std.mem.indexOf(u8, policy, "allow-same-origin") == null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "connect-src 'none'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "frame-ancestors 'self'") != null);
}
