const operation = @import("../../operation.zig");
const library = @import("library.zig");

pub const View = struct {
    pub const name = "media.view";
    pub const description = "What a page needs to show a file: its address, size and alt text";
    pub const details =
        \\By the id a media field holds. Anyone may ask about a public file, as anyone may
        \\load it from `/media/<key>`; a private one answers not found to callers who are not
        \\signed in, as one that does not exist. `url` takes `?w=`, `?h=`, `?fit=cover` and
        \\`?q=` to resize. Light enough for a page to ask for dozens: the alt text is not
        \\read (a page writes its own, from the record it shows); `alt` is empty.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        id: []const u8,
        url: []const u8,
        key: []const u8,
        alt: []const u8,
        title: []const u8,
        mime_type: []const u8,
        width: ?i64 = null,
        height: ?i64 = null,
    };
    pub const example: In = .{
        .id = library.example_item.id,
    };
    pub const example_out: Out = .{
        .id = library.example_item.id,
        .url = "/media/" ++ library.example_item.key,
        .key = library.example_item.key,
        .alt = "",
        .title = "harbour",
        .mime_type = "image/jpeg",
        .width = 1600,
        .height = 1067,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The file's id: what a media field holds",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .id = "The file's id",
        .url = "Its address (`/media/<key>`, or under the base a plugin gives through the " ++
            "mod `media.base`); add ?w=, ?h=, ?fit=cover to resize",
        .key = "Its key, as in its address",
        .alt = "What it shows, for people who cannot see it",
        .title = "Its title, else its file name",
        .mime_type = "Its type",
        .width = "Its width in pixels, for an image",
        .height = "Its height in pixels, for an image",
    };
};
