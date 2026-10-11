//! What a model writes, as the conversation shows it: the Markdown it uses, read into blocks
//! (paragraphs, headings, bulleted and numbered items) of runs (plain, bold, italic, code).
//! Data, drawn by the page with the design system's text, never HTML.

const std = @import("std");

pub const blocks_max: u32 = 256;
pub const runs_max: u32 = 1024;

pub const Run = struct {
    text: []const u8,
    /// `plain`, `bold`, `italic` or `code`.
    style: []const u8,
};

pub const Block = struct {
    /// `paragraph`, `heading`, `bullet` or `numbered`.
    kind: []const u8,
    /// A numbered item's number; 0 for any other block.
    number: u32 = 0,
    runs: []const Run,
};

/// `text` read into blocks. A line starting `- ` or `* ` is a bulleted item, `1. ` a
/// numbered one, `# ` a heading; lines run together into a paragraph until a blank line.
pub fn read(arena: std.mem.Allocator, text: []const u8) ![]const Block {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(blocks_max > 0);

    var blocks: std.ArrayList(Block) = .empty;
    var paragraph: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |raw| {
        if (blocks.items.len >= blocks_max) {
            break;
        }

        const line = std.mem.trim(u8, raw, " \t\r");
        const item = item_of(line);

        if (line.len == 0 or item != null) {
            try end_paragraph(arena, &blocks, &paragraph);
        }

        if (item) |found| {
            try blocks.append(arena, .{
                .kind = found.kind,
                .number = found.number,
                .runs = try runs_of(arena, found.text),
            });
        } else if (line.len > 0) {
            if (paragraph.items.len > 0) {
                try paragraph.append(arena, ' ');
            }

            try paragraph.appendSlice(arena, line);
        }
    }

    try end_paragraph(arena, &blocks, &paragraph);

    return blocks.items;
}

fn end_paragraph(
    arena: std.mem.Allocator,
    blocks: *std.ArrayList(Block),
    paragraph: *std.ArrayList(u8),
) !void {
    std.debug.assert(blocks.items.len <= blocks_max);

    if (paragraph.items.len == 0) {
        return;
    }

    const text = try arena.dupe(u8, paragraph.items);

    try blocks.append(arena, .{
        .kind = "paragraph",
        .runs = try runs_of(arena, text),
    });
    paragraph.clearRetainingCapacity();
}

const Item = struct {
    kind: []const u8,
    number: u32 = 0,
    text: []const u8,
};

/// A heading, a bulleted or a numbered item, with its text; null for any other line.
fn item_of(line: []const u8) ?Item {
    std.debug.assert(line.len <= std.math.maxInt(u32));

    if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
        return .{
            .kind = "bullet",
            .text = line[2..],
        };
    }

    if (std.mem.startsWith(u8, line, "#")) {
        const level = std.mem.indexOfNone(u8, line, "#") orelse return null;

        if (level <= 4 and level < line.len and line[level] == ' ') {
            return .{
                .kind = "heading",
                .text = line[level + 1 ..],
            };
        }

        return null;
    }

    const digits = std.mem.indexOfNone(u8, line, "0123456789") orelse return null;
    const numbered = digits > 0 and digits <= 3 and line.len > digits + 1 and
        line[digits] == '.' and line[digits + 1] == ' ';

    if (!numbered) {
        return null;
    }

    const number = std.fmt.parseInt(u32, line[0..digits], 10) catch return null;

    return .{
        .kind = "numbered",
        .number = number,
        .text = line[digits + 2 ..],
    };
}

/// A line's runs: `code`, **bold**, *italic* or _italic_, and plain text between. A marker
/// left open is plain text.
fn runs_of(arena: std.mem.Allocator, text: []const u8) ![]const Run {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(runs_max > 0);

    var runs: std.ArrayList(Run) = .empty;
    var plain_start: u32 = 0;
    var index: u32 = 0;

    while (index < text.len and runs.items.len + 2 < runs_max) {
        const found = marked_at(text, index) orelse {
            index += 1;
            continue;
        };

        if (index > plain_start) {
            try runs.append(arena, .{
                .text = text[plain_start..index],
                .style = "plain",
            });
        }

        try runs.append(arena, .{
            .text = found.text,
            .style = found.style,
        });
        index = found.end;
        plain_start = index;
    }

    if (plain_start < text.len) {
        try runs.append(arena, .{
            .text = text[plain_start..],
            .style = "plain",
        });
    }

    return runs.items;
}

const Marked = struct {
    text: []const u8,
    style: []const u8,
    end: u32,
};

fn marked_at(text: []const u8, index: u32) ?Marked {
    std.debug.assert(index < text.len);

    const markers = [_]struct {
        open: []const u8,
        style: []const u8,
    }{
        .{
            .open = "`",
            .style = "code",
        },
        .{
            .open = "**",
            .style = "bold",
        },
        .{
            .open = "*",
            .style = "italic",
        },
        .{
            .open = "_",
            .style = "italic",
        },
    };

    for (markers) |marker| {
        if (!std.mem.startsWith(u8, text[index..], marker.open)) {
            continue;
        }

        const start = index + marker.open.len;
        const close = std.mem.indexOfPos(u8, text, start, marker.open) orelse return null;

        // `_` inside a word (`snake_case`) is not emphasis, and nothing empty is marked.
        const in_word = marker.open[0] == '_' and index > 0 and
            std.ascii.isAlphanumeric(text[index - 1]);

        if (close == start or in_word) {
            return null;
        }

        const end: u32 = @intCast(close + marker.open.len);

        return .{
            .text = text[start..close],
            .style = marker.style,
            .end = end,
        };
    }

    return null;
}

test "a reply reads into paragraphs, lists and headings with their emphasis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const text =
        \\I haven't built anything yet.
        \\**What I need from you:**
        \\
        \\1. **What the site is for:** a shop, or a farm.
        \\2. Where it goes: replace `/` or keep `/customers`.
        \\- A *Page* type
        \\## Next
        \\Keep snake_case_names as they are.
    ;
    const blocks = try read(arena_state.allocator(), text);

    try std.testing.expectEqual(@as(usize, 6), blocks.len);
    try std.testing.expectEqualStrings("paragraph", blocks[0].kind);
    try std.testing.expectEqualStrings("bold", blocks[0].runs[1].style);
    try std.testing.expectEqualStrings("numbered", blocks[1].kind);
    try std.testing.expectEqual(@as(u32, 2), blocks[2].number);
    try std.testing.expectEqualStrings("code", blocks[2].runs[1].style);
    try std.testing.expectEqualStrings("/", blocks[2].runs[1].text);
    try std.testing.expectEqualStrings("italic", blocks[3].runs[1].style);
    try std.testing.expectEqualStrings("heading", blocks[4].kind);
    try std.testing.expectEqual(@as(usize, 1), blocks[5].runs.len);
}
