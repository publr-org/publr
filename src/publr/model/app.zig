//! An app as plugins and operations see it: the typefaces its pages load (`app.zon`), and
//! how its files travel in an operation.

/// A typeface the app's pages load: its family, and the stylesheet that serves it, or the
/// files the site hosts itself (each an `@font-face`).
pub const Font = struct {
    family: []const u8,
    url: []const u8 = "",
    faces: []const FontFace = &.{},
};

/// One hosted file of a family: its weight (a range for a variable face) and style.
pub const FontFace = struct {
    weight_min: u32 = 400,
    weight_max: u32 = 400,
    italic: bool = false,
    src: []const u8,
};

pub const font_faces_max: u32 = 32;

/// How an app file's bytes are carried: as they are when UTF-8, else base64 (an icon, an
/// image, a font), so any file fits a JSON field.
pub const FileEncoding = enum {
    text,
    base64,
};
