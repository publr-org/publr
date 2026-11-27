//! Files a plugin makes (an invoice's PDF, a label, a feed, a CSV export): written in pieces,
//! so the plugin never holds the whole file, then kept as a file of one of its own media
//! types, a published record it references like any other. A file of a private media type
//! opens only to whoever may read the type (staff), or to whoever holds a link the plugin
//! signed (`/_links/<token>` answering `{ "file": <id> }`); it attaches to messages as any
//! file does. How large a file may be is the plugin's declared limit (`.limits.file_mib`,
//! granted with the plugin), never more than the site keeps.
const operation = @import("../../operation.zig");
const library = @import("library.zig");

/// The most one piece carries, before base64: what a plugin holds at once.
pub const part_bytes_max: u32 = 256 << 10;

pub const part_name_len_min: u32 = 8;

pub const part_name_len_max: u32 = 40;

pub const WritePart = struct {
    pub const name = "media.write_part";
    pub const plugins_only = true;
    pub const description = "Add a piece to a file the plugin is making";
    pub const details =
        \\Plugins only. `data` (base64, at most 256 KiB before it) goes at `offset`: 0 starts
        \\the file afresh, any other must be where it ends. The part is the plugin's own; no
        \\other plugin writes or reads it. Past the plugin's file limit it is refused.
        \\`media.make` turns the part into a file.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        part: []const u8,
        offset: u64 = 0,
        data: []const u8,
    };
    pub const Out = struct {
        size: u64,
    };
    pub const example: In = .{
        .part = "invoice0001",
        .data = "JVBERi0xLjQK",
    };
    pub const example_out: Out = .{
        .size = 9,
    };
    pub const field_docs: operation.Docs(In) = .{
        .part = "The part's name, the plugin's own: 8 to 40 of a-z and 0-9",
        .offset = "Where the piece goes: 0 starts afresh, else the part's size so far",
        .data = "The piece's bytes, base64",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .size = "The part's size after the piece, in bytes",
    };
};

pub const Make = struct {
    pub const name = "media.make";
    pub const plugins_only = true;
    pub const description = "Keep a part the plugin wrote as a file of one of its media types";
    pub const details =
        \\Plugins only. The part becomes a published file of `type`, a media type the plugin
        \\declares (`kind` `media`), named `filename` and checked as an upload is: its bytes
        \\must be what its extension says. A file of a private type opens only to whoever
        \\may read the type, or through a link the plugin signed. The part is gone after.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        part: []const u8,
        filename: []const u8,
        type: []const u8,
    };
    pub const Out = library.Item;
    pub const example: In = .{
        .part = "invoice0001",
        .filename = "invoice-FK-1.pdf",
        .type = "invoices.document",
    };
    pub const example_out: Out = library.example_item;
    pub const field_docs: operation.Docs(In) = .{
        .part = "The part written with `media.write_part`",
        .filename = "The file's name, with its extension",
        .type = "One of the plugin's own media types, by handle",
    };
};

pub const Made = struct {
    pub const name = "media.made";
    pub const plugins_only = true;
    pub const description = "A file the plugin made, by its id: where it is kept";
    pub const details =
        \\Plugins only, for the plugin's own files: what serving one through a signed link
        \\needs. A file of another plugin's type, or of none of its own, is not found.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        key: []const u8,
        filename: []const u8,
        mime_type: []const u8,
        size: u64,
    };
    pub const example: In = .{
        .id = library.example_item.id,
    };
    pub const example_out: Out = .{
        .key = "invoices.document/2026/11/invoice-fk-1-a1b2c3.pdf",
        .filename = "invoice-FK-1.pdf",
        .mime_type = "application/pdf",
        .size = 18_204,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The file's record id",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .key = "Where its bytes are kept",
        .filename = "Its name",
        .mime_type = "Its type",
        .size = "Its size in bytes",
    };
};
