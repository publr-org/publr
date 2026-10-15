const std = @import("std");
const leaf = @import("leaf.zig");

test "quote markers take one space after them" {
    try std.testing.expectEqualStrings("a", leaf.quote("> a").?);
    try std.testing.expectEqualStrings("a", leaf.quote("   >a").?);
    try std.testing.expectEqualStrings("> b", leaf.quote(">> b").?);
    try std.testing.expect(leaf.quote("    > a") == null);
    try std.testing.expect(leaf.quote("a > b") == null);
}

test "list items: bullets, numbers, the content's indent" {
    const bullet = leaf.item("- a").?;
    try std.testing.expect(!bullet.ordered);
    try std.testing.expectEqual(@as(u8, '-'), bullet.marker);
    try std.testing.expectEqual(@as(u32, 2), bullet.content_indent);
    try std.testing.expectEqualStrings("a", bullet.content);

    const numbered = leaf.item("  12) b").?;
    try std.testing.expect(numbered.ordered);
    try std.testing.expectEqual(@as(u32, 12), numbered.start);
    try std.testing.expectEqual(@as(u8, ')'), numbered.marker);
    try std.testing.expectEqual(@as(u32, 6), numbered.content_indent);

    const empty = leaf.item("*").?;
    try std.testing.expectEqualStrings("", empty.content);
    try std.testing.expectEqual(@as(u32, 2), empty.content_indent);

    try std.testing.expect(leaf.item("-a") == null);
    try std.testing.expect(leaf.item("1.a") == null);
    try std.testing.expect(leaf.item("1234567890. a") == null);
    try std.testing.expect(leaf.item("    - a") == null);
    try std.testing.expect(leaf.item("") == null);
}

test "rules, headings and fences" {
    try std.testing.expect(leaf.is_rule("---"));
    try std.testing.expect(leaf.is_rule(" * * *"));
    try std.testing.expect(!leaf.is_rule("--"));
    try std.testing.expect(!leaf.is_rule("-- a"));

    try std.testing.expectEqualStrings("Title", leaf.heading("## Title ##").?.text);
    try std.testing.expectEqual(@as(u32, 2), leaf.heading("## Title ##").?.level);
    try std.testing.expectEqualStrings("C#", leaf.heading("# C#").?.text);
    try std.testing.expect(leaf.heading("#tag") == null);
    try std.testing.expect(leaf.heading("####### seven") == null);

    const fence = leaf.fence_open("```zig title").?;
    try std.testing.expectEqualStrings("zig", fence.language);
    try std.testing.expect(leaf.fence_closes("````", fence));
    try std.testing.expect(!leaf.fence_closes("``", fence));
    try std.testing.expect(!leaf.fence_closes("~~~", fence));
    try std.testing.expect(leaf.fence_open("``` a`b") == null);
    try std.testing.expect(leaf.fence_open("~~") == null);
}

test "HTML blocks and what interrupts a paragraph" {
    try std.testing.expect(leaf.html_start("<details>"));
    try std.testing.expect(leaf.html_start("</div>"));
    try std.testing.expect(leaf.html_start("<!-- x -->"));
    try std.testing.expect(!leaf.html_start("< b"));
    try std.testing.expect(!leaf.html_start("<"));

    try std.testing.expect(leaf.starts_block("# h"));
    try std.testing.expect(leaf.starts_block("- a"));
    try std.testing.expect(!leaf.starts_block("-"));
    try std.testing.expect(!leaf.starts_block("plain"));
}

test "table rows split on pipes not escaped; delimiter rows are dashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const row = try leaf.cells(arena, "| a | b \\| c |  |");
    try std.testing.expectEqual(@as(usize, 3), row.len);
    try std.testing.expectEqualStrings("a", row[0]);
    try std.testing.expectEqualStrings("b \\| c", row[1]);
    try std.testing.expectEqualStrings("", row[2]);

    const bare = try leaf.cells(arena, "a|b\\");
    try std.testing.expectEqual(@as(usize, 2), bare.len);
    try std.testing.expectEqualStrings("b\\", bare[1]);

    try std.testing.expect(leaf.is_delimiter_row(try leaf.cells(arena, "|---|:-:|--:|")));
    try std.testing.expect(!leaf.is_delimiter_row(try leaf.cells(arena, "|---|text|")));
    try std.testing.expect(!leaf.is_delimiter_row(try leaf.cells(arena, "|:|")));
}
