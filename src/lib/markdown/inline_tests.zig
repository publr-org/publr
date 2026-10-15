const std = @import("std");
const inline_module = @import("inline.zig");

fn expect_inline(expected: []const u8, input: []const u8) !void {
    try expect_with(expected, input, .{});
}

fn expect_with(expected: []const u8, input: []const u8, options: inline_module.Options) !void {
    std.debug.assert(input.len <= std.math.maxInt(u32));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());

    try inline_module.write(arena_state.allocator(), &out.writer, input, options);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "emphasis, strong, both, and strikethrough" {
    try expect_inline("<em>a</em> <strong>b</strong>", "*a* **b**");
    try expect_inline("<em>a</em> <strong>b</strong>", "_a_ __b__");
    try expect_inline("<em><strong>a</strong></em>", "***a***");
    try expect_inline("<strong>a <em>b</em> c</strong>", "**a *b* c**");
    try expect_inline("<del>gone</del> ~kept~", "~~gone~~ ~kept~");
}

test "runs that open nothing stay text" {
    try expect_inline("a * b", "a * b");
    try expect_inline("snake_case_name", "snake_case_name");
    try expect_inline("*open", "*open");
    try expect_inline("2<em>3</em>4 = <em>x</em>", "2*3*4 = *x*");
    try expect_inline("*<em>a</em>", "**a*");
}

test "code spans keep what is inside them as text" {
    try expect_inline("<code>a *b* &lt;c&gt;</code>", "`a *b* <c>`");
    try expect_inline("<code>`</code>", "`` ` ``");
    try expect_inline("`lonely", "`lonely");
}

test "links, images, titles, and a link holding an image" {
    try expect_inline("<a href=\"/docs\">the <em>docs</em></a>", "[the *docs*](/docs)");
    try expect_inline(
        "<a href=\"https://x.y/?a=1&amp;b=2\" title=\"T\">x</a>",
        "[x](https://x.y/?a=1&b=2 \"T\")",
    );
    try expect_inline("<img src=\"/a.png\" alt=\"A cat\" />", "![A cat](/a.png)");
    try expect_inline(
        "<a href=\"/x\"><img src=\"/b.svg\" alt=\"b\" /></a>",
        "[![b](/b.svg)](/x)",
    );
    try expect_inline("[not a link] (x)", "[not a link] (x)");
    try expect_inline("[a <a href=\"/b\">b</a>", "[a [b](/b)");
}

test "emphasis does not pair across a link's edge" {
    try expect_inline("*a <a href=\"/u\">b* c</a>", "*a [b* c](/u)");
}

test "autolinks, inline tags, escapes, entities and breaks" {
    try expect_inline("<a href=\"https://x.y\">https://x.y</a>", "<https://x.y>");
    try expect_inline("<a href=\"mailto:me@x.y\">me@x.y</a>", "<me@x.y>");
    try expect_inline("a <kbd>K</kbd> b", "a <kbd>K</kbd> b");
    try expect_inline("1 &lt; 2 &gt; 0", "1 < 2 > 0");
    try expect_inline("*not* &amp; &copy;", "\\*not\\* & &copy;");
    try expect_inline("a<br />\nb", "a  \nb");
    try expect_inline("a<br />\nb", "a\\\nb");
    try expect_inline("a \nb", "a \nb");
}

test "braces are text in a page's source, in tags too" {
    try expect_with(
        "&#123;x&#125; <code>&#123;</code> <b title=\"&#123;\">",
        "{x} `{` <b title=\"{\">",
        .{
            .braces_as_text = true,
        },
    );
}

test "any input reads without failing and writes balanced tags" {
    const inputs = [_][]const u8{
        "",
        "*",
        "**",
        "***",
        "_",
        "[",
        "]",
        "[]",
        "[](",
        "[]()",
        "![",
        "![](",
        "<",
        ">",
        "<>",
        "`",
        "``",
        "\\",
        "~~",
        "~~~",
        "a**b**c",
        "[a](b",
        "[a](<b)",
        "*[a*](b)*",
        "[a](b \"c)",
        "<a@>",
        "&",
        "&#",
        "&#;",
        "  \n",
        "\n",
    };

    for (inputs) |input| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var out: std.Io.Writer.Allocating = .init(arena_state.allocator());

        try inline_module.write(arena_state.allocator(), &out.writer, input, .{});

        const written = out.written();
        const opened = std.mem.count(u8, written, "<em>") + std.mem.count(u8, written, "<strong>");
        const closed = std.mem.count(u8, written, "</em>") +
            std.mem.count(u8, written, "</strong>");

        try std.testing.expectEqual(opened, closed);
        try std.testing.expectEqual(
            std.mem.count(u8, written, "<a "),
            std.mem.count(u8, written, "</a>"),
        );
    }
}
