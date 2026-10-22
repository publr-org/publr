const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const files_module = @import("../../lib/files.zig");
const image = @import("../../lib/image.zig");
const sanitize = @import("../../lib/sanitize.zig");
const ids = @import("../../lib/id.zig");
const record = @import("../record.zig");
const library = @import("library.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const media = model.media;

pub const token_len_min: u32 = 8;
pub const token_len_max: u32 = 40;
pub const svg_bytes_max: u32 = 1 << 20;

pub const Upload = struct {
    pub const name = "media.upload";
    pub const description = "Add the file an upload streamed in to the media library";
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
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .upload = "The token the upload's bytes are kept under: 8 to 40 of a-z and 0-9",
        .filename = "The file's name, with its extension",
        .folder = "The folder to file it in (a `media_folders` term id); none leaves it unsorted",
        .type = "The media type it is a file of, by handle; `media`, the library, by default",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!valid_token(in.upload) or !media.valid_filename(in.filename)) {
            return error.Invalid;
        }

        const def = (try library.media_type(ctx, in.type)).def;

        const files = try library.files_of(ctx);
        const limit = files_module.bytes_max;
        const allocator = library.file_allocator;
        const bytes = files.read(allocator, .incoming, in.upload, limit) catch |err| {
            return library.fail(err);
        };
        defer library.file_allocator.free(bytes);

        const item = try add(ctx, files, def, in.filename, bytes, in.folder);

        files.remove(.incoming, in.upload);

        return item;
    }
};

pub const Add = struct {
    pub const name = "media.add";
    pub const description = "Add a file on this machine to the media library";
    pub const details =
        \\For the local operator only (`--as-admin`): `file` is any path this machine reads.
        \\Checked and added as an upload is, named after the file unless `filename` says.
    ;
    pub const operator_only = true;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .file = "The file's path",
        .filename = "The name it is kept under; the path's own name when left out",
        .folder = "The folder to file it in (a `media_folders` term id)",
        .type = "The media type it is a file of, by handle; `media`, the library, by default",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (ctx.caller != .system) {
            return error.Denied;
        }

        if (in.file.len == 0 or in.file.len > 4096) {
            return error.Invalid;
        }

        const filename = in.filename orelse std.fs.path.basename(in.file);

        if (!media.valid_filename(filename)) {
            return error.Invalid;
        }

        const def = (try library.media_type(ctx, in.type)).def;
        const limit: std.Io.Limit = .limited(files_module.bytes_max);
        const allocator = library.file_allocator;
        const cwd = std.Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(ctx.io, in.file, allocator, limit) catch |err| {
            return switch (err) {
                error.FileNotFound => error.NotFound,
                error.OutOfMemory => error.OutOfMemory,
                else => error.Invalid,
            };
        };
        defer library.file_allocator.free(bytes);

        return add(ctx, try library.files_of(ctx), def, filename, bytes, in.folder);
    }
};

pub fn valid_token(token: []const u8) bool {
    std.debug.assert(token_len_max > token_len_min);

    if (token.len < token_len_min or token.len > token_len_max) {
        return false;
    }

    for (token) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char)) {
            return false;
        }
    }

    return true;
}

const not_taken: sdk.operation.Failure = .{
    .name = "NotTaken",
    .status = 422,
    .message = "This media type does not take files of this kind",
};

const no_folders: sdk.operation.Failure = .{
    .name = "NoFolders",
    .status = 422,
    .message = "Only the media library files into folders",
};

const not_what_it_says: sdk.operation.Failure = .{
    .name = "NotWhatItSays",
    .status = 422,
    .message = "The file's contents are not what its extension says",
};

/// Checks the file is one the media type takes, keeps its bytes under a new key, and adds
/// its record and row.
pub fn add(
    ctx: *Ctx,
    files: files_module.Files,
    def: model.content_type.Def,
    filename: []const u8,
    bytes: []const u8,
    folder: ?[]const u8,
) Error!library.Item {
    std.debug.assert(bytes.len <= files_module.bytes_max);
    std.debug.assert(media.valid_filename(filename));
    std.debug.assert(def.kind == .media);

    const library_type = media.is_library(def.handle);

    if (!library_type and folder != null and folder.?.len > 0) {
        return ctx.fail(no_folders);
    }

    if (!library.takes(def, media.kind_of(filename).?.family)) {
        return ctx.fail(not_taken);
    }

    const kept = try checked(ctx, filename, bytes);
    var random_hex: [ids.len]u8 = undefined;
    var key_buffer: [files_module.key_len_max]u8 = undefined;
    const random = ids.random(ctx.io, &random_hex)[0..media.random_len];
    const key = try ctx.arena.dupe(
        u8,
        media.key_of(&key_buffer, def.handle, ctx.now_ms, filename, random),
    );

    files.write(.files, key, kept) catch |err| return library.fail(err);

    return added(ctx, .{
        .type = def.handle,
        .filename = filename,
        .key = key,
        .bytes = kept,
        .folder = folder,
        .private = !library_type and !def.public,
    });
}

/// A library file whose bytes come later (`fill`): its record and row made now, Pending
/// (no bytes, no hash), so it can be referenced at once. What `media.import` makes before
/// its download runs as queued work.
pub fn reserved(ctx: *Ctx, filename: []const u8, folder: ?[]const u8) Error!library.Item {
    std.debug.assert(media.valid_filename(filename));
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const kind = media.kind_of(filename).?;
    var random_hex: [ids.len]u8 = undefined;
    var key_buffer: [files_module.key_len_max]u8 = undefined;
    const random = ids.random(ctx.io, &random_hex)[0..media.random_len];
    const key = try ctx.arena.dupe(
        u8,
        media.key_of(&key_buffer, media.type_handle, ctx.now_ms, filename, random),
    );
    const created = try registry.SDK.dispatch(ctx, record.Create, .{
        .type = media.type_handle,
        .document = try document_of(ctx, filename, folder),
        .status = "published",
    });
    const row: store.media.Row = .{
        .record = created.id,
        .filename = filename,
        .mime_type = kind.mime_type,
        .size = 0,
        .width = null,
        .height = null,
        .storage_key = key,
        .hash = "",
        .private = false,
        .created_at = ctx.now_ms,
    };

    try store.media.insert(ctx.db, row);

    return library.item_of(row, title_of(filename));
}

/// A Pending file's bytes, checked as an upload's are, kept under its key, and its facts
/// filled in: no longer Pending.
pub fn fill(ctx: *Ctx, pending: store.media.Row, bytes: []const u8) Error!void {
    std.debug.assert(pending.hash.len == 0);
    std.debug.assert(bytes.len <= files_module.bytes_max);

    const kept = try checked(ctx, pending.filename, bytes);
    const files = try library.files_of(ctx);

    files.write(.files, pending.storage_key, kept) catch |err| return library.fail(err);

    const size = image.size_of(kept);
    const hash = hash_of(kept);

    try store.media.filled(ctx.db, pending.record, .{
        .size = @intCast(kept.len),
        .width = if (size) |known| known.width else null,
        .height = if (size) |known| known.height else null,
        .hash = &hash,
    });
}

/// The bytes the library keeps of a file: what its extension says they are, an SVG
/// cleaned of scripts.
pub fn checked(ctx: *Ctx, filename: []const u8, bytes: []const u8) Error![]const u8 {
    std.debug.assert(bytes.len <= files_module.bytes_max);
    std.debug.assert(media.valid_filename(filename));

    if (bytes.len == 0) {
        return error.Invalid;
    }

    const kind = media.kind_of(filename).?;

    if (!media.matches(kind, bytes)) {
        return ctx.fail(not_what_it_says);
    }

    return if (std.mem.eql(u8, kind.extension, "svg")) try clean_svg(ctx, bytes) else bytes;
}

pub const Kept = struct {
    /// The media type, by handle.
    type: []const u8 = media.type_handle,
    filename: []const u8,
    key: []const u8,
    bytes: []const u8,
    folder: ?[]const u8 = null,
    /// Taken in from the media folder rather than uploaded.
    unreviewed: bool = false,
    /// Only signed-in users may open it.
    private: bool = false,
};

/// The record and row of a file whose bytes are kept under its key.
pub fn added(ctx: *Ctx, kept: Kept) Error!library.Item {
    std.debug.assert(kept.bytes.len > 0);
    std.debug.assert(files_module.valid_key(kept.key));

    const kind = media.kind_of(kept.filename).?;
    const size = image.size_of(kept.bytes);
    const hash = hash_of(kept.bytes);
    const created = try registry.SDK.dispatch(ctx, record.Create, .{
        .type = kept.type,
        .document = try document_of(ctx, kept.filename, kept.folder),
        .status = "published",
    });
    const row: store.media.Row = .{
        .record = created.id,
        .filename = kept.filename,
        .mime_type = kind.mime_type,
        .size = @intCast(kept.bytes.len),
        .width = if (size) |known| known.width else null,
        .height = if (size) |known| known.height else null,
        .storage_key = kept.key,
        .hash = &hash,
        .private = kept.private,
        .created_at = ctx.now_ms,
        .unreviewed = kept.unreviewed,
    };

    try store.media.insert(ctx.db, row);

    return library.item_of(row, title_of(kept.filename));
}

fn clean_svg(ctx: *Ctx, bytes: []const u8) Error![]const u8 {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(svg_bytes_max <= sanitize.input_bytes_max);

    if (bytes.len > svg_bytes_max) {
        return error.Invalid;
    }

    const cleaned = sanitize.sanitize(ctx.arena, bytes, .content) catch return error.Invalid;
    const start = std.mem.indexOf(u8, cleaned, "<svg") orelse return ctx.fail(not_what_it_says);

    return cleaned[start..];
}

fn hash_of(bytes: []const u8) [64]u8 {
    std.debug.assert(bytes.len > 0);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const hex = std.fmt.bytesToHex(digest, .lower);

    std.debug.assert(hex.len == 64);

    return hex;
}

/// A file is titled after its name, without the extension.
fn title_of(filename: []const u8) []const u8 {
    std.debug.assert(filename.len > 0);

    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
    const title = std.mem.trim(u8, filename[0..dot], " ");

    return if (title.len == 0) filename else title;
}

fn document_of(ctx: *Ctx, filename: []const u8, folder: ?[]const u8) Error![]const u8 {
    std.debug.assert(filename.len > 0);
    std.debug.assert(folder == null or folder.?.len <= 64);

    const Document = struct {
        title: []const u8,
        media_folders: ?[]const u8,
    };
    const filed = if (folder) |chosen| (if (chosen.len > 0) chosen else null) else null;

    return std.json.Stringify.valueAlloc(ctx.arena, Document{
        .title = title_of(filename),
        .media_folders = filed,
    }, .{
        .emit_null_optional_fields = false,
    }) catch error.OutOfMemory;
}

test "valid_token: lowercase letters and digits, 8 to 40" {
    try std.testing.expect(valid_token("u7f3a9c2e1"));
    try std.testing.expect(!valid_token("short"));
    try std.testing.expect(!valid_token("../../etc"));
    try std.testing.expect(!valid_token("UPPERCASE1"));
}

test "title_of: the name without its extension" {
    try std.testing.expectEqualStrings("Harbour at dawn", title_of("Harbour at dawn.jpg"));
    try std.testing.expectEqualStrings(".jpg", title_of(".jpg"));
}
