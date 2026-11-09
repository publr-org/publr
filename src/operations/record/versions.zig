//! A live record's scheduled changes, each on a base: what is live (no base) or another
//! scheduled change it builds on. One reads as the record will be at its moment: what is live
//! with its chain of bases and itself laid over, in order. Changes on the same base never
//! share a field: changing it again is a change on top of the one that has it. Edits made on
//! top of one are a draft on it until they are scheduled (`record.transition_at` with that
//! base), saved into it (`record.save_into_scheduled`) or dropped (`record.unschedule`).
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Value = std.json.Value;
const Entry = store.scheduled_changes.Entry;
const Def = model.content_type.Def;
const change_set = model.change_set;
const scheduled = store.scheduled_changes;

/// Whether an entry changes content (a draft included), not only the record's status.
pub fn is_change(entry: Entry) bool {
    std.debug.assert(entry.transition.len > 0);

    return entry.changes.len > 0;
}

fn is(entry: Entry, state: []const u8) bool {
    std.debug.assert(state.len > 0);

    return std.mem.eql(u8, entry.state, state);
}

/// The record as it will be: its document and what it holds back.
pub const Projected = struct {
    document: Value,
    held_back: []const u8,
};

/// The record's scheduled changes and drafts, soonest first, and the place of one.
pub const Found = struct {
    entries: []const Entry,
    index: u32,
};

pub fn find(ctx: *Ctx, record_id: []const u8, entry: i64) Error!?Found {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(entry > 0);

    const entries = try scheduled.of_record(ctx.db, ctx.arena, record_id);
    const index = index_of(entries, entry) orelse return null;

    return .{
        .entries = entries,
        .index = index,
    };
}

fn index_of(entries: []const Entry, id: i64) ?u32 {
    std.debug.assert(entries.len <= scheduled.record_max);

    for (entries, 0..) |one, index| {
        if (one.id == id) {
            return @intCast(index);
        }
    }

    return null;
}

/// The chain to `id`: its bases from the one on what is live, then it; as places in
/// `entries`. A base gone ends it.
fn chain_of(arena: std.mem.Allocator, entries: []const Entry, id: i64) Error![]const u32 {
    std.debug.assert(entries.len <= scheduled.record_max);
    std.debug.assert(id > 0);

    var reversed: std.ArrayList(u32) = .empty;
    var next: ?i64 = id;

    while (next) |at| {
        if (reversed.items.len == entries.len) {
            break;
        }

        const index = index_of(entries, at) orelse break;

        try reversed.append(arena, index);
        next = entries[index].base_id;
    }

    std.mem.reverse(u32, reversed.items);

    return reversed.items;
}

/// What is live now with the chain to `id` laid over (none: what is live); a failed one
/// in it is left out.
pub fn projected(
    ctx: *Ctx,
    row: store.records.Record,
    def: Def,
    entries: []const Entry,
    id: ?i64,
) Error!Projected {
    std.debug.assert(entries.len <= scheduled.record_max);
    std.debug.assert(row.id.len > 0);

    const domain = record_operations.domain;
    var out: Projected = .{
        .document = try domain.document.document_of(ctx, row.id, domain.values.live, def),
        .held_back = row.held_back,
    };
    const last = id orelse return out;

    for (try chain_of(ctx.arena, entries, last)) |index| {
        const one = entries[index];

        if (!is(one, "waiting") or !is_change(one)) {
            continue;
        }

        out = try laid_over(ctx, out, one);
    }

    return out;
}

fn laid_over(ctx: *Ctx, under: Projected, entry: Entry) Error!Projected {
    std.debug.assert(entry.changes.len > 0);
    std.debug.assert(under.document == .object);

    const changes = try parsed_changes(ctx, entry.changes);

    return .{
        .document = change_set.applied(ctx.arena, under.document, changes) catch {
            return error.OutOfMemory;
        },
        .held_back = entry.held_back orelse under.held_back,
    };
}

/// The draft on `base`: edits made on top of it, not scheduled yet.
pub fn draft_on(entries: []const Entry, base: i64) ?Entry {
    std.debug.assert(entries.len <= scheduled.record_max);
    std.debug.assert(base > 0);

    for (entries) |one| {
        if (is(one, "draft") and one.base_id != null and one.base_id.? == base) {
            return one;
        }
    }

    return null;
}

/// The record as the editor shows scheduled change `id`: as it will be then, with the
/// draft on it laid over.
pub fn shown(
    ctx: *Ctx,
    row: store.records.Record,
    def: Def,
    entries: []const Entry,
    id: i64,
) Error!Projected {
    std.debug.assert(id > 0);
    std.debug.assert(row.id.len > 0);

    const at = try projected(ctx, row, def, entries, id);
    const draft = draft_on(entries, id) orelse return at;

    return laid_over(ctx, at, draft);
}

/// A waiting change on `base` (other than `except`) that changes one of `keys`: changing a
/// field again is a change on top of the one that has it.
pub fn clash(
    ctx: *Ctx,
    entries: []const Entry,
    base: ?i64,
    keys: []const []const u8,
    except: ?i64,
) Error!?Clash {
    std.debug.assert(entries.len <= scheduled.record_max);
    std.debug.assert(keys.len <= 64 << 10);

    for (entries) |one| {
        const same_base = std.meta.eql(one.base_id, base);
        const other = except == null or one.id != except.?;

        if (!is(one, "waiting") or !is_change(one) or !same_base or !other) {
            continue;
        }

        const changes = try parsed_changes(ctx, one.changes);

        for (keys) |key| {
            if (changes.get(key) != null) {
                return .{
                    .entry = one,
                    .key = key,
                };
            }
        }
    }

    return null;
}

pub const Clash = struct {
    entry: Entry,
    key: []const u8,
};

/// Refused for a clash: the field, and the one that has it.
pub fn refuse_clash(ctx: *Ctx, found: Clash) Error {
    std.debug.assert(found.key.len > 0);
    std.debug.assert(found.entry.id > 0);

    // When, on the site's clock, as the admin shows it.
    const due = found.entry.due_at;
    const rule = @import("../../sdk/jobs.zig").zone_rule(ctx) catch "UTC0";
    const local = due + @import("../../lib/zone.zig").offset_ms(rule, due);
    const text = @import("../../lib/time.zig").datetime_local_text(ctx.arena, local) catch "";
    const when = std.mem.replaceOwned(u8, ctx.arena, text, "T", " ") catch {
        return error.OutOfMemory;
    };
    const message = std.fmt.allocPrint(
        ctx.arena,
        "Already changed by the change scheduled for {s}: schedule on top of it instead",
        .{when},
    ) catch return error.OutOfMemory;

    // Kept past this call: the problems live in the arena, never on this stack.
    const problems = ctx.arena.alloc(sdk.operation.Problem, 1) catch return error.OutOfMemory;

    problems[0] = .{
        .field = found.key,
        .message = message,
    };

    return ctx.refuse(problems);
}

pub fn parsed_changes(ctx: *Ctx, text: []const u8) Error!std.json.ObjectMap {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= 64 << 20);

    const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{
        .allocate = .alloc_always,
    }) catch return error.Invalid;

    if (parsed != .object) {
        return error.Invalid;
    }

    return parsed.object;
}

/// Made, or put live with what it builds on: what builds on it builds on what is live now.
pub fn settled(ctx: *Ctx, record_id: []const u8, id: i64) Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(id > 0);

    try scheduled.rebase(ctx.db, record_id, id, null);
}

/// Dropped: what builds on it builds on its base; the draft on it goes.
pub fn dropped(ctx: *Ctx, record_id: []const u8, entry: Entry) Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(entry.id > 0);

    const entries = try scheduled.of_record(ctx.db, ctx.arena, record_id);

    if (draft_on(entries, entry.id)) |draft| {
        _ = try scheduled.remove(ctx.db, record_id, draft.id);
    }

    try scheduled.rebase(ctx.db, record_id, entry.id, entry.base_id);
}

const Loaded = struct {
    row: store.records.Record,
    def: Def,
};

/// The record and its definition, reached by the caller.
fn loaded(ctx: *Ctx, granted: *const Grant, id: []const u8) Error!Loaded {
    std.debug.assert(id.len > 0);
    std.debug.assert(granted.allows());

    const domain = record_operations.domain;
    const row = try domain.access.load(ctx, id, granted) orelse return error.NotFound;
    const def = (try domain.definition.find(ctx, row.type_id) orelse return error.NotFound).def;

    return .{
        .row = row,
        .def = def,
    };
}

pub const SaveVersion = struct {
    pub const name = "record.save_version";
    pub const description = "Keep edits made on top of a scheduled change, as a draft";
    pub const details =
        \\Takes the whole document as it should read (`record get --version`) and keeps what
        \\differs from the scheduled change as a draft on it: nothing is scheduled until
        \\`record transition_at` with it as `base` schedules the draft on top of it, or
        \\`record save_into_scheduled` puts it into the change itself. Back to what the
        \\change reads, the draft goes. Live is untouched.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        version: i64,
        document: []const u8,
    };
    pub const Out = struct {
        /// Whether a draft is kept on it.
        changed: bool,
    };
    pub const example: In = .{
        .id = record_operations.example_scheduled_id,
        .version = 1,
        .document = "{\"title\":\"Back to normal\"}",
    };
    pub const example_out: Out = .{
        .changed = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .version = "The scheduled change, from `scheduled` in `record get`",
        .document = "The whole document as it should read",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .changed = "Whether edits are kept on it, waiting to be scheduled or saved into it",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64 or in.version <= 0) {
            return error.Invalid;
        }

        const person = ctx.caller.user_id() orelse return error.Denied;
        const record = try loaded(ctx, granted, in.id);
        const found = try find(ctx, in.id, in.version) orelse return error.NotFound;
        const entry = found.entries[found.index];

        if (!is(entry, "waiting") or !is_change(entry)) {
            return error.Invalid;
        }

        const at = try projected(ctx, record.row, record.def, found.entries, entry.id);
        const json = @import("../../lib/json.zig");
        const edited = json.parse(Value, ctx.arena, in.document, .{
            .allocate = .alloc_always,
        }) catch return error.Invalid;

        if (edited != .object) {
            return error.Invalid;
        }

        const changes = change_set.between(ctx.arena, at.document, edited) catch {
            return error.OutOfMemory;
        };
        const kept = draft_on(found.entries, entry.id);

        if (changes.count() == 0) {
            if (kept) |draft| {
                _ = try scheduled.remove(ctx.db, in.id, draft.id);
            }

            return .{
                .changed = false,
            };
        }

        const text = std.json.Stringify.valueAlloc(ctx.arena, Value{
            .object = changes,
        }, .{}) catch return error.OutOfMemory;

        if (kept) |draft| {
            _ = try scheduled.set_changes(ctx.db, in.id, draft.id, text, null);
        } else {
            _ = try scheduled.add(ctx.db, .{
                .record_id = in.id,
                .transition = "publish",
                .changes = text,
                .base_id = entry.id,
                .due_at = 0,
                .scheduled_by = person,
                .scheduled_at = ctx.now_ms,
                .state = "draft",
            });
        }

        return .{
            .changed = true,
        };
    }
};

pub const SaveIntoScheduled = struct {
    pub const name = "record.save_into_scheduled";
    pub const description = "Put the edits made on top of a scheduled change into it";
    pub const details =
        \\The draft on the change (`record save_version`) becomes part of it: the change
        \\then sets those fields too, at its moment. Refused when another change on the same
        \\base already changes one of them.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        version: i64,
    };
    pub const Out = struct {
        saved: bool,
    };
    pub const example: In = .{
        .id = record_operations.example_scheduled_id,
        .version = 1,
    };
    pub const example_out: Out = .{
        .saved = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .version = "The scheduled change, from `scheduled` in `record get`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .saved = "Always true; not found when nothing waits on it",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64 or in.version <= 0) {
            return error.Invalid;
        }

        _ = try loaded(ctx, granted, in.id);

        const found = try find(ctx, in.id, in.version) orelse return error.NotFound;
        const entry = found.entries[found.index];
        const draft = draft_on(found.entries, entry.id) orelse return error.NotFound;
        const added = try parsed_changes(ctx, draft.changes);

        if (try clash(ctx, found.entries, entry.base_id, added.keys(), entry.id)) |found_clash| {
            return refuse_clash(ctx, found_clash);
        }

        var merged = try parsed_changes(ctx, entry.changes);

        for (added.keys(), added.values()) |key, value| {
            merged.put(ctx.arena, key, value) catch return error.OutOfMemory;
        }

        const text = std.json.Stringify.valueAlloc(ctx.arena, Value{
            .object = merged,
        }, .{}) catch return error.OutOfMemory;

        _ = try scheduled.set_changes(ctx.db, in.id, entry.id, text, entry.held_back);
        _ = try scheduled.remove(ctx.db, in.id, draft.id);

        return .{
            .saved = true,
        };
    }
};

pub const PublishVersion = struct {
    pub const name = "record.publish_version";
    pub const description = "Put a scheduled change live now, with what it builds on";
    pub const details =
        \\The record goes live as the change reads, now, as you: the changes it builds on
        \\go live with it and leave the schedule; changes beside it and on top of it keep
        \\their moments, now on what is live. Checked as a publish is.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        version: i64,
    };
    pub const Out = @import("lifecycle.zig").Transition.Out;
    pub const example: In = .{
        .id = record_operations.example_scheduled_id,
        .version = 1,
    };
    pub const example_out: Out = .{
        .status = "published",
        .changed = false,
        .version = 3,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .version = "The scheduled change, from `scheduled` in `record get`",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64 or in.version <= 0) {
            return error.Invalid;
        }

        const record = try loaded(ctx, granted, in.id);
        const found = try find(ctx, in.id, in.version) orelse return error.NotFound;
        const entries = found.entries;

        if (!is(entries[found.index], "waiting") or !is_change(entries[found.index])) {
            return error.Invalid;
        }

        const domain = record_operations.domain;
        const live = try domain.document.document_of(
            ctx,
            in.id,
            domain.values.live,
            record.def,
        );
        const target = try projected(ctx, record.row, record.def, entries, in.version);
        const changes = change_set.between(ctx.arena, live, target.document) catch {
            return error.OutOfMemory;
        };
        const same_held = std.mem.eql(u8, target.held_back, record.row.held_back);
        const moved = try domain.lifecycle.publish_set(
            ctx,
            granted,
            in.id,
            changes,
            if (same_held) null else target.held_back,
        );

        for (try chain_of(ctx.arena, entries, in.version)) |index| {
            const one = entries[index];

            if (draft_on(entries, one.id)) |draft| {
                _ = try scheduled.remove(ctx.db, in.id, draft.id);
            }

            _ = try scheduled.remove(ctx.db, in.id, one.id);
            try settled(ctx, in.id, one.id);
        }

        return .{
            .status = moved.status,
            .changed = moved.changed,
            .version = moved.version,
            .pending = moved.pending,
        };
    }
};
