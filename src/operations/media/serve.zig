const std = @import("std");
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
    pub const In = struct { key: []const u8 };
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
    pub const example: In = .{ .key = library.example_item.key };
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
    pub const field_docs: sdk.operation.Docs(In) = .{ .key = "The file's key, as in its address" };
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
    pub const In = struct { folder: []const u8 };
    pub const Out = struct { moved: u32 };
    pub const example: In = .{ .folder = example_folder_id };
    pub const example_out: Out = .{ .moved = 0 };
    pub const field_docs: sdk.operation.Docs(In) = .{ .folder = "The folder's id" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .moved = "How many files and folders moved up",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.folder.len == 0 or in.folder.len > 64) {
            return error.Invalid;
        }

        const tree = try registry.SDK.dispatch(ctx, term.Tree, .{
            .taxonomy = model.media.folders_handle,
        });
        const folder = node_of(tree.terms, in.folder) orelse return error.NotFound;
        const parent = folder.parent orelse "";
        var moved: u32 = 0;

        for (tree.terms) |node| {
            const below = node.parent != null and std.mem.eql(u8, node.parent.?, folder.id);

            if (below) {
                _ = try registry.SDK.dispatch(ctx, term.Save, .{
                    .id = node.id,
                    .document = "{}",
                    .parent = parent,
                });
                moved += 1;
            }
        }

        for (try store.media.filed_in(ctx.db, ctx.arena, folder.id)) |record| {
            try library.save(ctx, record, edit.Changes{ .folder = parent });
            moved += 1;
        }

        _ = try registry.SDK.dispatch(ctx, term.Purge, .{ .id = folder.id });

        return .{ .moved = moved };
    }
};

fn node_of(nodes: []const term.Node, id: []const u8) ?term.Node {
    std.debug.assert(id.len > 0);

    for (nodes) |node| {
        if (std.mem.eql(u8, node.id, id)) {
            return node;
        }
    }

    return null;
}

pub const operations = [_]type{ File, FolderDelete };
