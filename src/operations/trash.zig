//! The trash: what a removal took, kept as it was (a copy of its rows) until it is emptied,
//! restorable meanwhile, and the records in the trash, which stay where they are. A removal
//! keeps its copy here before it runs (`keep`); the trash empties what it has held for
//! `trash.keep_days` (30 unless set): copies go, records are destroyed by their `destroy`
//! transition, hooks and all. Only emptying, or removing one entry for good, is final, and
//! only a person or Publr itself does it.

const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const copies = store.trash_copy;
const store_files = @import("../lib/files.zig");
const registry = @import("../server/registry.zig");
const records = @import("record.zig");
const entries = store.trash;
const public = @import("../publr/operations/trash.zig");

pub const namespace = public.namespace;

pub const operations = [_]type{ List, Restore, Remove, Empty, Keep };

pub const keep_days_default = public.keep_days_default;
const keep_days_key = "trash.keep_days";
const day_ms: i64 = 24 * 60 * 60 * 1000;

/// What a removal keeps before it runs.
pub const Kept = struct {
    kind: []const u8,
    key: []const u8,
    label: []const u8,
    roots: []const copies.Root = &.{},
    /// Tables a delete takes along that never come back (a user's sessions and devices).
    skip: []const []const u8 = &.{},
    /// Media files the entry holds, by key; the removal sets them aside (`set_aside`) once
    /// everything it removes has gone, so a refusal leaves every file in place.
    files: []const []const u8 = &.{},
    /// What to keep instead of rows (an app file's contents), already a copy.
    copy: ?[]const u8 = null,
};

/// Keeps a copy of what `kept.roots` name and everything a delete of them takes, with who
/// removed it and until when; answers the entry's id. Called by a removal before it deletes.
/// What the trash has held past its time goes for good meanwhile.
pub fn keep(ctx: *Ctx, kept: Kept) Error![]const u8 {
    std.debug.assert(kept.roots.len > 0 or kept.copy != null);
    std.debug.assert(kept.kind.len > 0);

    const captured = if (kept.copy == null)
        copies.capture(ctx.db, ctx.arena, kept.roots, kept.skip) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Invalid,
            };
        }
    else
        "";
    const copy = kept.copy orelse captured;

    const device_id = switch (ctx.caller) {
        .token => |token| token.id,
        else => "",
    };
    const conversation = if (device_id.len > 0)
        try store.ai_conversations.by_device(ctx.db, ctx.arena, device_id)
    else
        null;
    const keep_until = ctx.now_ms + @as(i64, try keep_days(ctx)) * day_ms;

    try empty_expired(ctx);

    return entries.insert(ctx.db, ctx.io, ctx.arena, .{
        .kind = kept.kind,
        .key = kept.key,
        .label = model.ai.clipped(kept.label, model.removal.label_len_max),
        .removed_by = ctx.author() orelse "",
        .device_id = device_id,
        .conversation_id = conversation orelse "",
        .keep_until = keep_until,
        .copy = copy,
        .files = std.mem.join(ctx.arena, "\n", kept.files) catch return error.OutOfMemory,
    }, ctx.now_ms);
}

/// A media file moved from the library into the trash's own folder. In the browser the file
/// stays where it is (its worker keeps the library's files only): the entry names it.
pub fn set_aside(ctx: *Ctx, key: []const u8) Error!void {
    std.debug.assert(key.len > 0);

    const files = ctx.files orelse return;

    if (files == .deferred) {
        return;
    }

    files.move(.files, .trash, key) catch |err| {
        return if (err == error.NotFound) {} else error.Unavailable;
    };
    files.clear_copies(key);
}

/// The files an entry set aside, back in the library.
fn put_back(ctx: *Ctx, keys: []const u8) Error!void {
    std.debug.assert(keys.len <= std.math.maxInt(u32));

    const files = ctx.files orelse return;

    if (files == .deferred or keys.len == 0) {
        return;
    }

    var each = std.mem.splitScalar(u8, keys, '\n');

    while (each.next()) |key| {
        files.move(.trash, .files, key) catch |err| {
            return if (err == error.NotFound) ctx.fail(files_gone) else error.Unavailable;
        };
    }
}

/// The files an entry set aside, gone for good.
fn throw_out(ctx: *Ctx, keys: []const u8) void {
    std.debug.assert(keys.len <= std.math.maxInt(u32));

    const files = ctx.files orelse return;
    const area: store_files.Area = if (files == .deferred) .files else .trash;
    var each = std.mem.splitScalar(u8, keys, '\n');

    while (each.next()) |key| {
        if (key.len > 0) {
            files.remove(area, key);
        }
    }
}

/// An entry gone for good: its row and the files it set aside.
/// One entry gone for good: its copy, and the files it set aside.
pub fn drop(ctx: *Ctx, id: []const u8) Error!bool {
    std.debug.assert(id.len > 0);

    const scratch = try ctx.scratch();
    const begun = scratch.mark();
    defer scratch.rewind(begun);

    throw_out(ctx, try entries.files_of(ctx.db, scratch.allocator(), id));

    return entries.delete(ctx.db, id);
}

/// Entries emptied a batch at a time.
const batch: u32 = 50;

/// Everything the trash holds, or what it held past its time, gone for good a batch at a
/// time, however much there is; how many went.
fn empty_all(ctx: *Ctx, expired_only: bool) Error!u32 {
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const scratch = try ctx.scratch();
    var removed: u32 = 0;

    while (true) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const due = if (expired_only)
            try entries.expired(ctx.db, scratch.allocator(), ctx.now_ms, batch)
        else
            try entries.page(ctx.db, scratch.allocator(), .{
                .limit = batch,
            });
        var dropped: u32 = 0;

        for (due) |entry| {
            dropped += @intFromBool(try drop(ctx, entry.id));
        }

        removed += dropped;

        // A batch that took nothing out would come back the same: done.
        if (due.len < batch or dropped == 0) {
            return removed;
        }
    }
}

const files_gone: sdk.operation.Failure = .{
    .name = "FilesGone",
    .status = 409,
    .message = "Its files are no longer in the trash's folder",
};

/// What the trash has held past its time goes for good.
fn empty_expired(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.db.transaction_depth >= 1);

    _ = try empty_all(ctx, true);
}

/// Records in the trash destroyed by their `destroy` transition, a page at a time: all, or
/// those trashed more than the trash's days ago; how many went. One that stays (its destroy
/// waits for a person, a hook refused it) is passed over.
fn destroy_trashed(ctx: *Ctx, expired_only: bool) Error!u32 {
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const cutoff = ctx.now_ms - @as(i64, try keep_days(ctx)) * day_ms;
    var destroyed: u32 = 0;
    var stayed: u32 = 0;

    while (true) {
        const page = try trashed_page(ctx, stayed, batch);

        for (page.records) |record| {
            if (expired_only and record.updated_at > cutoff) {
                return destroyed;
            }

            const moved = registry.SDK.dispatch(ctx, records.Transition, .{
                .id = record.id,
                .transition = "destroy",
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    ctx.failure = null;
                    break :blk null;
                },
            };
            const gone = if (moved) |done| std.mem.eql(u8, done.status, "destroyed") else false;

            destroyed += @intFromBool(gone);
            stayed += @intFromBool(!gone);
        }

        if (page.records.len < batch) {
            return destroyed;
        }
    }
}

/// What the trash has held past its time goes for good, whether or not anything new is put
/// in: Publr itself does it, from the queue's process. How many went.
pub fn sweep(ctx: *Ctx) Error!u32 {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.db.transaction_depth == 0);

    var transaction = try ctx.db.transaction();
    errdefer transaction.rollback();

    const removed = try empty_all(ctx, true) + try destroy_trashed(ctx, true);

    try transaction.commit();

    return removed;
}

/// The records in the trash, the longest there first.
fn trashed_page(ctx: *Ctx, offset: u32, limit: u32) Error!records.List.Out {
    std.debug.assert(limit > 0);

    return registry.SDK.dispatch(ctx, records.List, .{
        .filters = &.{"status:is:trashed"},
        .order = .updated_asc,
        .offset = offset,
        .limit = limit,
        .count = true,
    });
}

/// How long the trash keeps things: `trash.keep_days`, else 30.
pub fn keep_days(ctx: *Ctx) Error!u32 {
    std.debug.assert(keep_days_default > 0);

    const text = try store.settings.get(ctx.db, ctx.arena, keep_days_key) orelse {
        return keep_days_default;
    };
    const days = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \""), 10) catch {
        return keep_days_default;
    };

    return if (days == 0) keep_days_default else @min(days, 3650);
}

pub const Shown = public.Shown;
const example_shown = public.example_shown;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.conversation.len > 64 or in.limit == 0 or in.limit > entries.entries_max) {
            return error.Invalid;
        }

        const rows = try entries.page(ctx.db, ctx.arena, .{
            .conversation_id = in.conversation,
            .offset = in.offset,
            .limit = in.limit,
        });
        const out = ctx.arena.alloc(Shown, rows.len) catch return error.OutOfMemory;

        for (rows, out) |row, *shown| {
            shown.* = .{
                .id = row.id,
                .kind = row.kind,
                .key = row.key,
                .label = row.label,
                .removed_by = row.removed_by,
                .conversation_id = row.conversation_id,
                .removed_at = row.removed_at,
                .keep_until = row.keep_until,
            };
        }

        const days = try keep_days(ctx);
        const trashed: records.List.Out = if (in.conversation.len > 0)
            .{
                .records = &.{},
            }
        else
            try trashed_page(ctx, in.offset, in.limit);
        const shown = ctx.arena.alloc(Shown, trashed.records.len) catch return error.OutOfMemory;

        for (trashed.records, shown) |record, *item| {
            item.* = .{
                .id = record.id,
                .kind = "record",
                .key = record.type,
                .label = record.title,
                .removed_by = record.updated_by orelse "",
                .conversation_id = "",
                .removed_at = record.updated_at,
                .keep_until = record.updated_at + @as(i64, days) * day_ms,
            };
        }

        return .{
            .entries = out,
            .keep_days = days,
            .total = try entries.count(ctx.db, in.conversation),
            .records = shown,
            .records_total = trashed.total,
        };
    }
};

const taken: sdk.operation.Failure = .{
    .name = "Taken",
    .status = 409,
    .message = "Something new has its name now: rename or remove that first, then restore",
};

pub const Restore = struct {
    pub const shape = public.Restore;
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
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64) {
            return error.Invalid;
        }

        const entry = try entries.get(ctx.db, ctx.arena, in.id) orelse {
            return restore_record(ctx, in.id);
        };
        const copy = try entries.copy_of(ctx.db, ctx.arena, in.id) orelse return error.NotFound;

        if (std.mem.eql(u8, entry.kind, "app_file")) {
            // An app file's copy is the call that writes it back.
            _ = try registry.SDK.call_json(ctx, "apps.write", copy);
        } else {
            copies.restore(ctx.db, ctx.arena, copy) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Constraint => return ctx.fail(taken),
                else => return error.Invalid,
            };
        }

        try put_back(ctx, try entries.files_of(ctx.db, ctx.arena, in.id));
        _ = try entries.delete(ctx.db, in.id);

        return .{
            .kind = entry.kind,
            .key = entry.key,
            .label = entry.label,
        };
    }
};

/// A record in the trash, back by its `restore` transition.
fn restore_record(ctx: *Ctx, id: []const u8) Error!Restore.Out {
    std.debug.assert(id.len > 0);

    const got = try registry.SDK.dispatch(ctx, records.Get, .{
        .id = id,
    });

    if (!std.mem.eql(u8, got.record.status, model.flow.trashed)) {
        return error.NotFound;
    }

    _ = try registry.SDK.dispatch(ctx, records.Transition, .{
        .id = id,
        .transition = "restore",
    });

    return .{
        .kind = "record",
        .key = got.record.type,
        .label = got.record.title,
    };
}

pub const Remove = struct {
    pub const shape = public.Remove;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const destroys = shape.destroys;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64) {
            return error.Invalid;
        }

        if (try entries.get(ctx.db, ctx.arena, in.id) == null) {
            const moved = try registry.SDK.dispatch(ctx, records.Transition, .{
                .id = in.id,
                .transition = "destroy",
            });

            return .{
                .removed = std.mem.eql(u8, moved.status, "destroyed"),
            };
        }

        return .{
            .removed = try drop(ctx, in.id),
        };
    }
};

pub const Empty = struct {
    pub const shape = public.Empty;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const destroys = shape.destroys;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const removed = try empty_all(ctx, in.expired);

        return .{
            .removed = removed + try destroy_trashed(ctx, in.expired),
        };
    }
};

pub const Keep = struct {
    pub const shape = public.Keep;
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
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.days == 0 or in.days > 3650) {
            return error.Invalid;
        }

        const text = std.fmt.allocPrint(ctx.arena, "{d}", .{in.days}) catch {
            return error.OutOfMemory;
        };

        try store.settings.set(ctx.db, keep_days_key, text, ctx.now_ms);
        try entries.keep_all(ctx.db, @as(i64, in.days) * day_ms);

        return .{
            .days = in.days,
        };
    }
};

test "the trash lists a page at a time and empties all of it, past one batch" {
    const SDK = @import("../server/registry.zig").SDK;
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var made: u32 = 0;

    while (made < 120) : (made += 1) {
        _ = try entries.insert(&harness.fixture.connection, std.testing.io, system.arena, .{
            .kind = "secret",
            .key = "key",
            .label = "A secret",
            .keep_until = 10_000,
            .copy = "{}",
        }, 1_000 + made);
    }

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_ad",
            .roles = &.{"admin"},
        },
    });
    const last = try SDK.dispatch(&admin, List, .{
        .offset = 100,
    });
    try std.testing.expectEqual(20, last.entries.len);
    try std.testing.expectEqual(120, last.total);
    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, List, .{
        .limit = 0,
    }));

    try std.testing.expectEqual(120, (try SDK.dispatch(&admin, Empty, .{})).removed);
    try std.testing.expectEqual(0, (try SDK.dispatch(&admin, List, .{})).total);
}
