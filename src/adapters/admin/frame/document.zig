//! The document a plugin's page is served as inside the plugin frame: the design system's
//! stylesheet, the bridge, then whatever the plugin drew. Its policy sandboxes it whatever
//! opens it, so even opened on its own it runs with an opaque origin: no session, no reach
//! into the admin, nothing fetched from anywhere, framed only by the admin.
const std = @import("std");

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
        try writer.writeAll(html[0..at]);
        try writer.print("<script>{s}</script>", .{bridge});
        try writer.writeAll(html[at..]);

        return;
    }

    try writer.print(
        "<!doctype html><html lang=\"en\" class=\"bg-background\"><head>" ++
            "<meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++
            "<link rel=\"stylesheet\" href=\"{s}/admin/styles.css\">" ++
            "<script>{s}</script></head>" ++
            "<body class=\"bg-background text-foreground antialiased\">",
        .{ base, bridge },
    );
    try writer.writeAll(html);
    try writer.writeAll("</body></html>");
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

test "the frame's policy keeps it sandboxed, offline and framed only by the admin" {
    try std.testing.expect(std.mem.startsWith(u8, policy, "sandbox allow-scripts "));
    try std.testing.expect(std.mem.indexOf(u8, policy, "allow-same-origin") == null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "connect-src 'none'") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "frame-ancestors 'self'") != null);
}
