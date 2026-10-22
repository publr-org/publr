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
const content_types = @import("../content_type.zig");
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
    /// Taken in from the media folder; no one has looked at it yet.
    unreviewed: bool = false,
    /// Its file is gone from the media folder, or never came.
    missing: bool = false,
    /// Its bytes are on their way (`media.import`): referenced already, served once here.
    pending: bool = false,
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

    try plugin_types.apply(ctx, &.{.{
        .owner = model.content_type.core_owner,
        .def = media.type_def,
    }});

    try ensure_taxonomy(ctx, media.folders_handle, media.folders_definition);
    try ensure_taxonomy(ctx, media.tags_handle, media.tags_definition);
}

/// The library's taxonomy of this handle, made from its definition when it is missing.
fn ensure_taxonomy(ctx: *Ctx, handle: []const u8, definition: []const u8) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(definition.len > 0);

    const found = store.taxonomies.get_by_handle(ctx.db, ctx.arena, handle) catch {
        return error.Unavailable;
    };

    if (found == null) {
        _ = try registry.SDK.dispatch(ctx, taxonomy.Create, .{
            .definition = definition,
        });
    }
}

/// The media type of this handle as the caller reaches it: `NotFound` when there is none or
/// the grant does not reach it, `Invalid` when its records are not files.
pub fn media_type_for(
    ctx: *Ctx,
    granted: *const sdk.Grant,
    handle: []const u8,
) Error!store.content_types.Row {
    std.debug.assert(granted.allows());
    std.debug.assert(ctx.now_ms >= 0);

    const row = try media_type(ctx, handle);

    if (!content_types.visible(granted, row.def)) {
        return error.NotFound;
    }

    return row;
}

/// The media type of this handle: `NotFound` when there is none, `Invalid` when its records
/// are not files.
pub fn media_type(ctx: *Ctx, handle: []const u8) Error!store.content_types.Row {
    std.debug.assert(ctx.now_ms >= 0);

    if (handle.len == 0 or handle.len > model.content_type.handle_len_max) {
        return error.Invalid;
    }

    const row = try content_types.find_raw(ctx, handle) orelse return error.NotFound;

    if (row.def.kind != .media) {
        return error.Invalid;
    }

    std.debug.assert(row.def.handle.len > 0);

    return row;
}

/// Whether a media type takes a file of this family: any the library takes when it names
/// none.
pub fn takes(def: model.content_type.Def, family: []const u8) bool {
    std.debug.assert(def.kind == .media);
    std.debug.assert(family.len > 0);

    if (def.families.len == 0) {
        return true;
    }

    for (def.families) |taken| {
        if (std.mem.eql(u8, taken, family)) {
            return true;
        }
    }

    return false;
}

/// A file of a Private media type stays private; the library's files are each their own.
pub fn may_be_public(ctx: *Ctx, record_id: []const u8) Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const handle = try store.media.type_of(ctx.db, ctx.arena, record_id) orelse {
        return error.NotFound;
    };

    if (media.is_library(handle)) {
        return;
    }

    if (!(try media_type(ctx, handle)).def.public) {
        return ctx.fail(private_type);
    }
}

const private_type: sdk.operation.Failure = .{
    .name = "PrivateType",
    .status = 422,
    .message = "A file of a Private media type is private",
};

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
        .unreviewed = row.unreviewed,
        .missing = row.missing,
        .pending = row.hash.len == 0 and !row.missing,
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

    const got = try registry.SDK.dispatch(ctx, record.Get, .{
        .id = id,
    });
    const parsed = std.json.parseFromSliceLeaky(Written, ctx.arena, got.document, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;

    return parsed;
}

/// Writes the fields given straight into the live file: the library's records are never
/// drafts. Someone changing a file has looked at it: it leaves the unreviewed ones.
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
    try store.media.reviewed(ctx.db, &.{id});
}

/// The file's row, or `NotFound`: one only the library writes, so a record of the type
/// without one is not a file.
/// Whether the grant keeps private files out of reach: a plugin's `media.read` without
/// `.private`.
pub fn public_only(granted: *const sdk.Grant) bool {
    std.debug.assert(granted.allows());
    std.debug.assert(granted.field_mask.len <= sdk.grant.list_len_max);

    return granted.record_filter.flags.public_types_only;
}

pub fn row_of(ctx: *Ctx, id: []const u8) Error!store.media.Row {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (id.len > 64) {
        return error.Invalid;
    }

    return try store.media.get(ctx.db, ctx.arena, id) orelse error.NotFound;
}
