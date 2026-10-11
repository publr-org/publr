const std = @import("std");
const tags = @import("tags.zig");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const term = @import("../term.zig");
const library = @import("library.zig");
const edit = @import("edit.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const File = struct {
    pub const name = "media.file";
    pub const description = "What serving a file needs: its type, size and focal point";
    pub const details =
        \\Anyone may ask about a public file, by its key; a private one answers not found to
        \\callers who are not signed in, as one that does not exist.
    ;
    pub const kind: sdk.operation.Kind = .read;
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
        .hash = "9f2c" ** 16,
        .focal_x = 50,
        .focal_y = 40,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .key = "The file's key, as in its address",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The file's record id",
        .filename = "The name it was uploaded with",
        .mime_type = "Its type",
        .size = "Its size in bytes",
        .private = "Whether only signed-in users may see it",
        .hash = "SHA-256 of its bytes, hex",
        .focal_x = "The subject's place across, in percent",
        .focal_y = "The subject's place down, in percent",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.key.len == 0 or in.key.len > 256) {
            return error.Invalid;
        }

        const row = try store.media.by_key(ctx.db, ctx.arena, in.key) orelse return error.NotFound;
        const signed_in = ctx.caller != .anonymous;

        if (row.private and !signed_in) {
            return error.NotFound;
        }

        const focal = try store.media.focal(ctx.db, ctx.arena, row.record);

        return .{
            .id = row.record,
            .filename = row.filename,
            .mime_type = row.mime_type,
            .size = @intCast(row.size),
            .private = row.private,
            .hash = row.hash,
            .focal_x = @intCast(std.math.clamp(focal.across orelse 50, 0, 100)),
            .focal_y = @intCast(std.math.clamp(focal.down orelse 50, 0, 100)),
        };
    }
};

pub const example_folder_id = "2a3b4c5d6e7f80910a1b2c3d";

pub const FolderDelete = struct {
    pub const name = "media.folder_delete";
    pub const description = "Remove a folder, keeping what was in it";
    pub const details =
        \\The folders inside it move up to its parent, and so do its files; a top-level
        \\folder's files become unsorted. Then the folder's term is purged, which only
        \\administrators may do.
    ;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .folder = "The folder's id",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .moved = "How many files and folders moved up",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.folder.len == 0 or in.folder.len > 64) {
            return error.Invalid;
        }

        const folders = try tags.taxonomy_id(ctx, model.media.folders_handle);
        const folder = try store.terms.node(ctx.db, ctx.arena, folders, in.folder) orelse {
            return error.NotFound;
        };
        const parent = folder.parent_id orelse "";
        const moved = try move_up(ctx, folder.id, parent);

        _ = try registry.SDK.dispatch(ctx, term.Purge, .{
            .id = folder.id,
        });

        return .{
            .moved = moved,
        };
    }
};

/// Moved up in batches: a folder's own folders and files go to its parent, each move
/// taking one out of it, until none is left; how many moved.
fn move_up(ctx: *Ctx, folder: []const u8, parent: []const u8) Error!u32 {
    std.debug.assert(folder.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const scratch = try ctx.scratch();
    var moved: u32 = 0;
    var progress: Progress = .{};

    while (true) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const children = try store.terms.child_ids(ctx.db, scratch.allocator(), folder, batch);

        try progress.past(children);

        for (children) |child| {
            _ = try registry.SDK.dispatch(ctx, term.Save, .{
                .id = child,
                .document = "{}",
                .parent = parent,
            });
        }

        moved += @intCast(children.len);

        if (children.len < batch) {
            break;
        }
    }

    while (true) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const filed = try store.media.filed_in(ctx.db, scratch.allocator(), folder, batch);

        try progress.past(filed);

        for (filed) |record| {
            try library.save(ctx, record, edit.Changes{
                .folder = parent,
            });
        }

        moved += @intCast(filed.len);

        if (filed.len < batch) {
            return moved;
        }
    }
}

const batch: u32 = 50;

/// A batch that starts where the last one did moved nothing: stopped, never looped on.
const Progress = struct {
    first: [128]u8 = undefined,
    first_len: u32 = 0,

    fn past(progress: *Progress, ids: []const []const u8) Error!void {
        if (ids.len == 0) {
            return;
        }

        const first = ids[0];

        std.debug.assert(first.len <= progress.first.len);

        const last = progress.first[0..progress.first_len];

        if (progress.first_len > 0 and std.mem.eql(u8, last, first)) {
            return error.Failed;
        }

        @memcpy(progress.first[0..first.len], first);
        progress.first_len = @intCast(first.len);
    }
};

pub const operations = [_]type{ File, FolderDelete };
