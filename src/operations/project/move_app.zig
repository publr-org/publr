//! Every record of an app handed on, when the app is renamed.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const record_operations = @import("../record.zig");
const record_app = @import("../record/app.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const MoveApp = struct {
    pub const name = "project.move_app";
    pub const description = "Hand every record of one app to another, after renaming it";
    pub const details =
        \\An app is known by its `.name`, so renaming it in `app.zon` leaves its records
        \\under the old name: this moves them to the new one, or with `to` empty makes
        \\them the project's own. Every record, whatever its type or status. Administrators
        \\only: it is the project's, not one record's.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { from: []const u8, to: []const u8 = "" };
    pub const Out = struct { moved: u32 };
    pub const example: In = .{ .from = "www", .to = "site" };
    pub const example_out: Out = .{ .moved = 42 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .from = "The app's old `.name`",
        .to = "Its new `.name`; empty for the project's own",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .moved = "How many records moved",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(granted.allows());

        const from = try record_app.app_or_project(in.from) orelse return error.Invalid;
        const to = try record_app.app_or_project(in.to);

        return .{ .moved = try store.records.move_app(ctx.db, from, to) };
    }
};

const SDK = registry.SDK;

test "move_app hands every record of an app to another, or to the project; admins only" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    var admin = harness.ctx(.{ .user = .{ .id = "u_ad", .roles = &.{"admin"} } });
    const created = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = record_operations.example_document,
        .app = "www",
    });

    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, MoveApp, .{ .from = "www" }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, MoveApp, .{ .from = "" }));

    const moved = try SDK.dispatch(&admin, MoveApp, .{ .from = "www", .to = "site" });
    try std.testing.expectEqual(1, moved.moved);
    const again = try SDK.dispatch(&editor, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("site", again.record.app.?);
    try std.testing.expectEqual(1, (try SDK.dispatch(&admin, MoveApp, .{ .from = "site" })).moved);
    const cleared = try SDK.dispatch(&editor, record_operations.Get, .{ .id = created.id });
    try std.testing.expect(cleared.record.app == null);
}
