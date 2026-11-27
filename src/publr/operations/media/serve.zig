const operation = @import("../../operation.zig");
const library = @import("library.zig");

pub const example_folder_id = "2a3b4c5d6e7f80910a1b2c3d";

pub const File = struct {
    pub const name = "media.file";
    pub const description = "What serving a file needs: its type, size and focal point";
    pub const details =
        \\Anyone may ask about a public file, by its key; a private one answers not found to
        \\callers who are not signed in, as one that does not exist. A file whose bytes have not
        \\arrived yet (an import still downloading) answers not found to everyone.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        key: []const u8,
    };
    pub const Out = struct {
        id: []const u8,
        filename: []const u8,
        mime_type: []const u8,
        size: u64,
        private: bool,
        hash: []const u8,
        focal_x: u8,
        focal_y: u8,
    };
    pub const example: In = .{
        .key = library.example_item.key,
    };
    pub const example_out: Out = .{
        .id = library.example_item.id,
        .filename = "harbour.jpg",
        .mime_type = "image/jpeg",
        .size = 482_113,
        .private = false,
        .hash = "9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c",
        .focal_x = 50,
        .focal_y = 40,
    };
    pub const field_docs: operation.Docs(In) = .{
        .key = "The file's key, as in its address",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .id = "The file's record id",
        .filename = "The name it was uploaded with",
        .mime_type = "Its type",
        .size = "Its size in bytes",
        .private = "Whether only signed-in users may see it",
        .hash = "SHA-256 of its bytes, hex",
        .focal_x = "The subject's place across, in percent",
        .focal_y = "The subject's place down, in percent",
    };
};

pub const FolderDelete = struct {
    pub const name = "media.folder_delete";
    pub const description = "Remove a folder, keeping what was in it";
    pub const details =
        \\The folders inside it move up to its parent, and so do its files; a top-level
        \\folder's files become unsorted. Then the folder's term is purged, which only
        \\administrators may do.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        folder: []const u8,
    };
    pub const Out = struct {
        moved: u32,
    };
    pub const example: In = .{
        .folder = example_folder_id,
    };
    pub const example_out: Out = .{
        .moved = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .folder = "The folder's id",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .moved = "How many files and folders moved up",
    };
};
