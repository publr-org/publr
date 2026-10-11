//! An app's design as data: the three system types its overrides are records of (a route's
//! template, a template part by name, a pattern by name), and a pattern file read into its
//! label, category and fragment. No database.

const std = @import("std");
const content_type = @import("content_type.zig");

pub const pattern_settings = @import("design/pattern.zig");

pub const template_handle = "template";
pub const part_handle = "template_part";
pub const pattern_handle = "pattern";
pub const moodboard_handle = "moodboard_item";
pub const name_len_max: u32 = 64;

/// A route's template: what the editor reopens, and what the route's pages print.
pub const template_def: content_type.Def = .{
    .handle = template_handle,
    .name = "Template",
    .description = "A route's template, edited in the block editor; live once published.",
    .icon = "layout",
    .system = true,
    .owner = "publr",
    .title_field = "route",
    .fields = &.{
        .{
            .name = "route",
            .label = "Route",
            .kind = "string",
            .required = true,
        },
        .{
            .name = "html",
            .label = "Editor HTML",
            .kind = "text",
        },
        .{
            .name = "output",
            .label = "Output",
            .kind = "text",
        },
    },
};

/// A template part placed by name (a header, a footer), shared by every page placing it.
pub const part_def: content_type.Def = .{
    .handle = part_handle,
    .name = "Template part",
    .description = "A part every page placing it by name shows; live once published.",
    .icon = "layout",
    .system = true,
    .owner = "publr",
    .title_field = "name",
    .fields = &.{
        .{
            .name = "name",
            .label = "Name",
            .kind = "string",
            .required = true,
        },
        .{
            .name = "label",
            .label = "Label",
            .kind = "string",
        },
        .{
            .name = "html",
            .label = "Editor HTML",
            .kind = "text",
        },
        .{
            .name = "output",
            .label = "Output",
            .kind = "text",
        },
    },
};

/// A starting point copied into a page: editing a placed copy changes only that page.
pub const pattern_def: content_type.Def = .{
    .handle = pattern_handle,
    .name = "Pattern",
    .description = "A starting point the block editor copies into a page.",
    .icon = "layout",
    .system = true,
    .owner = "publr",
    .title_field = "name",
    .fields = &.{
        .{
            .name = "name",
            .label = "Name",
            .kind = "string",
            .required = true,
        },
        .{
            .name = "label",
            .label = "Label",
            .kind = "string",
        },
        .{
            .name = "category",
            .label = "Category",
            .kind = "string",
        },
        .{
            .name = "description",
            .label = "Description",
            .kind = "string",
        },
        .{
            .name = "html",
            .label = "Editor HTML",
            .kind = "text",
        },
        .{
            .name = "variants",
            .label = "Variants",
            .kind = "repeater",
            .fields = &.{
                .{
                    .name = "name",
                    .label = "Name",
                    .kind = "string",
                    .required = true,
                },
                .{
                    .name = "label",
                    .label = "Label",
                    .kind = "string",
                    .required = true,
                },
                .{
                    .name = "description",
                    .label = "Description",
                    .kind = "string",
                },
                .{
                    .name = "html",
                    .label = "Editor HTML",
                    .kind = "text",
                },
            },
        },
        .{
            .name = "default_variant",
            .label = "Default variant",
            .kind = "string",
        },
        .{
            .name = "default_color_context",
            .label = "Default color context",
            .kind = "string",
        },
        .{
            .name = "disabled_color_contexts",
            .label = "Disabled color contexts",
            .kind = "string",
            .many = true,
        },
    },
};

/// One card on an app's moodboard: what it shows (by `kind`) and where it sits.
pub const moodboard_def: content_type.Def = .{
    .handle = moodboard_handle,
    .name = "Moodboard item",
    .description = "A card on an app's moodboard: a note, a link, an image, a color, a " ++
        "font or a Figma frame, with why it is there.",
    .icon = "pattern",
    .system = true,
    .owner = "publr",
    .title_field = "kind",
    .fields = &.{
        .{
            .name = "kind",
            .label = "Kind",
            .kind = "string",
            .required = true,
        },
        .{
            .name = "x",
            .label = "Across",
            .kind = "number",
        },
        .{
            .name = "y",
            .label = "Down",
            .kind = "number",
        },
        .{
            .name = "w",
            .label = "Width",
            .kind = "number",
        },
        .{
            .name = "h",
            .label = "Height",
            .kind = "number",
        },
        .{
            .name = "note",
            .label = "Why",
            .kind = "text",
        },
        .{
            .name = "text",
            .label = "Text",
            .kind = "text",
        },
        .{
            .name = "url",
            .label = "Address",
            .kind = "string",
        },
        .{
            .name = "src",
            .label = "Source",
            .kind = "string",
        },
        .{
            .name = "value",
            .label = "Value",
            .kind = "string",
        },
        .{
            .name = "title",
            .label = "Title",
            .kind = "string",
        },
        .{
            .name = "alt",
            .label = "Alt text",
            .kind = "string",
        },
        .{
            .name = "family",
            .label = "Family",
            .kind = "string",
        },
        .{
            .name = "file",
            .label = "File",
            .kind = "string",
        },
        .{
            .name = "weight",
            .label = "Weight",
            .kind = "number",
        },
        .{
            .name = "weight_max",
            .label = "Heaviest weight",
            .kind = "number",
        },
        .{
            .name = "italic",
            .label = "Italic",
            .kind = "boolean",
        },
        .{
            .name = "thumbnail",
            .label = "Thumbnail",
            .kind = "string",
        },
        .{
            .name = "status",
            .label = "Status",
            .kind = "string",
        },
        .{
            .name = "error",
            .label = "Error",
            .kind = "string",
        },
        .{
            .name = "colors",
            .label = "Colors",
            .kind = "string",
            .many = true,
        },
        .{
            .name = "fonts",
            .label = "Fonts",
            .kind = "string",
            .many = true,
        },
    },
};

pub const defs = [_]content_type.Def{ template_def, part_def, pattern_def, moodboard_def };

pub const moodboard_kinds = [_][]const u8{ "note", "link", "image", "color", "font", "figma" };
pub const token_name_len_max: u32 = 64;
pub const token_value_len_max: u32 = 512;
pub const font_len_max: u32 = 512;

/// A design token's name: lowercase letters, digits and `-`, starting with a letter.
pub fn valid_token_name(name: []const u8) bool {
    std.debug.assert(token_name_len_max > 0);

    if (name.len == 0 or name.len > token_name_len_max or !std.ascii.isLower(name[0])) {
        return false;
    }

    for (name) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') {
            return false;
        }
    }

    return true;
}

/// A token's value: one CSS value, nothing that ends a declaration or a block.
pub fn valid_token_value(value: []const u8) bool {
    std.debug.assert(token_value_len_max > 0);

    if (value.len == 0 or value.len > token_value_len_max) {
        return false;
    }

    return std.mem.indexOfAny(u8, value, ";{}\r\n<") == null;
}

/// A font: a family on one line, and a stylesheet served over `https://`.
pub fn valid_font(family: []const u8, url: []const u8) bool {
    std.debug.assert(font_len_max > 0);

    if (family.len == 0 or family.len > font_len_max or url.len > font_len_max) {
        return false;
    }

    if (std.mem.indexOfAny(u8, family, ";{}\r\n<>\"") != null) {
        return false;
    }

    const host_start = "https://".len;

    if (!std.mem.startsWith(u8, url, "https://") or url.len == host_start) {
        return false;
    }

    return std.mem.indexOfAny(u8, url, " \t\r\n\"'<>\\`") == null;
}

/// A font family's name: one line, nothing that could end a CSS string or rule.
pub fn valid_font_family(family: []const u8) bool {
    std.debug.assert(font_len_max > 0);
    std.debug.assert(family.len < 1 << 24);

    if (family.len == 0 or family.len > font_len_max) {
        return false;
    }

    return std.mem.indexOfAny(u8, family, ";{}\r\n<>\"\\") == null;
}

/// A hosted face's file: a path on this site (the media library) or `https://`, and
/// nothing that could end the rule it is written into.
pub fn valid_font_face(src: []const u8, weight_min: u32, weight_max: u32) bool {
    std.debug.assert(font_len_max > 0);
    std.debug.assert(src.len < 1 << 24);

    if (src.len < 2 or src.len > font_len_max or weight_min > weight_max or weight_max > 1000) {
        return false;
    }

    if (std.mem.indexOfAny(u8, src, " \t\r\n\"'<>\\`(){};") != null) {
        return false;
    }

    return (src[0] == '/' and src[1] != '/') or std.mem.startsWith(u8, src, "https://");
}

/// Whether a content type is one of the design's: its records are kept out of Content.
pub fn is_design(handle: []const u8) bool {
    std.debug.assert(defs.len == 4);

    for (defs) |def| {
        if (std.mem.eql(u8, def.handle, handle)) {
            return true;
        }
    }

    std.debug.assert(handle.len == 0 or !std.mem.eql(u8, handle, template_handle));

    return false;
}

/// A part's or a pattern's name: letters, digits, `-` and `_`, up to `name_len_max`.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    for (name) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '-' or char == '_';

        if (!allowed) {
            return false;
        }
    }

    std.debug.assert(name.len <= name_len_max);

    return true;
}

/// A pattern file: a `---` header of `key: value` lines, then the fragment.
pub const Pattern = struct {
    label: []const u8 = "",
    category: []const u8 = "",
    description: []const u8 = "",
    html: []const u8,
};

pub const header_lines_max: u32 = 32;

/// The header read and the fragment after it; a file without a header is all fragment.
pub fn parse_pattern(source: []const u8) Pattern {
    std.debug.assert(header_lines_max > 0);

    const fence = "---";
    const opened = std.mem.startsWith(u8, source, fence ++ "\n") or
        std.mem.startsWith(u8, source, fence ++ "\r\n");

    if (!opened) {
        return .{
            .html = std.mem.trim(u8, source, " \t\r\n"),
        };
    }

    var pattern: Pattern = .{
        .html = "",
    };
    var lines = std.mem.splitScalar(u8, source, '\n');
    var count: u32 = 0;

    _ = lines.first();

    while (lines.next()) |raw| : (count += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");

        if (std.mem.eql(u8, line, fence) or count == header_lines_max) {
            pattern.html = std.mem.trim(u8, lines.rest(), " \t\r\n");

            return pattern;
        }

        header_line(&pattern, line);
    }

    std.debug.assert(pattern.html.len == 0);

    return pattern;
}

fn header_line(pattern: *Pattern, line: []const u8) void {
    std.debug.assert(line.len <= 1 << 20);

    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

    std.debug.assert(colon < line.len);

    if (std.mem.eql(u8, key, "label")) {
        pattern.label = value;
    } else if (std.mem.eql(u8, key, "category")) {
        pattern.category = value;
    } else if (std.mem.eql(u8, key, "description")) {
        pattern.description = value;
    }
}

test {
    _ = pattern_settings;
}

test "is_design: the three design types and nothing else" {
    try std.testing.expect(is_design("template"));
    try std.testing.expect(is_design("template_part"));
    try std.testing.expect(is_design("pattern"));
    try std.testing.expect(is_design("moodboard_item"));
    try std.testing.expect(!is_design("templates"));
    try std.testing.expect(!is_design("media"));
    try std.testing.expect(!is_design(""));
}

test "valid_name: plain names only" {
    try std.testing.expect(valid_name("header"));
    try std.testing.expect(valid_name("site-footer_2"));
    try std.testing.expect(!valid_name(""));
    try std.testing.expect(!valid_name("a b"));
    try std.testing.expect(!valid_name("../x"));
    try std.testing.expect(!valid_name("x\"y"));
    try std.testing.expect(!valid_name("x" ** (name_len_max + 1)));
}

test "parse_pattern: header, fragment, and files without either" {
    const read = parse_pattern(
        \\---
        \\label: Hero
        \\category: Banners
        \\description: A big opening
        \\unknown: ignored
        \\---
        \\<section><h1>Hi</h1></section>
        \\
    );

    try std.testing.expectEqualStrings("Hero", read.label);
    try std.testing.expectEqualStrings("Banners", read.category);
    try std.testing.expectEqualStrings("A big opening", read.description);
    try std.testing.expectEqualStrings("<section><h1>Hi</h1></section>", read.html);

    const bare = parse_pattern("  <p>Only a fragment</p>\n");

    try std.testing.expectEqualStrings("<p>Only a fragment</p>", bare.html);
    try std.testing.expectEqualStrings("", bare.label);

    const unclosed = parse_pattern("---\nlabel: Lost\n<p>never closed</p>");

    try std.testing.expectEqualStrings("", unclosed.html);
    try std.testing.expectEqualStrings("Lost", unclosed.label);

    const windows = parse_pattern("---\r\nlabel: Crlf\r\n---\r\n<p>x</p>\r\n");

    try std.testing.expectEqualStrings("Crlf", windows.label);
    try std.testing.expectEqualStrings("<p>x</p>", windows.html);
}

test "tokens and fonts: what a stylesheet and a page head can take" {
    try std.testing.expect(valid_token_name("color-primary"));
    try std.testing.expect(valid_token_name("text-2xl"));
    try std.testing.expect(!valid_token_name("Color"));
    try std.testing.expect(!valid_token_name("2xl"));
    try std.testing.expect(!valid_token_name("color_primary"));
    try std.testing.expect(!valid_token_name(""));
    try std.testing.expect(valid_token_value("var(--color-brand)"));
    try std.testing.expect(valid_token_value("'Iowan Old Style', serif"));
    try std.testing.expect(!valid_token_value("red; } body { color: red"));
    try std.testing.expect(!valid_token_value("red\nblue"));
    try std.testing.expect(!valid_token_value(""));
    try std.testing.expect(valid_font("Inter", "https://fonts.googleapis.com/css2?family=Inter"));
    try std.testing.expect(!valid_font("Inter", "http://fonts.googleapis.com/css2?family=Inter"));
    try std.testing.expect(!valid_font("Inter", "https://x.test/a\"><script>"));
    try std.testing.expect(!valid_font("Inter", "https://"));
    try std.testing.expect(!valid_font("", "https://x.test/a.css"));
    try std.testing.expect(!valid_font("In}ter", "https://x.test/a.css"));
}
