//! The term's status moves, declared; the bodies are the domain's `lifecycle`. Purging
//! adds what only a term has to check: children, and records filed under it.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const term_operations = @import("../term.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const lifecycle = term_operations.domain.lifecycle;
const Moved = @import("../document/lifecycle.zig").Moved;
const example_id = term_operations.example_id;
const example_changed_id = term_operations.example_changed_id;
const example_draft_id = term_operations.example_draft_id;

pub const Transition = struct {
    pub const name = "term.transition";
    pub const description = "Move a term to another status (publish, unpublish, archive, ...)";
    pub const details =
        \\As `record transition`: a registered move, into a live status applies pending
        \\edits, out of one keeps them. Bumps `version`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, to: []const u8, expected_version: ?i64 = null };
    pub const Out = struct { status: []const u8, changed: bool, version: i64 };
    pub const example: In = .{ .id = example_draft_id, .to = "published" };
    pub const example_out: Out = .{ .status = "published", .changed = false, .version = 2 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The term id",
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

fn moved_out(moved: Moved) Transition.Out {
    std.debug.assert(moved.status.len > 0);
    std.debug.assert(moved.version >= 1);

    return .{ .status = moved.status, .changed = moved.changed, .version = moved.version };
}

pub const Publish = struct {
    pub const name = "term.publish";
    pub const description = "Make the term's latest document live";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = Transition.Out;
    pub const example: In = .{ .id = example_changed_id };
    pub const example_out: Out = .{ .status = "published", .changed = false, .version = 2 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The term id",
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
    pub const name = "term.discard_changes";
    pub const description = "Drop a term's pending edits; the document stays as it is";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, expected_version: ?i64 = null };
    pub const Out = struct { version: i64 };
    pub const example: In = .{ .id = example_changed_id };
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
    pub const name = "term.delete";
    pub const description = "Move a term to `deleted` (reversible: transition back to draft)";
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
    pub const name = "term.purge";
    pub const description = "Remove a term for good; refused while it has children or records";
    pub const details =
        \\Admins only. A term with child terms, or one that records are filed under
        \\(directly or through a descendant), answers `conflict`: move the children and
        \\the records first.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { purged: bool };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .purged = true };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const load = term_operations.access.load;
        const row = try load(ctx, in.id, granted) orelse return error.NotFound;

        if (try store.terms.has_children(ctx.db, row.id)) {
            return error.Conflict;
        }

        if (try store.record_terms.assigned_count(ctx.db, row.id) > 0) {
            return error.Conflict;
        }

        return .{ .purged = try lifecycle.purge(ctx, granted, in.id) };
    }
};

const SDK = registry.SDK;

test "term lifecycle: pending edits, publish, delete; purge refuses children and members" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try term_operations.seed_topics(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    var anon = harness.ctx(.anonymous);
    const created = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"One\"}",
    });
    _ = try SDK.dispatch(&admin, Publish, .{ .id = created.id });

    const parked = try SDK.dispatch(&admin, term_operations.Save, .{
        .id = created.id,
        .document = "{\"name\":\"Two\"}",
    });
    try std.testing.expect(parked.changed);
    const public_view = try SDK.dispatch(&anon, term_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("One", public_view.term.title);
    const published = try SDK.dispatch(&admin, Publish, .{ .id = created.id });
    try std.testing.expect(!published.changed);
    const public_again = try SDK.dispatch(&anon, term_operations.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("Two", public_again.term.title);

    _ = try SDK.dispatch(&admin, term_operations.Save, .{
        .id = created.id,
        .document = "{\"name\":\"Three\"}",
    });
    _ = try SDK.dispatch(&admin, DiscardChanges, .{ .id = created.id });
    const kept = try SDK.dispatch(&admin, term_operations.Get, .{
        .id = created.id,
        .purpose = .edit,
    });
    try std.testing.expectEqualStrings("Two", kept.term.title);

    const child = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Child\"}",
        .parent = created.id,
    });
    try std.testing.expectError(error.Conflict, SDK.dispatch(&admin, Purge, .{ .id = created.id }));
    try std.testing.expect((try SDK.dispatch(&admin, Purge, .{ .id = child.id })).purged);

    const deleted = try SDK.dispatch(&admin, Delete, .{ .id = created.id });
    try std.testing.expectEqualStrings("deleted", deleted.status);
    const restored = try SDK.dispatch(&admin, Transition, .{ .id = created.id, .to = "draft" });
    try std.testing.expectEqualStrings("draft", restored.status);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, Purge, .{ .id = created.id }));
    try std.testing.expect((try SDK.dispatch(&admin, Purge, .{ .id = created.id })).purged);
    try std.testing.expectError(
        error.NotFound,
        SDK.dispatch(&admin, term_operations.Get, .{ .id = created.id }),
    );
}
