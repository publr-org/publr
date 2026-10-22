//! The trash: what a removal took, kept as it was (a copy of its rows) until it is emptied,
//! restorable meanwhile. A removal keeps its copy here before it runs (`keep`); the trash
//! empties what it has held for `trash.keep_days` (30 unless set). Only emptying, or
//! removing one entry for good, is final, and only a person does it.

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
const entries = store.trash;

pub const namespace: sdk.operation.Namespace = .{
    .name = "trash",
    .label = "Trash",
    .area = .content,
    .summary = "The trash: what was removed, restorable until it is emptied",
    .details =
    \\Removing a content type, a taxonomy or a field group keeps a copy of everything it
    \\takes (its records, terms, values, snapshots) here before it goes. `trash restore`
    \\brings it back as it was. The trash empties what it has held for `trash.keep_days`
    \\days (30 unless set); `trash remove` and `trash empty` remove for good sooner. Those
    \\two are final, so a device (an agent) lists them for its person instead.
    ,
};

pub const operations = [_]type{ List, Restore, Remove, Empty, Keep };

pub const keep_days_default: u32 = 30;
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
    /// Media files to set aside, by key.
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

    for (kept.files) |file| {
        try set_aside(ctx, file);
    }

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
fn set_aside(ctx: *Ctx, key: []const u8) Error!void {
    std.debug.assert(key.len > 0);

    const files = ctx.files orelse return;

    if (files == .deferred) {
        return;
    }

    const bytes = files.read(ctx.arena, .files, key, store_files.bytes_max) catch |err| {
        return if (err == error.NotFound) {} else error.Unavailable;
    };

    files.write(.trash, key, bytes) catch return error.Unavailable;
    files.remove(.files, key);
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
        const bytes = files.read(ctx.arena, .trash, key, store_files.bytes_max) catch {
            return ctx.fail(files_gone);
        };

        files.write(.files, key, bytes) catch return error.Unavailable;
        files.remove(.trash, key);
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
fn drop(ctx: *Ctx, id: []const u8) Error!bool {
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

pub const Shown = struct {
    id: []const u8,
    /// `content_type`, `taxonomy`, `field_group`, …
    kind: []const u8,
    key: []const u8,
    label: []const u8,
    removed_by: []const u8,
    conversation_id: []const u8,
    removed_at: i64,
    /// When it goes for good.
    keep_until: i64,
};

const example_shown: Shown = .{
    .id = "0190a1b2c3d40001a1b2c3d4",
    .kind = "content_type",
    .key = "recipe",
    .label = "Content type Recipe, and its 12 records",
    .removed_by = "0190a1b2c3d40001a1b2c3d5",
    .conversation_id = "",
    .removed_at = 1789650000000,
    .keep_until = 1792242000000,
};

pub const List = struct {
    pub const name = "trash.list";
    pub const description = "List what the trash holds, newest first";
    pub const details =
        \\Every removed thing still restorable, with who removed it, when, and when it goes for
        \\good. A conversation's only, with `conversation`.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        conversation: []const u8 = "",
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        entries: []const Shown,
        keep_days: u32,
        total: u32 = 0,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .entries = &.{},
        .keep_days = keep_days_default,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .conversation = "Only what this conversation's agent removed",
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .entries = "What it holds, newest first",
        .keep_days = "How many days it keeps something before removing it for good",
        .total = "How many entries it holds in all (the conversation's, when named)",
    };

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

        return .{
            .entries = out,
            .keep_days = try keep_days(ctx),
            .total = try entries.count(ctx.db, in.conversation),
        };
    }
};

const taken: sdk.operation.Failure = .{
    .name = "Taken",
    .status = 409,
    .message = "Something new has its name now: rename or remove that first, then restore",
};

pub const Restore = struct {
    pub const name = "trash.restore";
    pub const description = "Bring something back from the trash, as it was";
    pub const details =
        \\Everything the removal took comes back: a content type with its records, their
        \\values, terms and snapshots. Refused when something new took its name meanwhile.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        kind: []const u8,
        key: []const u8,
        label: []const u8,
    };
    pub const example: In = .{
        .id = example_shown.id,
    };
    pub const example_out: Out = .{
        .kind = "content_type",
        .key = "recipe",
        .label = example_shown.label,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The trash entry's id",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64) {
            return error.Invalid;
        }

        const entry = try entries.get(ctx.db, ctx.arena, in.id) orelse return error.NotFound;
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

pub const Remove = struct {
    pub const name = "trash.remove";
    pub const description = "Remove one thing in the trash for good";
    pub const details =
        \\Its copy goes, and it can never be restored. Final, so a device lists it for its
        \\person instead.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        removed: bool,
    };
    pub const example: In = .{
        .id = example_shown.id,
    };
    pub const example_out: Out = .{
        .removed = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The trash entry's id",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > 64) {
            return error.Invalid;
        }

        return .{
            .removed = try drop(ctx, in.id),
        };
    }
};

pub const Empty = struct {
    pub const name = "trash.empty";
    pub const description = "Empty the trash: what it holds goes for good";
    pub const details =
        \\Everything, or only what it has held past `trash.keep_days` with `expired`. Final,
        \\so a device lists it for its person instead.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        expired: bool = false,
    };
    pub const Out = struct {
        removed: u32,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .removed = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .expired = "Only what it has held longer than it keeps things",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        return .{
            .removed = try empty_all(ctx, in.expired),
        };
    }
};

pub const Keep = struct {
    pub const name = "trash.keep";
    pub const description = "Set how long the trash keeps things before removing them for good";
    pub const details =
        \\`days` for everything in the trash and all that is removed from now on: each entry
        \\goes that many days after it was removed. 1 to 3650.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        days: u32,
    };
    pub const Out = struct {
        days: u32,
    };
    pub const example: In = .{
        .days = 30,
    };
    pub const example_out: Out = .{
        .days = 30,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .days = "How many days, 1 to 3650",
    };

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
