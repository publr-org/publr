const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/media/view.zig");
const store = @import("../../store.zig");
const library = @import("library.zig");
const media_base = @import("../../sdk/media_base.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{View};

pub const View = struct {
    pub const shape = public.View;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.id.len == 0 or in.id.len > 64) {
            return error.Invalid;
        }

        const row = try store.media.get(ctx.db, ctx.arena, in.id) orelse return error.NotFound;

        if (row.private and (ctx.caller == .anonymous or library.public_only(granted))) {
            return error.NotFound;
        }

        // One row, nothing more: a page may show dozens of files within its render's
        // memory, so what is written about the file (its alt text) is not read here.
        const url = try media_base.url(ctx, row.storage_key);
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
