const std = @import("std");
const markdown = @import("../markdown.zig");

fn expect_html(expected: []const u8, input: []const u8) !void {
    std.debug.assert(input.len <= markdown.input_bytes_max);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const html = try markdown.to_html(arena_state.allocator(), input, .{});

    try std.testing.expectEqualStrings(expected, html);
}

test "headings, paragraphs and rules" {
    try expect_html(
        "<h1>Title</h1>\n<p>One line\nand the next.</p>\n<hr />\n<h3>Small</h3>\n",
        "# Title\n\nOne line\nand the next.\n\n---\n### Small ###\n",
    );
    try expect_html("<p>a</p>\n<h2>b</h2>\n", "a\n## b");
    try expect_html("", "");
    try expect_html("", "\n\n  \n");
}

test "fenced code keeps its text and names its language" {
    try expect_html(
        "<pre><code class=\"language-zig\">const answer = 1 &lt; 2;\n\n  *kept*\n</code></pre>\n",
        "```zig\nconst answer = 1 < 2;\n\n  *kept*\n```\n",
    );
    try expect_html("<pre><code>open\n</code></pre>\n", "~~~\nopen");
    try expect_html("<p>a</p>\n<pre><code></code></pre>\n", "a\n```\n```");
}

test "lists: bullets, numbers with a start, nesting, items over several lines" {
    try expect_html("<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n", "- a\n- b");
    try expect_html(
        "<ol start=\"3\">\n<li>c</li>\n<li>d</li>\n</ol>\n",
        "3. c\n4. d",
    );
    try expect_html(
        "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n<li>c</li>\n</ul>\n",
        "- a\n  - b\n- c",
    );
    try expect_html("<ul>\n<li>a\nmore</li>\n</ul>\n", "- a\n  more");
    try expect_html("<ul>\n<li>a\nlazy</li>\n</ul>\n", "- a\nlazy");
    try expect_html(
        "<ul>\n<li>a\n<p>second</p>\n</li>\n</ul>\n<p>after</p>\n",
        "- a\n\n  second\n\nafter",
    );
    try expect_html("<ul>\n<li>a</li>\n</ul>\n<ol>\n<li>b</li>\n</ol>\n", "- a\n1. b");
    try expect_html("<p>The year\n2024. was long</p>\n", "The year\n2024. was long");
}

test "quotes nest and hold other blocks" {
    try expect_html(
        "<blockquote>\n<p>a\nb</p>\n<blockquote>\n<p>c</p>\n</blockquote>\n</blockquote>\n",
        "> a\nb\n> > c",
    );
    try expect_html(
        "<blockquote>\n<ul>\n<li>x</li>\n</ul>\n</blockquote>\n<p>y</p>\n",
        "> - x\n\ny",
    );
}

test "tables: header, rows, missing and extra cells" {
    try expect_html(
        "<table>\n<thead>\n<tr>\n<th>a</th>\n<th><em>b</em></th>\n</tr>\n</thead>\n" ++
            "<tbody>\n<tr>\n<td>1</td>\n<td></td>\n</tr>\n<tr>\n<td>2</td>\n<td>3</td>\n" ++
            "</tr>\n</tbody>\n</table>\n<p>after</p>\n",
        "| a | *b* |\n|---|:--|\n| 1 |\n| 2 | 3 | 4 |\nafter",
    );
    try expect_html(
        "<table>\n<thead>\n<tr>\n<th>a</th>\n</tr>\n</thead>\n</table>\n",
        "| a |\n| - |",
    );
    try expect_html("<p>a | b\n--- | --- | ---</p>\n", "a | b\n--- | --- | ---");
}

test "HTML blocks pass through until a blank line" {
    try expect_html(
        "<details>\n<summary>More</summary>\n<p>Text</p>\n",
        "<details>\n<summary>More</summary>\n\nText",
    );
    try expect_html("<p>a\n<b>c</b></p>\n", "a\n<b>c</b>");
}

test "tabs indent like four spaces; carriage returns go" {
    try expect_html("<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n", "- a\r\n\t- b\r\n");
}

test "quotes and lists deeper than the limit read as text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const deep = ">" ** (markdown.depth_max + 4) ++ " x";
    const html = try markdown.to_html(arena_state.allocator(), deep, .{});

    try std.testing.expectEqual(
        @as(usize, markdown.depth_max),
        std.mem.count(u8, html, "<blockquote>"),
    );
    try std.testing.expectEqual(
        std.mem.count(u8, html, "<blockquote>"),
        std.mem.count(u8, html, "</blockquote>"),
    );
}

test "input over the limit is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const long = try arena.alloc(u8, markdown.input_bytes_max + 1);
    @memset(long, 'a');

    try std.testing.expectError(error.TooLong, markdown.to_html(arena, long, .{}));
}

test "fuzz: any input converts with balanced containers" {
    try std.testing.fuzz({}, fuzz_one, .{
        .corpus = &.{
            "# a\n- b\n  > c\n\n```\nd\n```\n| e |\n|---|\n| f |\n",
            "1. a\n   - b\n\n   c\n2. d\n",
            "> > ***a** [b](c) ![d](e)*\n<div>\n",
        },
    });
}

fn fuzz_one(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const input = buffer[0..len];

    std.debug.assert(len <= buffer.len);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const html = try markdown.to_html(arena_state.allocator(), input, .{});
    const pairs = [_][2][]const u8{
        .{ "<blockquote>", "</blockquote>" },
        .{ "<ul>", "</ul>" },
        .{ "<ol", "</ol>" },
        .{ "<table>", "</table>" },
        .{ "<pre>", "</pre>" },
    };

    for (pairs) |pair| {
        try std.testing.expectEqual(
            std.mem.count(u8, html, pair[0]),
            std.mem.count(u8, html, pair[1]),
        );
    }
}
