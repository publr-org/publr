const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const files_module = @import("../../lib/files.zig");
const ids = @import("../../lib/id.zig");
const term = @import("../term.zig");
const library = @import("library.zig");
const upload = @import("upload.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const media = model.media;
const dropped = files_module.dropped;

/// How many skipped files the answer names; the count covers the rest.
pub const skipped_listed_max: u32 = 50;
const kept_page: u32 = 500;
const folder_name_len_max: u32 = 64;

pub const Skipped = struct { path: []const u8, reason: []const u8 };

pub const Sync = struct {
    pub const name = "media.sync";
    pub const description = "Take in the files put into the media folder by hand";
    pub const details =
        \\Walks the media folder beside the database (never its hidden areas) for files the
        \\library does not have yet and adds each as a published `media` record marked
        \\unreviewed. A file whose path can serve as its key (lowercase letters, digits,
        \\`.-_`, up to four parts) stays where it is; any other is moved under a dated key.
        \\Its directories name its folder: `Photos/Trips/a.jpg` is filed in Photos › Trips,
        \\made when missing; a top directory of four digits is the library's own layout and
        \\names none. Files of a type the library does not take, empty ones and ones whose
        \\bytes are not what their extension says are skipped with the reason. Every file
        \\of the library whose bytes are gone is marked missing, and one found again is
        \\not. With `check`, nothing is written: the answer says what a sync would do.
        \\Only a server keeps such a folder; in the browser it is `Unavailable`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { check: bool = false };
    pub const Out = struct {
        new: u32,
        added: u32,
        missing: u32,
        skipped: []const Skipped,
        skipped_count: u32,
        more: bool,
    };
    pub const example: In = .{ .check = true };
    pub const example_out: Out = .{
        .new = 0,
        .added = 0,
        .missing = 0,
        .skipped = &.{},
        .skipped_count = 0,
        .more = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .check = "Only report what a sync would do",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .new = "Files in the folder the library does not have",
        .added = "How many of them this call added",
        .missing = "Files of the library whose bytes are gone from the folder",
        .skipped = "Files left out and why, the first fifty",
        .skipped_count = "How many files were left out",
        .more = "The folder holds more files than one sync looks at; run it again",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const disk = switch (try library.files_of(ctx)) {
            .disk => |disk| disk,
            .deferred => return ctx.fail(no_folder),
        };
        const walked = dropped.walk(disk, ctx.arena) catch |err| return library.fail(err);
        var out: Out = .{
            .new = 0,
            .added = 0,
            .missing = 0,
            .skipped = &.{},
            .skipped_count = 0,
            .more = walked.more,
        };
        var skipped: std.ArrayList(Skipped) = .empty;
        var folders: Folders = .{ .nodes = .empty };

        for (walked.found) |found| {
            if (try known(ctx, found.path)) {
                continue;
            }

            const reason = reason_of(found) orelse
                try take(ctx, disk, found.path, &folders, in.check);

            if (reason) |why| {
                out.skipped_count += 1;

                if (skipped.items.len < skipped_listed_max) {
                    try skipped.append(ctx.arena, .{ .path = found.path, .reason = why });
                }

                continue;
            }

            out.new += 1;
            out.added += @intFromBool(!in.check);
        }

        out.skipped = skipped.items;
        out.missing = try missing_of(ctx, disk, in.check);

        return out;
    }
};

const no_folder: sdk.operation.Failure = .{
    .name = "NoFolder",
    .status = 503,
    .message = "Only a server keeps a media folder to put files into",
};

fn known(ctx: *Ctx, path: []const u8) Error!bool {
    std.debug.assert(path.len > 0);

    if (path.len > 256) {
        return false;
    }

    return try store.media.by_key(ctx.db, ctx.arena, path) != null;
}

/// Why a file is left out before its bytes are read, if it is.
fn reason_of(found: dropped.Found) ?[]const u8 {
    std.debug.assert(found.path.len > 0);

    const slash = std.mem.lastIndexOfScalar(u8, found.path, '/');
    const filename = if (slash) |index| found.path[index + 1 ..] else found.path;

    if (media.kind_of(filename) == null) {
        return "not a type the library takes";
    }

    if (!media.valid_filename(filename)) {
        return "a name the library cannot keep";
    }

    if (found.size == 0) {
        return "empty";
    }

    if (found.size > files_module.bytes_max) {
        return "larger than 32 MiB";
    }

    return null;
}

/// Adds the file, kept where it lies when its path can be a key; or why it was left out.
/// A check reads and checks it the same way, and stops there.
fn take(
    ctx: *Ctx,
    disk: *files_module.Disk,
    path: []const u8,
    folders: *Folders,
    check: bool,
) Error!?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const limit = files_module.bytes_max;
    const bytes = dropped.read(disk, library.file_allocator, path, limit) catch |err| {
        return library.fail(err);
    };
    defer library.file_allocator.free(bytes);

    var directories: [media.folder_depth_max][]const u8 = undefined;
    const placed = media.placed_of(&directories, path);

    if (!media.matches(media.kind_of(placed.filename).?, bytes)) {
        return "its contents are not what its extension says";
    }

    const kept = upload.checked(ctx, placed.filename, bytes) catch |err| switch (err) {
        error.Invalid => return "an SVG that could not be cleaned",
        else => return err,
    };

    if (check) {
        return null;
    }

    const cleaned = !std.mem.eql(u8, kept, bytes);
    const key = if (files_module.valid_key(path) and !cleaned) path else try key_of(ctx, placed);

    if (cleaned) {
        const stored: files_module.Files = .{ .disk = disk };

        stored.write(.files, key, kept) catch |err| return library.fail(err);
        dropped.remove(disk, path);
    } else {
        dropped.adopt(disk, path, key) catch |err| return library.fail(err);
    }

    _ = try upload.added(ctx, .{
        .filename = placed.filename,
        .key = key,
        .bytes = kept,
        .folder = try folders.of(ctx, placed.folders),
        .unreviewed = true,
    });

    return null;
}

fn key_of(ctx: *Ctx, placed: media.Placed) Error![]const u8 {
    std.debug.assert(placed.filename.len > 0);

    var random_hex: [ids.len]u8 = undefined;
    var buffer: [files_module.key_len_max]u8 = undefined;
    const random = ids.random(ctx.io, &random_hex)[0..media.random_len];

    return ctx.arena.dupe(u8, media.key_of(&buffer, ctx.now_ms, placed.filename, random));
}

/// The library's folders by name and parent, made on the way when a directory names one
/// that is not there yet.
const Folders = struct {
    nodes: std.ArrayList(term.Node),
    loaded: bool = false,

    fn of(folders: *Folders, ctx: *Ctx, names: []const []const u8) Error!?[]const u8 {
        std.debug.assert(names.len <= media.folder_depth_max);

        if (names.len == 0) {
            return null;
        }

        if (!folders.loaded) {
            const tree = try registry.SDK.dispatch(ctx, term.Tree, .{
                .taxonomy = media.folders_handle,
            });

            try folders.nodes.appendSlice(ctx.arena, tree.terms);
            folders.loaded = true;
        }

        var parent: ?[]const u8 = null;

        for (names) |raw| {
            const wanted = std.mem.trim(u8, raw, " ");

            if (wanted.len == 0 or wanted.len > folder_name_len_max) {
                break;
            }

            parent = folders.named(wanted, parent) orelse try folders.made(ctx, wanted, parent);
        }

        return parent;
    }

    fn named(folders: *const Folders, wanted: []const u8, parent: ?[]const u8) ?[]const u8 {
        std.debug.assert(wanted.len > 0);

        for (folders.nodes.items) |node| {
            const same_parent = if (parent) |id|
                node.parent != null and std.mem.eql(u8, node.parent.?, id)
            else
                node.parent == null;

            if (same_parent and std.ascii.eqlIgnoreCase(node.title, wanted)) {
                return node.id;
            }
        }

        return null;
    }

    fn made(
        folders: *Folders,
        ctx: *Ctx,
        wanted: []const u8,
        parent: ?[]const u8,
    ) Error![]const u8 {
        std.debug.assert(wanted.len > 0 and wanted.len <= folder_name_len_max);

        const document = std.json.Stringify.valueAlloc(ctx.arena, .{ .name = wanted }, .{}) catch
            return error.OutOfMemory;
        const created = try registry.SDK.dispatch(ctx, term.Create, .{
            .taxonomy = media.folders_handle,
            .document = document,
            .status = "published",
            .parent = parent,
        });

        try folders.nodes.append(ctx.arena, .{
            .id = created.id,
            .parent = parent,
            .title = wanted,
            .slug = created.slug,
            .status = created.status,
            .depth = 0,
        });

        return created.id;
    }
};

/// How many of the library's files are gone from the folder, each marked so unless only
/// checking.
fn missing_of(ctx: *Ctx, disk: *files_module.Disk, check: bool) Error!u32 {
    std.debug.assert(kept_page > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    var missing: u32 = 0;
    var after: []const u8 = "";
    var pages: u32 = 0;

    // Bounded: every page moves past at least one record, and records are fewer than this.
    while (pages < 1 << 20) : (pages += 1) {
        const page = try store.media.kept_after(ctx.db, ctx.arena, after, kept_page);

        for (page) |kept| {
            const gone = !files_module.valid_key(kept.storage_key) or
                !dropped.exists(disk, kept.storage_key);

            missing += @intFromBool(gone);

            if (gone != kept.missing and !check) {
                try store.media.set_missing(ctx.db, kept.record, gone);
            }
        }

        if (page.len < kept_page) {
            break;
        }

        after = page[page.len - 1].record;
    }

    return missing;
}

test "sync: files put in by hand are checked, taken in, filed by directory, missing marked" {
    const encode = @import("../../lib/image/encode.zig");
    const media_operations = @import("../media.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var disk = try files_module.Disk.open(std.testing.io, root);
    defer disk.close();

    var system = harness.ctx(.system);
    system.files = .{ .disk = &disk };
    try registry.SDK.bootstrap(&system);

    const png = try encode.sample_png(std.testing.allocator, 8, 4);
    defer std.testing.allocator.free(png);

    const io = std.testing.io;

    try disk.root.createDirPath(io, "Photos/Trips");
    try disk.root.writeFile(io, .{ .sub_path = "Photos/Trips/Beach Day.png", .data = png });
    try disk.root.writeFile(io, .{ .sub_path = "cat.png", .data = png });
    try disk.root.writeFile(io, .{ .sub_path = "notes.docx", .data = "words" });
    try disk.root.writeFile(io, .{ .sub_path = "fake.png", .data = "not a png" });

    const checked = try registry.SDK.dispatch(&system, Sync, .{ .check = true });

    try std.testing.expectEqual(@as(u32, 2), checked.new);
    try std.testing.expectEqual(@as(u32, 0), checked.added);
    try std.testing.expectEqual(@as(u32, 2), checked.skipped_count);
    try std.testing.expect(!dropped.exists(&disk, "photos/trips/beach-day.png"));

    const synced = try registry.SDK.dispatch(&system, Sync, .{});

    try std.testing.expectEqual(@as(u32, 2), synced.added);
    try std.testing.expectEqual(@as(u32, 2), synced.skipped_count);
    try std.testing.expect(dropped.exists(&disk, "cat.png"));

    const unreviewed = try registry.SDK.dispatch(&system, media_operations.List, .{
        .folder = "unreviewed",
    });

    try std.testing.expectEqual(@as(u32, 2), unreviewed.total);
    try std.testing.expectEqual(@as(u32, 2), unreviewed.unreviewed);
    try std.testing.expectEqual(@as(usize, 2), unreviewed.folders.len);
    try std.testing.expectEqualStrings("Trips", unreviewed.folders[1].name);
    try std.testing.expectEqual(@as(u32, 1), unreviewed.folders[1].count);

    const again = try registry.SDK.dispatch(&system, Sync, .{ .check = true });

    try std.testing.expectEqual(@as(u32, 0), again.new);

    var cat_id: []const u8 = "";

    for (unreviewed.items) |item| {
        if (std.mem.eql(u8, item.key, "cat.png")) {
            cat_id = item.id;
        }
    }

    try std.testing.expect(cat_id.len > 0);
    try disk.root.deleteFile(io, "cat.png");

    const gone = try registry.SDK.dispatch(&system, Sync, .{});

    try std.testing.expectEqual(@as(u32, 1), gone.missing);
    try std.testing.expect((try registry.SDK.dispatch(&system, media_operations.Get, .{
        .id = cat_id,
    })).media.missing);

    _ = try registry.SDK.dispatch(&system, media_operations.Update, .{
        .id = cat_id,
        .alt = "A cat",
    });

    const left = try registry.SDK.dispatch(&system, media_operations.List, .{});

    try std.testing.expectEqual(@as(u32, 1), left.unreviewed);
}
