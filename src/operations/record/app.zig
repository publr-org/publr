//! Which app a record belongs to, declared.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const example_id = "a1b2c3d4e5f60718293a4b5c";

pub const SetApp = struct {
    pub const name = "record.set_app";
    pub const description = "Say which app a record belongs to, or that it is the project's own";
    pub const details =
        \\`app` is an app's `.name` from its `app.zon`; empty makes the record the
        \\project's own. It only decides where the admin shows the record: every app still
        \\reads what it may. Not a document change: `version` stays, nothing is published,
        \\and an editor's open copy stays current. Refused for a record the caller may
        \\not see.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, app: []const u8 = "" };
    pub const Out = struct { app: ?[]const u8 };
    pub const example: In = .{ .id = example_id, .app = "www" };
    pub const example_out: Out = .{ .app = "www" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .app = "The app's `.name`; empty for the project's own",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .app = "The app it belongs to now; null for the project's own",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(granted.allows());

        const app = try app_or_project(in.app);
        const found = try record_operations.access.load(ctx, in.id, granted);

        if (found == null) {
            return error.NotFound;
        }

        try store.records.set_app(ctx.db, in.id, app);

        return .{ .app = app };
    }
};

/// An app's name, or null for the project's own (empty); anything else is refused.
pub fn app_or_project(app: []const u8) Error!?[]const u8 {
    std.debug.assert(model.app.name_len_max > 0);

    if (app.len == 0) {
        return null;
    }

    if (!model.app.valid_name(app)) {
        return error.Invalid;
    }

    return app;
}

const SDK = registry.SDK;

test "a record belongs to the app it was made in, to the one named, or to the project" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    const document = record_operations.example_document;
    const own = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = document,
    });
    const named = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = document,
        .app = "saas",
    });
    try std.testing.expectError(error.Invalid, SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = document,
        .app = "Not An App",
    }));

    editor.app = "www";
    const made_there = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = document,
    });
    const told_otherwise = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = document,
        .app = "",
    });
    editor.app = "";

    const Get = record_operations.Get;
    try std.testing.expect((try SDK.dispatch(&editor, Get, .{ .id = own.id })).record.app == null);
    try std.testing.expectEqualStrings(
        "saas",
        (try SDK.dispatch(&editor, Get, .{ .id = named.id })).record.app.?,
    );
    try std.testing.expectEqualStrings(
        "www",
        (try SDK.dispatch(&editor, Get, .{ .id = made_there.id })).record.app.?,
    );
    try std.testing.expect(
        (try SDK.dispatch(&editor, Get, .{ .id = told_otherwise.id })).record.app == null,
    );
}

test "set_app moves one record without a new version, within what the caller may see" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    var anonymous = harness.ctx(.anonymous);
    const created = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = record_operations.example_document,
    });
    const set = try SDK.dispatch(&editor, SetApp, .{ .id = created.id, .app = "www" });

    try std.testing.expectEqualStrings("www", set.app.?);
    const got = try SDK.dispatch(&editor, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqual(1, got.record.version);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&editor, SetApp, .{
        .id = "a1b2c3d4e5f60718293a4b5c",
        .app = "www",
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&editor, SetApp, .{
        .id = created.id,
        .app = "no spaces",
    }));
    try std.testing.expectError(error.Denied, SDK.dispatch(&anonymous, SetApp, .{
        .id = created.id,
    }));
}

test "an app's plugins: a type another plugin owns is out of reach, the project's own never" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var order = model.content_type.test_post;
    order.handle = "order";
    order.name = "Order";
    order.system = true;
    order.owner = "shop";
    const types = @import("../content_type.zig");
    _ = try SDK.dispatch(&system, types.Create, .{
        .definition = try model.content_type.encode(system.arena, order),
    });

    const document = "{\"title\":\"Mine\"}";
    const bought = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "order",
        .document = document,
    });
    _ = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = document,
    });

    var site = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    site.app_plugins = &.{"newsletter"};
    const listed = try SDK.dispatch(&site, record_operations.List, .{});
    try std.testing.expectEqual(1, listed.records.len);
    try std.testing.expectEqualStrings("post", listed.records[0].type);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&site, record_operations.Get, .{
        .id = bought.id,
    }));

    for ((try SDK.dispatch(&site, types.List, .{})).types) |summary| {
        try std.testing.expect(!std.mem.eql(u8, summary.handle, "order"));
    }

    var shop = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    shop.app_plugins = &.{"shop"};
    const everything = try SDK.dispatch(&shop, record_operations.List, .{});
    try std.testing.expectEqual(2, everything.records.len);
    _ = try SDK.dispatch(&shop, record_operations.Get, .{ .id = bought.id });
}
