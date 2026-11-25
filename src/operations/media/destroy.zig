const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const record = @import("../record.zig");
const library = @import("library.zig");
const edit = @import("edit.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Destroy = struct {
    pub const name = "media.destroy";
    pub const description = "Delete files for good, freeing their space";
    pub const details =
        \\Each file goes with its record, its bytes and its resized copies, and nothing is kept
        \\in the trash: it can never be restored. Only a person does it, in the admin; a device
        \\lists it for its person instead. A file a record still points at is refused like any
        \\record that is referenced.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        ids: []const []const u8,
    };
    pub const Out = struct {
        destroyed: u32,
    };
    pub const example: In = .{
        .ids = &.{library.example_item.id},
    };
    pub const example_out: Out = .{
        .destroyed = 1,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .ids = "The files' record ids, up to 200",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .destroyed = "How many files went",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.ids.len == 0 or in.ids.len > edit.ids_max) {
            return error.Invalid;
        }

        const files = try library.files_of(ctx);
        var keys: [edit.ids_max][]const u8 = undefined;

        // Every record first, so a refusal (a file still in use) leaves every byte in place.
        for (in.ids, 0..) |id, index| {
            const row = try library.row_of(ctx, id);

            keys[index] = row.storage_key;
            _ = try registry.SDK.dispatch(ctx, record.Purge, .{
                .id = row.record,
            });
        }

        for (keys[0..in.ids.len]) |key| {
            files.remove(.files, key);
            files.clear_copies(key);
        }

        return .{
            .destroyed = @intCast(in.ids.len),
        };
    }
};

test "media destroy: record, bytes and copies go, nothing in the trash, a device may not" {
    const files_module = @import("../../lib/files.zig");
    const upload = @import("upload.zig");
    const trash = @import("../trash.zig");
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
    try system.files.?.write(.incoming, "upload0001", "plain words");

    const notes = try registry.SDK.dispatch(&system, upload.Upload, .{
        .upload = "upload0001",
        .filename = "notes.txt",
    });

    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&system, Destroy, .{
        .ids = &.{},
    }));

    const destroyed = try registry.SDK.dispatch(&system, Destroy, .{
        .ids = &.{notes.id},
    });

    try std.testing.expectEqual(@as(u32, 1), destroyed.destroyed);
    try std.testing.expectError(
        error.NotFound,
        system.files.?.read(std.testing.allocator, .files, notes.key, 1024),
    );
    try std.testing.expectError(
        error.NotFound,
        system.files.?.read(std.testing.allocator, .trash, notes.key, 1024),
    );
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&system, edit.Get, .{
        .id = notes.id,
    }));

    const kept = try registry.SDK.dispatch(&system, trash.List, .{});

    try std.testing.expectEqual(@as(usize, 0), kept.entries.len);
    try std.testing.expect(sdk.operation.destroys(Destroy));
}
