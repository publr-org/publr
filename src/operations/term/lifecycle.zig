//! The term's status moves, declared; the bodies are the domain's `lifecycle`. Purging
//! adds what only a term has to check: children, and records filed under it.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/term/lifecycle.zig");
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
    pub const shape = public.Transition;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const expected = in.expected_version;

        return moved_out(try lifecycle.transition(ctx, granted, in.id, in.transition, expected));
    }
};

fn moved_out(moved: Moved) Transition.Out {
    std.debug.assert(moved.status.len > 0);
    std.debug.assert(moved.version >= 1);

    return .{
        .status = moved.status,
        .changed = moved.changed,
        .version = moved.version,
    };
}

pub const Publish = struct {
    pub const shape = public.Publish;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return moved_out(try lifecycle.publish(ctx, granted, in.id, in.expected_version));
    }
};

pub const DiscardChanges = struct {
    pub const shape = public.DiscardChanges;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return .{
            .version = try lifecycle.discard(ctx, granted, in.id, in.expected_version),
        };
    }
};

pub const Delete = struct {
    pub const shape = public.Delete;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return moved_out(try lifecycle.delete(ctx, granted, in.id, in.expected_version));
    }
};

pub const Purge = struct {
    pub const shape = public.Purge;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const destroys = shape.destroys;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

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

        return .{
            .purged = try lifecycle.purge(ctx, granted, in.id),
        };
    }
};

const SDK = registry.SDK;

test "term lifecycle: pending edits, publish, delete; purge refuses children and members" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try term_operations.seed_topics(&harness);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var anon = harness.ctx(.anonymous);
    const created = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"name\":\"One\"}",
        },
    });
    _ = try SDK.dispatch(&admin, Publish, .{
        .id = created.id,
    });

    const parked = try SDK.dispatch(&admin, term_operations.Save, .{
        .id = created.id,
        .document = .{
            .text = "{\"name\":\"Two\"}",
        },
    });
    try std.testing.expect(parked.changed);
    const public_view = try SDK.dispatch(&anon, term_operations.Get, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("One", public_view.term.title);
    const published = try SDK.dispatch(&admin, Publish, .{
        .id = created.id,
    });
    try std.testing.expect(!published.changed);
    const public_again = try SDK.dispatch(&anon, term_operations.Get, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("Two", public_again.term.title);

    _ = try SDK.dispatch(&admin, term_operations.Save, .{
        .id = created.id,
        .document = .{
            .text = "{\"name\":\"Three\"}",
        },
    });
    _ = try SDK.dispatch(&admin, DiscardChanges, .{
        .id = created.id,
    });
    const kept = try SDK.dispatch(&admin, term_operations.Get, .{
        .id = created.id,
        .purpose = .edit,
    });
    try std.testing.expectEqualStrings("Two", kept.term.title);

    const child = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"name\":\"Child\"}",
        },
        .parent = created.id,
    });
    try std.testing.expectError(error.Conflict, SDK.dispatch(&admin, Purge, .{
        .id = created.id,
    }));
    try std.testing.expect((try SDK.dispatch(&admin, Purge, .{
        .id = child.id,
    })).purged);

    const deleted = try SDK.dispatch(&admin, Delete, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("trashed", deleted.status);
    const restored = try SDK.dispatch(&admin, Transition, .{
        .id = created.id,
        .transition = "restore",
    });
    try std.testing.expectEqualStrings("draft", restored.status);

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, Purge, .{
        .id = created.id,
    }));
    try std.testing.expect((try SDK.dispatch(&admin, Purge, .{
        .id = created.id,
    })).purged);
    try std.testing.expectError(
        error.NotFound,
        SDK.dispatch(&admin, term_operations.Get, .{
            .id = created.id,
        }),
    );
}
