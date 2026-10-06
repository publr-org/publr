//! The record's status moves, declared; the bodies are the domain's `lifecycle`.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const lifecycle = record_operations.domain.lifecycle;
const example_id = "a1b2c3d4e5f60718293a4b5c";

pub const Transition = struct {
    pub const name = "record.transition";
    pub const description = "Move a record to another status (publish, unpublish, archive, ...)";
    pub const details =
        \\The move must be a registered transition (see `status list`) and the type
        \\must accept the target status. Moving into a live status applies pending
        \\edits first, like `record publish`; moving out of one keeps them parked.
        \\Bumps `version`; `expected_version` works as in save.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, to: []const u8, expected_version: ?i64 = null };
    pub const Out = struct { status: []const u8, changed: bool, version: i64 };
    pub const example: In = .{ .id = record_operations.example_draft_id, .to = "published" };
    pub const example_out: Out = .{ .status = "published", .changed = false, .version = 2 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .to = "The target status id",
        .expected_version = "The `version` you read; refuse if it changed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return moved_out(try lifecycle.transition(ctx, granted, in.id, in.to, in.expected_version));
    }
};

fn moved_out(moved: @import("../document/lifecycle.zig").Moved) Transition.Out {
    std.debug.assert(moved.status.len > 0);
    std.debug.assert(moved.version >= 1);

    return .{ .status = moved.status, .changed = moved.changed, .version = moved.version };
}

pub const Publish = struct {
    pub const name = "record.publish";
    pub const description = "Make the record's latest document live";
    pub const details =
        \\From a draft: the document goes live (`draft -> published`). From a live
        \\record with pending edits: the pending copy becomes the live document, the
        \\old one is kept as a revision snapshot, `changed` clears. Either way one
        \\`record.published` notice. Refused when there is nothing to publish.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = Transition.Out;
    pub const example: In = .{ .id = record_operations.example_changed_id };
    pub const example_out: Out = .{ .status = "published", .changed = false, .version = 2 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .expected_version = "The `version` you read; refuse if it changed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return moved_out(try lifecycle.publish(ctx, granted, in.id, in.expected_version));
    }
};

pub const DiscardChanges = struct {
    pub const name = "record.discard_changes";
    pub const description = "Drop a record's pending edits; the document stays as it is";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = struct { version: i64 };
    pub const example: In = .{ .id = record_operations.example_changed_id };
    pub const example_out: Out = .{ .version = 4 };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return .{ .version = try lifecycle.discard(ctx, granted, in.id, in.expected_version) };
    }
};

pub const Delete = struct {
    pub const name = "record.delete";
    pub const description = "Move a record to `deleted` (reversible: transition back to draft)";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = Transition.Out;
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .status = "deleted", .changed = false, .version = 2 };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return moved_out(try lifecycle.delete(ctx, granted, in.id, in.expected_version));
    }
};

pub const Purge = struct {
    pub const name = "record.purge";
    pub const description = "Remove a record for good: document, pending edits and snapshots";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { purged: bool };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .purged = true };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return .{ .purged = try lifecycle.purge(ctx, granted, in.id) };
    }
};

const SDK = registry.SDK;

test "pending edits: save on a live record parks, publish applies, discard drops, moves keep" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    var anon = harness.ctx(.anonymous);
    const created = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"One\",\"body\":\"first\"}",
    });
    _ = try SDK.dispatch(&editor, Publish, .{ .id = created.id });

    const parked = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Two\",\"body\":\"second\"}",
    });
    try std.testing.expect(parked.changed);
    const public_view = try SDK.dispatch(&anon, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("One", public_view.record.title);
    const editing = try SDK.dispatch(&editor, record_operations.Get, .{
        .id = created.id,
        .purpose = .edit,
    });
    try std.testing.expectEqualStrings("Two", editing.record.title);
    try std.testing.expectEqualStrings("pending", editing.slot);
    try std.testing.expect(editing.record.changed);

    const live_only = try SDK.dispatch(&anon, record_operations.List, .{
        .type = "post",
        .search = "second",
    });
    try std.testing.expectEqual(@as(usize, 0), live_only.records.len);
    const flagged = try SDK.dispatch(&editor, record_operations.List, .{
        .type = "post",
        .filters = &.{"changed:is:pending"},
    });
    try std.testing.expectEqual(@as(usize, 1), flagged.records.len);

    const unpublished = try SDK.dispatch(&editor, Transition, .{ .id = created.id, .to = "draft" });
    try std.testing.expect(unpublished.changed);
    const still_parked = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Three\",\"body\":\"third\"}",
    });
    try std.testing.expect(still_parked.changed);
    const own_view = try SDK.dispatch(&editor, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("One", own_view.record.title);

    const published = try SDK.dispatch(&editor, Publish, .{ .id = created.id });
    try std.testing.expect(!published.changed);
    try std.testing.expectEqualStrings("published", published.status);
    const public_again = try SDK.dispatch(&anon, record_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("Three", public_again.record.title);
    const nothing_to_publish = SDK.dispatch(&editor, Publish, .{ .id = created.id });
    try std.testing.expectError(error.Invalid, nothing_to_publish);

    _ = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Four\",\"body\":\"x\"}",
    });
    _ = try SDK.dispatch(&editor, DiscardChanges, .{ .id = created.id });
    const after = try SDK.dispatch(&editor, record_operations.Get, .{
        .id = created.id,
        .purpose = .edit,
    });
    try std.testing.expectEqualStrings("Three", after.record.title);
    try std.testing.expect(!after.record.changed);
    const nothing_to_discard = SDK.dispatch(&editor, DiscardChanges, .{ .id = created.id });
    try std.testing.expectError(error.Invalid, nothing_to_discard);

    const revisions = try store.snapshots.list(
        &harness.fixture.connection,
        harness.fixed.allocator(),
        created.id,
        "revision",
        10,
    );
    try std.testing.expectEqual(@as(usize, 1), revisions.len);
    try std.testing.expect(std.mem.indexOf(u8, revisions[0].document, "\"One\"") != null);

    const deleted = try SDK.dispatch(&editor, Delete, .{ .id = created.id });
    try std.testing.expectEqualStrings("deleted", deleted.status);
    const gone_for_anon = SDK.dispatch(&anon, record_operations.Get, .{ .id = created.id });
    try std.testing.expectError(error.NotFound, gone_for_anon);
    const restored = try SDK.dispatch(&editor, Transition, .{ .id = created.id, .to = "draft" });
    try std.testing.expectEqualStrings("draft", restored.status);
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, Purge, .{ .id = created.id }));

    var admin = harness.ctx(.{ .user = .{ .id = "u_ad", .roles = &.{"admin"} } });
    try std.testing.expect((try SDK.dispatch(&admin, Purge, .{ .id = created.id })).purged);
    const gone_for_good = SDK.dispatch(&admin, record_operations.Get, .{ .id = created.id });
    try std.testing.expectError(error.NotFound, gone_for_good);
}

test "SDK rejects oversized ids and invalid statuses without leaving a transaction open" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var ctx = harness.ctx(.system);
    const long = "x" ** 129;

    inline for (.{ Publish, DiscardChanges, Delete, Purge }) |Operation| {
        try std.testing.expectError(
            error.Invalid,
            registry.SDK.dispatch(
                &ctx,
                Operation,
                .{
                    .id = long,
                },
            ),
        );
        try std.testing.expectEqual(@as(u32, 0), ctx.db.transaction_depth);
    }

    for ([_][]const u8{ "", "x" ** 33 }) |status| {
        try std.testing.expectError(
            error.Invalid,
            registry.SDK.dispatch(
                &ctx,
                Transition,
                .{
                    .id = example_id,
                    .to = status,
                },
            ),
        );
        try std.testing.expectEqual(@as(u32, 0), ctx.db.transaction_depth);
    }
}

/// Notices kept on the call's trail, as the activity log would see them.
fn hear(ctx: *Ctx, notice: sdk.Event.Notice) void {
    std.debug.assert(notice.name.len > 0);
    std.debug.assert(ctx.trail != null);

    ctx.trail.?.noticed(ctx, .{ .name = notice.name, .subject = notice.subject });
}

fn heard(trail: *const sdk.trail.Trail, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(trail.root != 0);

    for (trail.notices.items) |notice| {
        if (std.mem.eql(u8, notice.name, name)) {
            return true;
        }
    }

    return false;
}

/// The record's live copy made `document` straight in the store, as a merge writes it.
fn replace_live(ctx: *Ctx, id: []const u8, document: []const u8) !void {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const row = (try store.records.get(ctx.db, ctx.arena, id)).?;
    const type_row = (try record_operations.domain.definition.find(ctx, row.type_id)).?;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, document, .{});

    const fields = type_row.def.fields;

    try store.values.write(registry.Kinds.all, ctx.db, id, "live", row.type_id, fields, value);
}

test "a document whose rows were replaced from outside lands as a person's move would" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    const created = try registry.SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"Hello\",\"slug\":\"hello\"}",
    });
    _ = try registry.SDK.dispatch(&system, Publish, .{ .id = created.id });
    const other = try registry.SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"Taken\",\"slug\":\"taken\"}",
    });
    _ = try registry.SDK.dispatch(&system, Publish, .{ .id = other.id });

    var trail: sdk.trail.Trail = .{ .root = 1 };

    system.parent = 1;
    system.trail = &trail;
    system.notify = hear;
    defer system.notify = null;

    // The live title replaced: a revision of the old one, saved and published.
    {
        var transaction = try system.db.transaction();
        defer transaction.rollback();

        const before = try lifecycle.landing(&system, created.id);

        try replace_live(&system, created.id, "{\"title\":\"Hi\",\"slug\":\"hello\"}");
        try lifecycle.landed(&system, created.id, before);

        const revisions = try store.snapshots.list(
            system.db,
            system.arena,
            created.id,
            store.snapshots.revision,
            8,
        );

        try std.testing.expect(heard(&trail, "record.saved"));
        try std.testing.expect(heard(&trail, "record.published"));
        try std.testing.expect(!heard(&trail, "record.transitioned"));
        try std.testing.expectEqual(@as(usize, 1), revisions.len);
    }

    // Taken back to a draft: the move's own notices.
    {
        trail.notices.clearRetainingCapacity();

        var transaction = try system.db.transaction();
        defer transaction.rollback();

        const before = try lifecycle.landing(&system, created.id);

        _ = try store.records.set_status(system.db, created.id, "draft", null, 1, null, false);
        try lifecycle.landed(&system, created.id, before);

        try std.testing.expect(heard(&trail, "record.transitioned"));
        try std.testing.expect(heard(&trail, "record.unpublished"));
    }

    // A slug another live document holds is refused.
    {
        var transaction = try system.db.transaction();
        defer transaction.rollback();

        const before = try lifecycle.landing(&system, created.id);

        try replace_live(&system, created.id, "{\"title\":\"Hello\",\"slug\":\"taken\"}");
        try std.testing.expectError(error.Conflict, lifecycle.landed(&system, created.id, before));
    }
}
