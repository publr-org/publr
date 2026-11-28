const operation = @import("../../operation.zig");
const library = @import("library.zig");
const media = @import("../../model/media.zig");

pub const token_len_min: u32 = 8;

pub const token_len_max: u32 = 40;

pub const svg_bytes_max: u32 = 1 << 20;

pub const Upload = struct {
    pub const name = "media.upload";
    pub const description = "Add the file an upload streamed in to the media library";
    pub const find_words = "file, image, picture, photo, attachment, add a file";
    pub const details =
        \\What the library's Upload does after it sends a file's bytes to `/media/upload`,
        \\which keeps them under a token: the file is checked (its bytes must be what its
        \\extension says; an SVG is cleaned of scripts), kept under a dated key and added
        \\as a published record of the media type `type` (the library, `media`, unless it
        \\names another) titled after its name, in `folder` when given (the library's
        \\only). Up to 32 MiB; the file types are the library's own (images, video, audio,
        \\PDF, text, CSV, ZIP, fonts), narrowed to the families the type takes. A file of
        \\a Private media type other than the library is private. `/media/upload` calls it
        \\itself; the token alone is no use.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        upload: []const u8,
        filename: []const u8,
        folder: ?[]const u8 = null,
        type: []const u8 = media.type_handle,
    };
    pub const Out = library.Item;
    pub const example: In = .{
        .upload = "u7f3a9c2e1",
        .filename = "harbour.png",
    };
    pub const example_out: Out = library.example_item;
    pub const field_docs: operation.Docs(In) = .{
        .upload = "The token the upload's bytes are kept under: 8 to 40 of a-z and 0-9",
        .filename = "The file's name, with its extension",
        .folder = "The folder to file it in (a `media_folders` term id); none leaves it unsorted",
        .type = "The media type it is a file of, by handle; `media`, the library, by default",
    };
};

pub const Add = struct {
    pub const name = "media.add";
    pub const description = "Add a file on this machine to the media library";
    pub const details =
        \\For the local operator only (`--as-admin`): `file` is any path this machine reads.
        \\Checked and added as an upload is, named after the file unless `filename` says.
    ;
    pub const operator_only = true;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        file: []const u8,
        filename: ?[]const u8 = null,
        folder: ?[]const u8 = null,
        type: []const u8 = media.type_handle,
    };
    pub const Out = library.Item;
    pub const example: In = .{
        .file = "harbour.png",
    };
    pub const example_out: Out = library.example_item;
    pub const field_docs: operation.Docs(In) = .{
        .file = "The file's path",
        .filename = "The name it is kept under; the path's own name when left out",
        .folder = "The folder to file it in (a `media_folders` term id)",
        .type = "The media type it is a file of, by handle; `media`, the library, by default",
    };
};
