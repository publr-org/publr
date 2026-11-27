//! `media.read`: a file's bytes as the caller may read them, of any media type, private
//! ones included; how an agent or a command looks at a picture without the site serving
//! it to anyone. Resized copies are made and cached as `/media/<key>` makes them.
const operation = @import("../../operation.zig");
const library = @import("library.zig");

/// The most one answer carries, before base64: a resized copy is asked for past it.
pub const read_bytes_max: u32 = 8 << 20;

pub const side_max: u32 = 4096;

pub const Read = struct {
    pub const name = "media.read";
    pub const description = "A file's bytes, as uploaded or resized";
    pub const details =
        \\The file at `key`, of any media type, private ones included: signed-in callers
        \\only, and only files whose type they may read. `width` and `height` resize an
        \\image (never
        \\larger; with both, `fit` `cover` scales before it crops, else it crops at full
        \\size) around its focal point; `format` (`webp`, `jpeg` or `png`) converts it,
        \\`quality` sets the quality. Files that are not JPEG or PNG come as they are. Up to 8 MiB,
        \\base64 in `data`; a larger image is read smaller.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        key: []const u8,
        width: ?u32 = null,
        height: ?u32 = null,
        fit: []const u8 = "",
        format: []const u8 = "",
        quality: ?u8 = null,
    };
    pub const Out = struct {
        mime_type: []const u8,
        size: u64,
        data: []const u8,
    };
    pub const example: In = .{
        .key = library.example_item.key,
        .width = 800,
        .format = "webp",
    };
    pub const example_out: Out = .{
        .mime_type = "image/webp",
        .size = 4,
        .data = "UklGRg==",
    };
    pub const field_docs: operation.Docs(In) = .{
        .key = "The file's key, as in its address",
        .width = "Width to resize to, 1 to 4096",
        .height = "Height to resize to, 1 to 4096",
        .fit = "`crop` (the default) or `cover`",
        .format = "`webp`, `jpeg` or `png`; empty keeps the file's own",
        .quality = "Quality, 1 to 100",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .mime_type = "The type of the bytes sent",
        .size = "How many bytes they are",
        .data = "The bytes, base64",
    };
};
