//! What the media operations share: the type and taxonomies the library stands on, made
//! when a database opens; a file as the operations answer with it; reading and writing a
//! file's record.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const files_module = @import("../../lib/files.zig");
const plugin_types = @import("../../sdk/plugin/types.zig");
const taxonomy = @import("../taxonomy.zig");
const record = @import("../record.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const media = model.media;

pub const Item = struct {
    id: []const u8,
    title: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    /// The media field's file family: `image`, `video`, `pdf`...
    family: []const u8,
    size: u64,
    width: ?u32 = null,
    height: ?u32 = null,
    /// Where the file is served: `/media/<key>`.
    key: []const u8,
    private: bool,
    created_at: i64,
};

pub const example_item: Item = .{
    .id = "0190a1b2c3d40001a1b2c3d4",
    .title = "Harbour at dawn",
    .filename = "harbour.jpg",
    .mime_type = "image/jpeg",
    .family = "image",
    .size = 482_113,
    .width = 2400,
    .height = 1600,
    .key = "2026/10/harbour-a1b2c3.jpg",
    .private = false,
    .created_at = 1791244800000,
};

/// The bytes of a whole file are held outside the request's arena, which is a few MiB.
pub const file_allocator = std.heap.page_allocator;

/// The `media` type and the two taxonomies that file its records, made or brought up to
/// date as the system whenever a database opens.
pub fn bootstrap(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.db.transaction_depth == 0);

    try plugin_types.apply(ctx, &.{.{ .owner = "publr", .def = media.type_def }});

    const listed = try registry.SDK.dispatch(ctx, taxonomy.List, .{});

    try ensure_taxonomy(ctx, listed.taxonomies, media.folders_handle, media.folders_definition);
    try ensure_taxonomy(ctx, listed.taxonomies, media.tags_handle, media.tags_definition);
}

fn ensure_taxonomy(
    ctx: *Ctx,
    listed: []const taxonomy.Summary,
    handle: []const u8,
    definition: []const u8,
) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(definition.len > 0);

    for (listed) |summary| {
        if (std.mem.eql(u8, summary.handle, handle)) {
            return;
        }
    }

    _ = try registry.SDK.dispatch(ctx, taxonomy.Create, .{ .definition = definition });
}

pub fn files_of(ctx: *const Ctx) Error!files_module.Files {
    std.debug.assert(ctx.now_ms >= 0);

    const found = ctx.files orelse return error.Unavailable;

    std.debug.assert(found.caches() or found == .deferred);

    return found;
}

/// A store failure as an operation's: a file the browser's worker has yet to hand over is
/// `Unavailable` (the request runs again with it), a bad key `Invalid`.
pub fn fail(err: files_module.Error) Error {
    std.debug.assert(@intFromError(err) != 0);

    return switch (err) {
        error.NotFound => error.NotFound,
        error.Needed, error.Storage => error.Unavailable,
        error.OutOfOrder => error.Conflict,
        error.TooLarge, error.InvalidKey => error.Invalid,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn item_of(row: anytype, title: []const u8) Item {
    std.debug.assert(row.size >= 0);
    std.debug.assert(row.storage_key.len > 0);

    const kind = media.kind_of(row.filename);

    return .{
        .id = row.record,
        .title = title,
        .filename = row.filename,
        .mime_type = row.mime_type,
        .family = if (kind) |known| known.family else "document",
        .size = @intCast(row.size),
        .width = if (row.width) |width| @intCast(width) else null,
        .height = if (row.height) |height| @intCast(height) else null,
        .key = row.storage_key,
        .private = row.private,
        .created_at = row.created_at,
    };
}

/// A file's record as the library reads it: what people wrote, and where it is filed.
pub const Written = struct {
    title: []const u8 = "",
    alt: []const u8 = "",
    caption: []const u8 = "",
    credit: []const u8 = "",
    focal_x: ?i64 = null,
    focal_y: ?i64 = null,
    media_folders: ?[]const u8 = null,
    media_tags: []const []const u8 = &.{},
};

pub fn written_of(ctx: *Ctx, id: []const u8) Error!Written {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const got = try registry.SDK.dispatch(ctx, record.Get, .{ .id = id });
    const parsed = std.json.parseFromSliceLeaky(Written, ctx.arena, got.document, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;

    return parsed;
}

/// Writes the fields given straight into the live file: the library's records are never
/// drafts.
pub fn save(ctx: *Ctx, id: []const u8, document: anytype) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const text = std.json.Stringify.valueAlloc(ctx.arena, document, .{
        .emit_null_optional_fields = false,
    }) catch return error.OutOfMemory;

    _ = try registry.SDK.dispatch(ctx, record.Save, .{
        .id = id,
        .document = text,
        .status = "published",
    });
}

/// The file's row, or `NotFound`: one only the library writes, so a record of the type
/// without one is not a file.
pub fn row_of(ctx: *Ctx, id: []const u8) Error!store.media.Row {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (id.len > 64) {
        return error.Invalid;
    }

    return try store.media.get(ctx.db, ctx.arena, id) orelse error.NotFound;
}
