const sdk = @import("../sdk.zig");

pub const library = @import("media/library.zig");
pub const upload = @import("media/upload.zig");
pub const list = @import("media/list.zig");
pub const edit = @import("media/edit.zig");
pub const serve = @import("media/serve.zig");
pub const tags = @import("media/tags.zig");

pub const namespace: sdk.operation.Namespace = .{
    .name = "media",
    .summary = "The media library: files, their folders and tags",
    .details =
    \\Every file is a published record of the core `media` type (title, alt text, caption,
    \\credit, focal point), filed in at most one folder (`media_folders`, nested) and under
    \\any tags (`media_tags`). The facts of the file itself (name, type, size, dimensions,
    \\key, hash) are the library's own, written on upload. The bytes are kept beside the
    \\database and served at `/media/<key>`, resized with `?w=`, `?h=`, `?fit=cover`, `?q=`.
    ,
};

pub const Item = library.Item;
pub const Upload = upload.Upload;
pub const Add = upload.Add;
pub const List = list.List;
pub const Get = edit.Get;
pub const Update = edit.Update;
pub const Delete = edit.Delete;
pub const Move = edit.Move;
pub const Tag = edit.Tag;
pub const File = serve.File;
pub const FolderDelete = serve.FolderDelete;

pub const operations = [_]type{ Upload, Add, List } ++ edit.operations ++ serve.operations;

pub const bootstrap = library.bootstrap;

test {
    @import("std").testing.refAllDecls(@This());
}

test "media: upload in pieces, list and count, write, tag, move, fold a folder, delete" {
    const std = @import("std");
    const registry = @import("../server/registry.zig");
    const term = @import("term.zig");
    const files_module = @import("../lib/files.zig");
    const encode = @import("../lib/image/encode.zig");
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

    const photos = try registry.SDK.dispatch(&system, term.Create, .{
        .taxonomy = "media_folders",
        .document = "{\"name\":\"Photos\"}",
        .status = "published",
    });
    const trips = try registry.SDK.dispatch(&system, term.Create, .{
        .taxonomy = "media_folders",
        .document = "{\"name\":\"Trips\"}",
        .status = "published",
        .parent = photos.id,
    });
    const png = try encode.sample_png(std.testing.allocator, 8, 4);
    defer std.testing.allocator.free(png);

    // What `/media/upload` leaves before it calls the operation: the bytes, under a token.
    try system.files.?.write(.incoming, "upload0001", png);

    const harbour = try registry.SDK.dispatch(&system, Upload, .{
        .upload = "upload0001",
        .filename = "Harbour.png",
        .folder = trips.id,
    });

    try std.testing.expectEqualStrings("Harbour", harbour.title);
    try std.testing.expectEqual(@as(?u32, 8), harbour.width);
    try std.testing.expectEqualStrings("image", harbour.family);
    try std.testing.expectError(
        error.NotFound,
        system.files.?.read(std.testing.allocator, .incoming, "upload0001", 1024),
    );
    try system.files.?.write(.incoming, "upload0002", "plain words");

    const notes = try registry.SDK.dispatch(&system, Upload, .{
        .upload = "upload0002",
        .filename = "notes.txt",
    });

    try system.files.?.write(.incoming, "upload0003", "not a png");
    try std.testing.expectError(error.Failed, registry.SDK.dispatch(&system, Upload, .{
        .upload = "upload0003",
        .filename = "fake.png",
    }));
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&system, Upload, .{
        .upload = "upload0009",
        .filename = "gone.png",
    }));

    const everything = try registry.SDK.dispatch(&system, List, .{});

    try std.testing.expectEqual(@as(u32, 2), everything.total);
    try std.testing.expectEqual(@as(u32, 1), everything.unsorted);
    try std.testing.expectEqual(@as(usize, 2), everything.folders.len);
    try std.testing.expectEqual(@as(u32, 1), everything.folders[0].count);
    try std.testing.expectEqual(@as(u32, 1), everything.folders[1].depth);

    const in_photos = try registry.SDK.dispatch(&system, List, .{ .folder = photos.id });

    try std.testing.expectEqual(@as(u32, 1), in_photos.total);
    try std.testing.expectEqualStrings(harbour.id, in_photos.items[0].id);

    _ = try registry.SDK.dispatch(&system, Update, .{
        .id = harbour.id,
        .alt = "Boats at dawn",
        .focal_x = 30,
        .tags = &.{ "Sea", "boats" },
    });

    const detail = try registry.SDK.dispatch(&system, Get, .{ .id = harbour.id });

    try std.testing.expectEqualStrings("Boats at dawn", detail.alt);
    try std.testing.expectEqual(@as(u8, 30), detail.focal_x);
    try std.testing.expectEqual(@as(u8, 50), detail.focal_y);
    try std.testing.expectEqualStrings(trips.id, detail.folder.?);
    try std.testing.expectEqual(@as(usize, 2), detail.tags.len);

    const tagged = try registry.SDK.dispatch(&system, Tag, .{
        .ids = &.{ harbour.id, notes.id },
        .tag = "sea",
    });

    try std.testing.expectEqual(@as(u32, 1), tagged.changed);

    const sea = detail.tags[0].id;
    const boats = detail.tags[1].id;
    const both = try registry.SDK.dispatch(&system, List, .{ .tags = &.{ sea, boats } });
    const only_sea = try registry.SDK.dispatch(&system, List, .{ .tags = &.{sea} });

    try std.testing.expectEqual(@as(u32, 1), both.total);
    try std.testing.expectEqual(@as(u32, 2), only_sea.total);

    const searched = try registry.SDK.dispatch(&system, List, .{ .search = "harb" });

    try std.testing.expectEqual(@as(u32, 1), searched.total);

    _ = try registry.SDK.dispatch(&system, FolderDelete, .{ .folder = trips.id });

    const moved_up = try registry.SDK.dispatch(&system, Get, .{ .id = harbour.id });

    try std.testing.expectEqualStrings(photos.id, moved_up.folder.?);

    _ = try registry.SDK.dispatch(&system, Move, .{ .ids = &.{harbour.id}, .folder = "" });

    const unsorted = try registry.SDK.dispatch(&system, List, .{ .folder = "unsorted" });

    try std.testing.expectEqual(@as(u32, 2), unsorted.total);

    const served = try registry.SDK.dispatch(&system, File, .{ .key = harbour.key });

    try std.testing.expectEqualStrings("image/png", served.mime_type);
    try std.testing.expectEqual(@as(u8, 30), served.focal_x);

    _ = try registry.SDK.dispatch(&system, Delete, .{ .ids = &.{ harbour.id, notes.id } });

    const emptied = try registry.SDK.dispatch(&system, List, .{});

    try std.testing.expectEqual(@as(u32, 0), emptied.total);
    try std.testing.expectError(
        error.NotFound,
        system.files.?.read(std.testing.allocator, .files, harbour.key, 1024),
    );
}
