//! An app's design system beyond its tokens: the structure the design system builder edits
//! over them. The semantic color roles and the contexts they repeat in, the web fonts
//! behind the `font-*` tokens, the type scale, the approved icons and the blocks' starting
//! documents. Kept as `<app>/design/system.zon`; the tokens stay in `app.zon`.

const std = @import("std");
const design = @import("../design.zig");

pub const file_name = "design/system.zon";
pub const roles_max: u32 = 64;
pub const contexts_max: u32 = 16;
pub const fonts_max: u32 = 32;
pub const faces_max: u32 = 32;
pub const weights_max: u32 = 9;
pub const styles_max: u32 = 64;
pub const icons_max: u32 = 512;
pub const managed_max: u32 = 1024;
pub const block_defaults_max: u32 = 64;
pub const key_len_max: u32 = 64;
pub const label_len_max: u32 = 128;
pub const description_len_max: u32 = 512;
pub const svg_len_max: u32 = 16 * 1024;
pub const html_len_max: u32 = 64 * 1024;

pub const Role = struct {
    key: []const u8,
    label: []const u8,
    description: []const u8 = "",
};

pub const Context = struct {
    key: []const u8,
    label: []const u8,
};

/// One hosted face: a weight (or a variable range, `weight_min` < `weight_max`) and style.
pub const Face = struct {
    weight_min: u32,
    weight_max: u32,
    italic: bool = false,
    src: []const u8,
};

/// Where a family comes from: Google Fonts, files the site hosts, or the visitor's device.
pub const Font = struct {
    token: []const u8,
    family: []const u8,
    fallback: []const u8 = "sans-serif",
    provider: []const u8,
    weights: []const u32 = &.{},
    italic: bool = false,
    available_weights: []const u32 = &.{},
    available_italic: bool = false,
    faces: []const Face = &.{},
};

/// A named text style riding a font role; sizes are token keys or literal lengths.
pub const Style = struct {
    key: []const u8,
    label: []const u8,
    font_role: []const u8,
    weight: u32 = 400,
    size: []const u8,
    line_height: []const u8 = "",
    letter_spacing: []const u8 = "",
    text_transform: []const u8 = "",
    description: []const u8 = "",
};

pub const Icon = struct {
    name: []const u8,
    label: []const u8,
    category: []const u8,
    svg: []const u8,
};

pub const BlockDefault = struct {
    block: []const u8,
    html: []const u8,
};

pub const System = struct {
    roles: []const Role = &.{},
    contexts: []const Context = &.{},
    fonts: []const Font = &.{},
    type_scale: []const Style = &.{},
    icons: []const Icon = &.{},
    managed_color_tokens: []const []const u8 = &.{},
    block_defaults: []const BlockDefault = &.{},
};

const providers = [_][]const u8{ "google", "files", "system" };
const fallbacks = [_][]const u8{ "sans-serif", "serif", "monospace", "cursive" };
const transforms = [_][]const u8{ "", "uppercase", "lowercase", "capitalize" };

/// Whether a document fits: every list within its bound, every key a token name, every
/// text on one line, fonts and faces from places a page may load, icons plain SVG.
pub fn valid(system: System) bool {
    std.debug.assert(roles_max > 0 and icons_max > 0);
    std.debug.assert(system.roles.len < 1 << 24);

    const sized = system.roles.len <= roles_max and system.contexts.len <= contexts_max and
        system.fonts.len <= fonts_max and system.type_scale.len <= styles_max and
        system.icons.len <= icons_max and system.managed_color_tokens.len <= managed_max and
        system.block_defaults.len <= block_defaults_max;

    if (!sized) {
        return false;
    }

    for (system.roles) |role| {
        if (!key(role.key) or !text(role.label, label_len_max)) {
            return false;
        }

        if (!text(role.description, description_len_max)) {
            return false;
        }
    }

    for (system.contexts) |context| {
        if (!key(context.key) or !text(context.label, label_len_max)) {
            return false;
        }
    }

    for (system.managed_color_tokens) |name| {
        if (!design.valid_token_name(name)) {
            return false;
        }
    }

    return valid_fonts(system.fonts) and valid_styles(system.type_scale) and
        valid_icons(system.icons) and valid_block_defaults(system.block_defaults);
}

fn valid_fonts(fonts: []const Font) bool {
    std.debug.assert(fonts.len <= fonts_max);
    std.debug.assert(faces_max > 0);

    for (fonts) |font| {
        const known = one_of(&providers, font.provider) and one_of(&fallbacks, font.fallback);
        const counts = font.weights.len <= weights_max and font.faces.len <= faces_max and
            font.available_weights.len <= weights_max;

        if (!known or !counts or !design.valid_token_name(font.token)) {
            return false;
        }

        if (!text(font.family, design.font_len_max) or font.family.len == 0) {
            return false;
        }

        if (!weights(font.weights) or !weights(font.available_weights)) {
            return false;
        }

        for (font.faces) |face| {
            if (face.weight_min > face.weight_max or face.weight_max > 1000) {
                return false;
            }

            if (!source(face.src)) {
                return false;
            }
        }
    }

    return true;
}

fn valid_styles(styles: []const Style) bool {
    std.debug.assert(styles.len <= styles_max);
    std.debug.assert(transforms.len == 4);

    for (styles) |style| {
        if (!key(style.key) or !key(style.font_role)) {
            return false;
        }

        if (!text(style.label, label_len_max) or !text(style.description, description_len_max)) {
            return false;
        }

        if (style.weight < 100 or style.weight > 900) {
            return false;
        }

        if (!length(style.size) or style.size.len == 0) {
            return false;
        }

        if (!length(style.line_height) or !length(style.letter_spacing)) {
            return false;
        }

        if (!one_of(&transforms, style.text_transform)) {
            return false;
        }
    }

    return true;
}

fn valid_icons(icons: []const Icon) bool {
    std.debug.assert(icons.len <= icons_max);
    std.debug.assert(svg_len_max > 0);

    for (icons) |icon| {
        if (!key(icon.name) or !text(icon.label, label_len_max)) {
            return false;
        }

        if (!text(icon.category, label_len_max) or !svg(icon.svg)) {
            return false;
        }
    }

    return true;
}

fn valid_block_defaults(defaults: []const BlockDefault) bool {
    std.debug.assert(defaults.len <= block_defaults_max);
    std.debug.assert(html_len_max > 0);

    for (defaults) |entry| {
        if (!key(entry.block) or entry.html.len == 0 or entry.html.len > html_len_max) {
            return false;
        }

        if (contains_folded(entry.html, "<script")) {
            return false;
        }
    }

    return true;
}

/// A key: a token-name segment (`accent-surface`, `headline-1`).
fn key(value: []const u8) bool {
    std.debug.assert(key_len_max <= design.token_name_len_max);
    std.debug.assert(value.len < 1 << 24);

    return value.len <= key_len_max and design.valid_token_name(value);
}

/// Text on one line, within `len_max`.
fn text(value: []const u8, len_max: u32) bool {
    std.debug.assert(len_max > 0 and len_max <= html_len_max);
    std.debug.assert(value.len < 1 << 24);

    return value.len <= len_max and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

/// A size: a token key, or a literal CSS length (`93px`, `-0.02em`); empty is allowed.
fn length(value: []const u8) bool {
    std.debug.assert(key_len_max > 0);
    std.debug.assert(value.len < 1 << 24);

    if (value.len > key_len_max) {
        return false;
    }

    for (value) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or
            char == '%' or char == '+';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

fn weights(list: []const u32) bool {
    std.debug.assert(list.len <= 64);
    std.debug.assert(weights_max == 9);

    for (list) |weight| {
        if (weight < 100 or weight > 900 or weight % 100 != 0) {
            return false;
        }
    }

    return true;
}

/// Where a face's file is: a path of this site (the media library) or `https://`.
fn source(src: []const u8) bool {
    std.debug.assert(design.font_len_max > 0);
    std.debug.assert(src.len < 1 << 24);

    if (src.len < 2 or src.len > design.font_len_max) {
        return false;
    }

    if (std.mem.indexOfAny(u8, src, " \t\r\n\"'<>\\`()") != null) {
        return false;
    }

    const local = src[0] == '/' and src[1] != '/';

    return local or std.mem.startsWith(u8, src, "https://");
}

/// Self-contained SVG markup: one `<svg>` element, no scripts, handlers or links out.
fn svg(markup: []const u8) bool {
    std.debug.assert(svg_len_max > 0);
    std.debug.assert(markup.len < 1 << 24);

    const trimmed = std.mem.trim(u8, markup, " \t\r\n");

    if (trimmed.len == 0 or markup.len > svg_len_max) {
        return false;
    }

    if (!std.mem.startsWith(u8, trimmed, "<svg")) {
        return false;
    }

    const banned = [_][]const u8{
        "<script",
        "javascript:",
        " on",
        "<foreignobject",
        "href=\"http",
    };

    for (banned) |needle| {
        if (contains_folded(trimmed, needle)) {
            return false;
        }
    }

    return true;
}

fn contains_folded(haystack: []const u8, needle: []const u8) bool {
    std.debug.assert(needle.len > 0);
    std.debug.assert(haystack.len < 1 << 24);

    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn one_of(choices: []const []const u8, value: []const u8) bool {
    std.debug.assert(choices.len > 0);
    std.debug.assert(value.len < 1 << 24);

    for (choices) |choice| {
        if (std.mem.eql(u8, choice, value)) {
            return true;
        }
    }

    return false;
}

/// The document as the `design/system.zon` file holds it.
pub fn to_zon(arena: std.mem.Allocator, system: System) error{OutOfMemory}![]const u8 {
    std.debug.assert(valid(system));

    var out: std.Io.Writer.Allocating = .init(arena);

    const header = "// The app's design system, written by the design system builder.\n";

    out.writer.writeAll(header) catch {
        return error.OutOfMemory;
    };
    std.zon.stringify.serialize(system, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeAll("\n") catch return error.OutOfMemory;

    std.debug.assert(out.written().len > 0);

    return out.written();
}

/// The document a `design/system.zon` holds; error.Invalid when it is not one.
pub fn from_zon(
    arena: std.mem.Allocator,
    content: []const u8,
) error{ OutOfMemory, Invalid }!System {
    std.debug.assert(content.len < 1 << 31);

    const source_z = try arena.dupeZ(u8, content);
    const parsed = std.zon.parse.fromSliceAlloc(System, arena, source_z, null, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;

    if (!valid(parsed)) {
        return error.Invalid;
    }

    return parsed;
}

test "a design system round-trips through its zon file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const system: System = .{
        .roles = &.{.{
            .key = "surface",
            .label = "Surface",
            .description = "Pages",
        }},
        .contexts = &.{.{
            .key = "default",
            .label = "Default",
        }},
        .fonts = &.{.{
            .token = "font-inferi",
            .family = "Inferi",
            .fallback = "serif",
            .provider = "files",
            .faces = &.{.{
                .weight_min = 400,
                .weight_max = 400,
                .src = "/media/ab12.woff2",
            }},
        }},
        .type_scale = &.{.{
            .key = "body-1",
            .label = "Body 1",
            .font_role = "body",
            .size = "16px",
        }},
        .icons = &.{.{
            .name = "check",
            .label = "Check",
            .category = "General",
            .svg = "<svg/>",
        }},
    };
    const written = try to_zon(arena, system);
    const read = try from_zon(arena, written);

    try std.testing.expectEqualStrings("Inferi", read.fonts[0].family);
    try std.testing.expectEqualStrings("/media/ab12.woff2", read.fonts[0].faces[0].src);
    try std.testing.expectEqualStrings("16px", read.type_scale[0].size);
    try std.testing.expectError(error.Invalid, from_zon(arena, ".{ .roles = 1 }"));
}

test "what a design system may not hold" {
    const scripted: System = .{
        .icons = &.{.{
            .name = "x",
            .label = "X",
            .category = "General",
            .svg = "<svg onload=\"alert(1)\"/>",
        }},
    };
    const far_face: System = .{
        .fonts = &.{.{
            .token = "font-a",
            .family = "A",
            .provider = "files",
            .faces = &.{.{
                .weight_min = 400,
                .weight_max = 400,
                .src = "//evil.test/a.woff2",
            }},
        }},
    };
    const unknown_provider: System = .{
        .fonts = &.{.{
            .token = "font-a",
            .family = "A",
            .provider = "adobe",
        }},
    };

    try std.testing.expect(valid(.{}));
    try std.testing.expect(!valid(scripted));
    try std.testing.expect(!valid(far_face));
    try std.testing.expect(!valid(unknown_provider));
}
