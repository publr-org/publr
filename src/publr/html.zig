//! The one thing every HTML writer needs: escaping text so it cannot become markup.

const std = @import("std");

pub fn escape(writer: *std.Io.Writer, text: []const u8) error{OutOfMemory}!void {
    std.debug.assert(text.len <= 1 << 24);

    for (text) |char| {
        const piece: []const u8 = switch (char) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &.{char},
        };

        writer.writeAll(piece) catch return error.OutOfMemory;
    }
}

test "escape replaces the five characters that matter and leaves the rest" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try escape(&out.writer, "<a href=\"x\">Tom & 'Jerry'</a>");
    try std.testing.expectEqualStrings(
        "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;",
        out.written(),
    );
}
