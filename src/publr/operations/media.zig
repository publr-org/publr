//! The media library: files, their folders and tags, and the media types core and plugins
//! keep apart from it.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "media",
    .label = "Media library",
    .area = .content,
    .summary = "The media library: files, their folders and tags",
    .details =
    \\Every file is a published record of a media type. The library's is the core `media`
    \\type (title, alt text, caption, credit, focal point); core and plugins declare
    \\others (`kind` `media`) for files kept apart from it, shown only where they draw
    \\them. A library file is filed in at most one folder (`media_folders`, nested) and under
    \\any tags (`media_tags`). The facts of the file itself (name, type, size, dimensions,
    \\key, hash) are the library's own, written on upload. The bytes are kept beside the
    \\database and served at `/media/<key>`, resized with `?w=`, `?h=`, `?fit=cover`, `?q=`.
    ,
};

pub const library = @import("media/library.zig");
pub const upload = @import("media/upload.zig");
pub const list = @import("media/list.zig");
pub const edit = @import("media/edit.zig");
pub const serve = @import("media/serve.zig");
pub const sync = @import("media/sync.zig");
pub const import = @import("media/import.zig");
pub const view = @import("media/view.zig");
pub const read = @import("media/read.zig");
pub const made = @import("media/made.zig");
pub const destroy = @import("media/destroy.zig");

pub const Item = library.Item;
pub const Upload = upload.Upload;
pub const Add = upload.Add;
pub const List = list.List;
pub const Get = edit.Get;
pub const Update = edit.Update;
pub const Delete = edit.Delete;
pub const Destroy = destroy.Destroy;
pub const Move = edit.Move;
pub const Tag = edit.Tag;
pub const File = serve.File;
pub const FolderDelete = serve.FolderDelete;
pub const Sync = sync.Sync;
pub const Read = read.Read;
