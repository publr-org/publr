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
    pub const description = "Move a record by a transition of its type's flow: publish, " ++
        "archive, ...";
    pub const details =
        \\Names the transition, never the status: `publish`, `archive`, a type's own
        \\(`submit`), `trash` and `restore`. Refused unless the record is in one of the
        \\transition's `from` statuses and you pass the transition's own `authorize`.
        \\Moving into a live status applies pending edits first, like `record publish`;
        \\moving out of one keeps them parked. Bumps `version`; `expected_version` works as
        \\in save. Without the right to publish (`record publish`), a transition into or out
        \\of a live status, `destroy`, and `publish` of a live record's changes are asked
        \\for instead: `pending`, the record as it was, the request kept on it until someone
        \\who may runs it or `record decline_request` drops it.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        transition: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        status: []const u8,
        changed: bool,
        version: i64,
        /// The transition waits for a person: the caller may only draft.
        pending: bool = false,
    };
    pub const example: In = .{
        .id = record_operations.example_draft_id,
        .transition = "publish",
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 2,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .transition = "The transition's name, `publish`",
        .expected_version = "The `version` you read; refuse if it changed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const expected = in.expected_version;
        const moved = try lifecycle.transition(ctx, granted, in.id, in.transition, expected);

        return moved_out(moved);
    }
};

pub const TransitionAt = struct {
    pub const name = "record.transition_at";
    pub const description = "Schedule a transition of a record for a moment: publish on " ++
        "5 Nov at 9:00";
    pub const details =
        \\A person schedules it; at that moment the server makes it as them, with the rights
        \\they hold then, as `record transition` would. A record may have any number
        \\scheduled, each its own entry (`scheduled` in `record get`) on a `base`: what is
        \\live, or another scheduled change it builds on (never earlier than it). `publish`
        \\on a live record schedules its changes: the pending ones on what is live, or the
        \\draft on `base` (`record save_version`); only the fields they change go live at
        \\its moment (`record publish` with `changes`). Changes on the same base never share
        \\a field: changing it again is a change on top of the one that has it. Nothing
        \\changed is refused. No `at` cancels every one of this transition. Never early;
        \\about a minute late at most. One refused then stays `failed`, with why.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        transition: []const u8,
        /// When, in ms; null cancels every one of this transition.
        at: ?i64 = null,
        /// The scheduled change it builds on (its draft is what `publish` schedules); 0 for
        /// what is live.
        base: i64 = 0,
    };
    pub const Out = struct {
        /// Whether one was scheduled.
        scheduled: bool,
        /// Its entry, for `record unschedule`; 0 when cancelled.
        entry: i64 = 0,
    };
    pub const example: In = .{
        .id = record_operations.example_draft_id,
        .transition = "publish",
        .at = 1_792_405_800_000,
    };
    pub const example_out: Out = .{
        .scheduled = true,
        .entry = 1,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .transition = "The transition's name, `publish`",
        .at = "When, in ms since 1970; leave it out to cancel every one of this transition",
        .base = "The scheduled change it builds on; leave it out for what is live",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .scheduled = "Whether one was scheduled",
        .entry = "The entry's id, for `record unschedule`",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64 or in.transition.len == 0) {
            return error.Invalid;
        }

        // Scheduled by a person, made as them: nobody else's rights are kept for later.
        const person = ctx.caller.user_id() orelse return error.Denied;

        // Only a record the person reaches.
        _ = try registry.SDK.call(ctx, record_operations.Get, .{
            .id = in.id,
        });

        const scheduled = store.scheduled_changes;
        const at = in.at orelse {
            _ = try scheduled.remove_transition(ctx.db, in.id, in.transition);

            return .{
                .scheduled = false,
            };
        };

        if (try scheduled.count(ctx.db, in.id) >= scheduled.record_max) {
            return error.Invalid;
        }

        const base: ?i64 = if (in.base > 0) in.base else null;
        var entry: store.scheduled_changes.Entry = .{
            .record_id = in.id,
            .transition = in.transition,
            .base_id = base,
            .due_at = @max(at, ctx.now_ms),
            .scheduled_by = person,
            .scheduled_at = ctx.now_ms,
        };

        if (base) |on| {
            try after_base(ctx, in.id, on, entry.due_at);
        }

        if (!std.mem.eql(u8, in.transition, "publish")) {
            return .{
                .scheduled = true,
                .entry = try scheduled.add(ctx.db, entry),
            };
        }

        if (base) |on| {
            return .{
                .scheduled = true,
                .entry = try take_draft(ctx, in.id, on, entry),
            };
        }

        try take_changes(ctx, granted, in.id, &entry);

        return .{
            .scheduled = true,
            .entry = try scheduled.add(ctx.db, entry),
        };
    }

    /// Refused unless the base is a waiting change no later than `due_at`.
    fn after_base(ctx: *Ctx, id: []const u8, base: i64, due_at: i64) Error!void {
        std.debug.assert(id.len > 0);
        std.debug.assert(base > 0);

        const versions = @import("versions.zig");
        const found = try versions.find(ctx, id, base) orelse return error.NotFound;
        const on = found.entries[found.index];

        if (!std.mem.eql(u8, on.state, "waiting")) {
            return error.Invalid;
        }

        if (due_at < on.due_at) {
            return ctx.refuse(&.{.{
                .field = "at",
                .message = "Not before the change it builds on",
            }});
        }
    }

    /// The draft on `base` scheduled: the edits made on top of it, checked against the
    /// changes beside it; its id.
    fn take_draft(
        ctx: *Ctx,
        id: []const u8,
        base: i64,
        entry: store.scheduled_changes.Entry,
    ) Error!i64 {
        std.debug.assert(id.len > 0);
        std.debug.assert(base > 0);

        const versions = @import("versions.zig");
        const entries = try store.scheduled_changes.of_record(ctx.db, ctx.arena, id);
        const draft = versions.draft_on(entries, base) orelse {
            return ctx.refuse(&.{.{
                .field = "transition",
                .message = "Nothing to schedule: change something first",
            }});
        };
        const keys = (try versions.parsed_changes(ctx, draft.changes)).keys();

        if (try versions.clash(ctx, entries, base, keys, null)) |found| {
            return versions.refuse_clash(ctx, found);
        }

        const made = try store.scheduled_changes.schedule_draft(
            ctx.db,
            draft.id,
            entry.due_at,
            entry.scheduled_by,
            ctx.now_ms,
        );

        if (!made) {
            return error.NotFound;
        }

        return draft.id;
    }

    /// A live record's pending changes, into `entry`: the fields they change and what it
    /// holds back then, checked as publishing them would be and against the changes
    /// scheduled on what is live; its pending copy cleared. A record not live is published
    /// whole, as a transition.
    fn take_changes(
        ctx: *Ctx,
        granted: *const Grant,
        id: []const u8,
        entry: *store.scheduled_changes.Entry,
    ) Error!void {
        std.debug.assert(id.len > 0);
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const domain = record_operations.domain;
        const row = try domain.access.load(ctx, id, granted) orelse return error.NotFound;
        const def = (try domain.definition.find(ctx, row.type_id) orelse {
            return error.NotFound;
        }).def;

        if (!def.flow.is_live(row.status)) {
            return;
        }

        if (!row.changed) {
            return ctx.refuse(&.{.{
                .field = "transition",
                .message = "Nothing to schedule: change something first",
            }});
        }

        const values = domain.values;
        const live = try domain.document.document_of(ctx, row.id, values.live, def);
        const pending = try domain.document.document_of(ctx, row.id, values.pending, def);
        const change_set = @import("../../model.zig").change_set;
        const changes = change_set.between(ctx.arena, live, pending) catch {
            return error.OutOfMemory;
        };
        const versions = @import("versions.zig");
        const entries = try store.scheduled_changes.of_record(ctx.db, ctx.arena, id);

        if (try versions.clash(ctx, entries, null, changes.keys(), null)) |found| {
            return versions.refuse_clash(ctx, found);
        }

        try domain.lifecycle.check_references(ctx, row, values.pending);

        entry.changes = std.json.Stringify.valueAlloc(ctx.arena, std.json.Value{
            .object = changes,
        }, .{}) catch return error.OutOfMemory;
        entry.held_back = row.pending_held_back;

        try values.clear(ctx.db, row.id, values.pending);
        try store.records.hold_back(ctx.db, row.id, null, .pending);
        _ = try store.records.save(ctx.db, row.id, ctx.author(), null, ctx.now_ms, false);
    }
};

pub const Unschedule = struct {
    pub const name = "record.unschedule";
    pub const description = "Drop one thing scheduled for a record";
    pub const details =
        \\Takes the entry's id from `scheduled` in `record get`; a failed one is dropped the
        \\same way. The changes a scheduled publish kept go with it. Not found when the
        \\record has no such entry.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        entry: i64,
    };
    pub const Out = struct {
        removed: bool,
    };
    pub const example: In = .{
        .id = record_operations.example_scheduled_id,
        .entry = 1,
    };
    pub const example_out: Out = .{
        .removed = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .entry = "The entry's id",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .removed = "Always true; not found otherwise",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64 or in.entry <= 0) {
            return error.Invalid;
        }

        _ = try registry.SDK.call(ctx, record_operations.Get, .{
            .id = in.id,
        });

        const versions = @import("versions.zig");
        const found = try versions.find(ctx, in.id, in.entry) orelse return error.NotFound;

        try versions.dropped(ctx, in.id, found.entries[found.index]);

        if (!try store.scheduled_changes.remove(ctx.db, in.id, in.entry)) {
            return error.NotFound;
        }

        return .{
            .removed = true,
        };
    }
};

/// `record publish` with `changes`: those fields, and `held_back`, published over what is live.
fn publish_set(
    ctx: *Ctx,
    granted: *const Grant,
    in: Publish.In,
) Error!@import("../document/lifecycle.zig").Moved {
    std.debug.assert(in.id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const text = in.changes orelse "{}";
    const parsed = @import("../../lib/json.zig").parse(std.json.Value, ctx.arena, text, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    if (in.held_back) |held_back| {
        var parts = std.mem.splitScalar(u8, held_back, ';');

        while (parts.next()) |part| {
            if (held_back.len > 0 and @import("../../model.zig").dimension.parse(part) == null) {
                return error.Invalid;
            }
        }
    }

    return lifecycle.publish_set(ctx, granted, in.id, parsed.object, in.held_back);
}

pub const RunScheduled = struct {
    pub const name = "record.run_scheduled";
    pub const description = "Make the next thing scheduled for a record now";
    pub const details =
        \\Only the record's next waiting entry (the first in `scheduled` from `record get`):
        \\one further on would run before what is scheduled ahead of it. Made now as you,
        \\with your rights, exactly as it would be at its time (`record publish` with its
        \\changes, or its transition), then dropped; the rest keep their times.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        entry: i64,
    };
    pub const Out = Transition.Out;
    pub const example: In = .{
        .id = record_operations.example_scheduled_id,
        .entry = 1,
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 3,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .entry = "The next entry's id; any other is refused",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64 or in.entry <= 0) {
            return error.Invalid;
        }

        _ = try registry.SDK.call(ctx, record_operations.Get, .{
            .id = in.id,
        });

        const scheduled = store.scheduled_changes;
        const next = try scheduled.next_of(ctx.db, ctx.arena, in.id) orelse {
            return error.NotFound;
        };

        if (next.id != in.entry) {
            return ctx.refuse(&.{.{
                .field = "entry",
                .message = "Only the next scheduled one runs now",
            }});
        }

        const out = if (next.changes.len > 0 or next.held_back != null)
            try registry.SDK.call(ctx, Publish, .{
                .id = in.id,
                .changes = if (next.changes.len > 0) next.changes else null,
                .held_back = next.held_back,
            })
        else
            try registry.SDK.call(ctx, Transition, .{
                .id = in.id,
                .transition = next.transition,
            });

        try scheduled.made(ctx.db, next.id);
        try @import("versions.zig").settled(ctx, in.id, next.id);

        return out;
    }
};

pub const Reschedule = struct {
    pub const name = "record.reschedule";
    pub const description = "Move something scheduled for a record to another moment";
    pub const details =
        \\A waiting entry from `scheduled` in `record get`, to `at`; what it makes stays
        \\as it is. Not found for a failed one or one already made.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        entry: i64,
        at: i64,
    };
    pub const Out = struct {
        moved: bool,
    };
    pub const example: In = .{
        .id = record_operations.example_scheduled_id,
        .entry = 1,
        .at = 1_792_405_800_000,
    };
    pub const example_out: Out = .{
        .moved = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .entry = "The entry's id",
        .at = "When, in ms since 1970",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .moved = "Always true; not found otherwise",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64 or in.entry <= 0 or in.at < 0) {
            return error.Invalid;
        }

        _ = ctx.caller.user_id() orelse return error.Denied;
        _ = try registry.SDK.call(ctx, record_operations.Get, .{
            .id = in.id,
        });

        const at = @max(in.at, ctx.now_ms);

        if (!try store.scheduled_changes.retime(ctx.db, in.id, in.entry, at)) {
            return error.NotFound;
        }

        return .{
            .moved = true,
        };
    }
};

fn moved_out(moved: @import("../document/lifecycle.zig").Moved) Transition.Out {
    std.debug.assert(moved.status.len > 0);
    std.debug.assert(moved.version >= 1);

    return .{
        .status = moved.status,
        .changed = moved.changed,
        .version = moved.version,
        .pending = moved.pending,
    };
}

pub const Publish = struct {
    pub const name = "record.publish";
    pub const description = "Make the record's latest document live";
    pub const details =
        \\From a draft: the document goes live (`draft -> published`). From a live
        \\record with pending edits: the pending copy becomes the live document, the
        \\old one is kept as a revision snapshot, `changed` clears. From a draft the move
        \\also raises the type's transition event. Refused when there is nothing to publish.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
        /// Only these fields, over what is live: a JSON object of each key and its value.
        changes: ?[]const u8 = null,
        /// What it holds back with them; null leaves it as it is.
        held_back: ?[]const u8 = null,
    };
    pub const Out = Transition.Out;
    pub const example: In = .{
        .id = record_operations.example_changed_id,
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 2,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .expected_version = "The `version` you read; refuse if it changed",
        .changes = "Publish only these fields onto what is live, a JSON object " ++
            "(`{\"title\":\"Deal\"}`, null empties one); pending edits stay parked",
        .held_back = "With `changes`: what it holds back once published, `;` between",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const published = if (in.changes != null or in.held_back != null)
            try publish_set(ctx, granted, in)
        else
            try lifecycle.publish(ctx, granted, in.id, in.expected_version);

        try registry.SDK.jobs.follow(ctx, in.id);

        return moved_out(published);
    }
};

pub const DiscardChanges = struct {
    pub const name = "record.discard_changes";
    pub const description = "Drop a record's pending edits; the document stays as it is";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        version: i64,
    };
    pub const example: In = .{
        .id = record_operations.example_changed_id,
    };
    pub const example_out: Out = .{
        .version = 4,
    };

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
    pub const name = "record.delete";
    pub const description = "Move a record to the trash (restorable: the `restore` transition)";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        expected_version: ?i64 = null,
    };
    pub const Out = struct {
        status: []const u8,
        changed: bool,
        version: i64,
        /// The record's type: its list is where a person deleting it goes back to.
        type: []const u8,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .status = "trashed",
        .changed = false,
        .version = 2,
        .type = "post",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const moved = moved_out(try lifecycle.delete(ctx, granted, in.id, in.expected_version));
        const row = try store.records.get(ctx.db, ctx.arena, in.id) orelse return error.NotFound;
        const type_row = try record_operations.domain.definition.find(ctx, row.type_id) orelse {
            return error.NotFound;
        };

        std.debug.assert(type_row.def.handle.len > 0);

        return .{
            .status = moved.status,
            .changed = moved.changed,
            .version = moved.version,
            .type = type_row.def.handle,
        };
    }
};

pub const Purge = struct {
    pub const name = "record.purge";
    pub const description = "Remove a record for good: document, pending edits and snapshots";
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        purged: bool,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .purged = true,
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return .{
            .purged = try lifecycle.purge(ctx, granted, in.id),
        };
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

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    var anon = harness.ctx(.anonymous);
    const created = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"One\",\"body\":\"first\"}",
    });
    _ = try SDK.dispatch(&editor, Publish, .{
        .id = created.id,
    });

    const parked = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Two\",\"body\":\"second\"}",
    });
    try std.testing.expect(parked.changed);
    const public_view = try SDK.dispatch(&anon, record_operations.Get, .{
        .id = created.id,
    });
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

    const unpublished = try SDK.dispatch(&editor, Transition, .{
        .id = created.id,
        .transition = "unpublish",
    });
    try std.testing.expect(unpublished.changed);
    const still_parked = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Three\",\"body\":\"third\"}",
    });
    try std.testing.expect(still_parked.changed);
    // Signed in, a read is the latest copy, pending changes and all.
    const own_view = try SDK.dispatch(&editor, record_operations.Get, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("Three", own_view.record.title);

    const published = try SDK.dispatch(&editor, Publish, .{
        .id = created.id,
    });
    try std.testing.expect(!published.changed);
    try std.testing.expectEqualStrings("published", published.status);
    const public_again = try SDK.dispatch(&anon, record_operations.Get, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("Three", public_again.record.title);
    const nothing_to_publish = SDK.dispatch(&editor, Publish, .{
        .id = created.id,
    });
    try std.testing.expectError(error.Invalid, nothing_to_publish);

    _ = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Four\",\"body\":\"x\"}",
    });
    _ = try SDK.dispatch(&editor, DiscardChanges, .{
        .id = created.id,
    });
    const after = try SDK.dispatch(&editor, record_operations.Get, .{
        .id = created.id,
        .purpose = .edit,
    });
    try std.testing.expectEqualStrings("Three", after.record.title);
    try std.testing.expect(!after.record.changed);
    const nothing_to_discard = SDK.dispatch(&editor, DiscardChanges, .{
        .id = created.id,
    });
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

    const deleted = try SDK.dispatch(&editor, Delete, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("trashed", deleted.status);
    const gone_for_anon = SDK.dispatch(&anon, record_operations.Get, .{
        .id = created.id,
    });
    try std.testing.expectError(error.NotFound, gone_for_anon);
    const restored = try SDK.dispatch(&editor, Transition, .{
        .id = created.id,
        .transition = "restore",
    });
    try std.testing.expectEqualStrings("draft", restored.status);
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, Purge, .{
        .id = created.id,
    }));

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_ad",
            .roles = &.{"admin"},
        },
    });
    try std.testing.expect((try SDK.dispatch(&admin, Purge, .{
        .id = created.id,
    })).purged);
    const gone_for_good = SDK.dispatch(&admin, record_operations.Get, .{
        .id = created.id,
    });
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
                    .transition = status,
                },
            ),
        );
        try std.testing.expectEqual(@as(u32, 0), ctx.db.transaction_depth);
    }
}

/// Events kept on the call's trail, as the activity log would see them.
fn hear(ctx: *Ctx, emitted: sdk.Event.Emitted, _: bool) void {
    std.debug.assert(emitted.name.len > 0);
    std.debug.assert(ctx.trail != null);

    ctx.trail.?.emitted(.{
        .name = emitted.name,
        .subject = emitted.subject,
    });
}

fn heard(trail: *const sdk.trail.Trail, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(trail.root != 0);

    for (trail.events.items) |emitted| {
        if (std.mem.eql(u8, emitted.name, name)) {
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

    const known = registry.kinds(ctx);

    try store.values.write(known, ctx, ctx.db, id, "live", row.type_id, fields, value);
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
    _ = try registry.SDK.dispatch(&system, Publish, .{
        .id = created.id,
    });
    const other = try registry.SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"Taken\",\"slug\":\"taken\"}",
    });
    _ = try registry.SDK.dispatch(&system, Publish, .{
        .id = other.id,
    });

    var trail: sdk.trail.Trail = .{
        .root = 1,
        .arena = system.arena,
    };

    system.parent = 1;
    system.trail = &trail;
    system.notify = hear;
    defer system.notify = null;

    // The live title replaced: a revision of the old one, what visitors see changed, no move.
    {
        system.publishes = false;

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

        try std.testing.expect(system.publishes);
        try std.testing.expect(!heard(&trail, "post.transitioned"));
        try std.testing.expectEqual(@as(usize, 1), revisions.len);
    }

    // Taken back to a draft: the type's transition event, as the move would raise it.
    {
        trail.events.clearRetainingCapacity();
        system.publishes = false;

        var transaction = try system.db.transaction();
        defer transaction.rollback();

        const before = try lifecycle.landing(&system, created.id);

        _ = try store.records.set_status(system.db, created.id, "draft", null, 1, null, false);
        try lifecycle.landed(&system, created.id, before);

        try std.testing.expect(heard(&trail, "post.transitioned"));
        try std.testing.expect(system.publishes);
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

test "signed-in reads match the latest copy; a preview reads it too and writes nothing" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    const live = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"One\",\"body\":\"first\"}",
    });
    _ = try SDK.dispatch(&editor, Publish, .{
        .id = live.id,
    });
    _ = try SDK.dispatch(&editor, record_operations.Save, .{
        .id = live.id,
        .document = "{\"title\":\"Two\",\"body\":\"pendingword\"}",
    });
    _ = try SDK.dispatch(&editor, record_operations.Create, .{
        .type = "post",
        .document = "{\"title\":\"Draft\"}",
    });

    // Signed in, search and field filters match the latest copy; a visitor's, the live one.
    const searched = try SDK.dispatch(&editor, record_operations.List, .{
        .type = "post",
        .search = "pendingword",
    });
    try std.testing.expectEqual(@as(usize, 1), searched.records.len);
    try std.testing.expectEqualStrings("Two", searched.records[0].title);

    const filtered = try SDK.dispatch(&editor, record_operations.List, .{
        .type = "post",
        .filter_field = "title",
        .filter_value = "Two",
    });
    try std.testing.expectEqual(@as(usize, 1), filtered.records.len);

    var anon = harness.ctx(.anonymous);
    const unseen = try SDK.dispatch(&anon, record_operations.List, .{
        .type = "post",
        .search = "pendingword",
    });
    try std.testing.expectEqual(@as(usize, 0), unseen.records.len);

    var preview = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    preview.preview = true;

    const got = try SDK.dispatch(&preview, record_operations.Get, .{
        .id = live.id,
    });
    try std.testing.expectEqualStrings("Two", got.record.title);

    const listed = try SDK.dispatch(&preview, record_operations.List, .{
        .type = "post",
        .documents = true,
        .order = .title_asc,
    });
    try std.testing.expectEqual(@as(usize, 2), listed.records.len);
    try std.testing.expectEqualStrings("Draft", listed.records[0].title);
    try std.testing.expectEqualStrings("Two", listed.records[1].title);

    const refused = SDK.dispatch(&preview, record_operations.Save, .{
        .id = live.id,
        .document = "{\"title\":\"Three\"}",
    });
    try std.testing.expect(std.meta.isError(refused));
}
