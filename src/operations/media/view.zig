const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const library = @import("library.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{View};

pub const View = struct {
    pub const name = "media.view";
    pub const description = "What a page needs to show a file: its address, size and alt text";
    pub const details =
        \\By the id a media field holds. Anyone may ask about a public file, as anyone may
        \\load it from `/media/<key>`; a private one answers not found to callers who are not
        \\signed in, as one that does not exist. `url` takes `?w=`, `?h=`, `?fit=cover` and
        \\`?q=` to resize. Light enough for a page to ask for dozens: the alt text is not
        \\read (a page writes its own, from the record it shows); `alt` is empty.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        id: []const u8,
        url: []const u8,
        key: []const u8,
        alt: []const u8,
        title: []const u8,
        mime_type: []const u8,
        width: ?i64 = null,
        height: ?i64 = null,
    };
    pub const example: In = .{
        .id = library.example_item.id,
    };
    pub const example_out: Out = .{
        .id = library.example_item.id,
        .url = "/media/" ++ library.example_item.key,
        .key = library.example_item.key,
        .alt = "",
        .title = "harbour",
        .mime_type = "image/jpeg",
        .width = 1600,
        .height = 1067,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The file's id: what a media field holds",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The file's id",
        .url = "Its address on this site; add ?w=, ?h=, ?fit=cover to resize",
        .key = "Its key, as in its address",
        .alt = "What it shows, for people who cannot see it",
        .title = "Its title, else its file name",
        .mime_type = "Its type",
        .width = "Its width in pixels, for an image",
        .height = "Its height in pixels, for an image",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.id.len == 0 or in.id.len > 64) {
            return error.Invalid;
        }

        const row = try store.media.get(ctx.db, ctx.arena, in.id) orelse return error.NotFound;

        if (row.private and ctx.caller == .anonymous) {
            return error.NotFound;
        }

        // One row, nothing more: a page may show dozens of files within its render's
        // memory, so what is written about the file (its alt text) is not read here.
        const url = try std.mem.concat(ctx.arena, u8, &.{ "/media/", row.storage_key });
        const dot = std.mem.lastIndexOfScalar(u8, row.filename, '.') orelse row.filename.len;

        return .{
            .id = row.record,
            .url = url,
            .key = row.storage_key,
            .alt = "",
            .title = row.filename[0..dot],
            .mime_type = row.mime_type,
            .width = row.width,
            .height = row.height,
        };
    }
};

test "a page shows a public file to anyone, a private one only to signed-in people" {
    const registry = @import("../../server/registry.zig");
    const upload = @import("upload.zig");
    const files_module = @import("../../lib/files.zig");
    const encode = @import("../../lib/image/encode.zig");
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
    system.files = .{
        .disk = &disk,
    };
    try registry.SDK.bootstrap(&system);

    const png = try encode.sample_png(std.testing.allocator, 8, 4);
    defer std.testing.allocator.free(png);

    try system.files.?.write(.incoming, "upload0002", png);

    const added = try registry.SDK.dispatch(&system, upload.Upload, .{
        .upload = "upload0002",
        .filename = "Pancakes.png",
    });
    var visitor = harness.ctx(.anonymous);
    const seen = try registry.SDK.dispatch(&visitor, View, .{
        .id = added.id,
    });

    try std.testing.expectEqualStrings(added.key, seen.key);
    try std.testing.expect(std.mem.startsWith(u8, seen.url, "/media/"));
    try std.testing.expectEqual(@as(?i64, 8), seen.width);

    try store.media.set_private(&harness.fixture.connection, added.id, true);
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&visitor, View, .{
        .id = added.id,
    }));
    _ = try registry.SDK.dispatch(&system, View, .{
        .id = added.id,
    });
}
