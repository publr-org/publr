//! What a write did to records that changes what visitors see becomes changed keys in the
//! dependency index, so the built site (`adapters/site`) rebuilds exactly the pages and
//! fragments that read the record or its type. Heard as any plugin hears it: `after` the
//! record operations that write a document, from their input and answer, and from the
//! records' typed transition events, one per record even in a move over many. The built
//! site holds live documents only: an edit kept as pending changes, or written into a
//! record no visitor sees, rebuilds nothing (a preview renders those on request). Raised
//! inside the operation's transaction: a rolled-back write raises nothing.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const records = @import("../../store/records.zig");
const statuses = @import("../status.zig");
const record_operations = @import("../record.zig");
const project_put = @import("put.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Event = sdk.Event;
const Transitioned = @import("../../model/flow.zig").Transitioned;

/// The key every listing render records, raised when a change cannot be pinned to a type.
pub const all_records_key = "records";
pub const key_len_max: u32 = 128;

/// A record's move: heard inside the write, one by one or a move over many at once.
pub const RecordChanged = struct {
    pub const stage: sdk.middleware.Stage = .on;
    /// Part of the write: a page the write changed and the index never heard of would stay
    /// stale, so a key not raised fails the write.
    pub const intrinsic = true;

    pub fn run(ctx: *Ctx, event: Event) void {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(all_records_key.len > 0);

        const emitted = switch (event) {
            .emitted => |found| found,
            else => return,
        };

        raise_many(ctx, &.{emitted}) catch |err| failed(ctx, err);
    }

    /// A write over many records: every key they raise, raised at once.
    pub fn run_many(ctx: *Ctx, events: []const Event.Emitted) void {
        std.debug.assert(events.len > 0);
        std.debug.assert(ctx.db.transaction_depth >= 1);

        raise_many(ctx, events) catch |err| failed(ctx, err);
    }
};

fn failed(ctx: *Ctx, err: anyerror) void {
    std.debug.assert(@errorName(err).len > 0);

    ctx.dependency_failure = true;
    std.log.debug("site changes: not raised: {s}", .{@errorName(err)});
}

/// The `after` hooks on the record operations that write a document; a move is heard by its
/// transition event.
pub const hooks = [_]type{
    After(record_operations.Create, created),
    After(record_operations.Save, saved),
    After(record_operations.Publish, published),
    After(record_operations.Transition, published_by_name),
    After(record_operations.Purge, purged),
    After(project_put.Put, put),
};

fn After(comptime Operation: type, comptime raised: anytype) type {
    return struct {
        pub const stage: sdk.middleware.Stage = .after;
        pub const operation = Operation.name;
        /// A move over many: each record from its transition event (`RecordChanged`).
        pub const by_events = true;

        pub fn run(ctx: *Ctx, in: *Operation.In, out: *const Operation.Out) Error!void {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(ctx.parent != null);

            raised(ctx, in, out) catch |err| {
                if (err == error.OutOfMemory) {
                    return error.OutOfMemory;
                }

                failed(ctx, err);
            };
        }
    };
}

/// Created live: what a new record shows.
fn created(
    ctx: *Ctx,
    _: *const record_operations.Create.In,
    out: *const record_operations.Create.Out,
) !void {
    std.debug.assert(out.id.len > 0);

    try raise(ctx, out.id, false);
}

/// Written into the record's own document: what visitors see when it is live.
fn saved(
    ctx: *Ctx,
    in: *const record_operations.Save.In,
    out: *const record_operations.Save.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    if (std.mem.eql(u8, out.outcome, "saved")) {
        try raise(ctx, in.id, false);
    }
}

/// Pending changes applied, or a record put live: done, not asked for.
fn published(
    ctx: *Ctx,
    in: *const record_operations.Publish.In,
    out: *const record_operations.Publish.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    if (!out.pending) {
        try raise(ctx, in.id, false);
    }
}

/// `publish` named on a live record applies its pending changes: no move, no transition.
fn published_by_name(
    ctx: *Ctx,
    in: *const record_operations.Transition.In,
    out: *const record_operations.Transition.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    if (std.mem.eql(u8, in.transition, "publish") and !out.pending) {
        try raise(ctx, in.id, false);
    }
}

fn purged(
    ctx: *Ctx,
    in: *const record_operations.Purge.In,
    _: *const record_operations.Purge.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    try raise(ctx, in.id, true);
}

/// Each record put as another copy keeps it: added or replaced while live, or removed.
fn put(ctx: *Ctx, _: *const project_put.Put.In, out: *const project_put.Put.Out) !void {
    std.debug.assert(out.put.len <= project_put.units_max);

    for (out.put) |done| {
        const record = std.mem.eql(u8, done.kind, "record");

        if (record and !std.mem.eql(u8, done.outcome, "unchanged")) {
            try raise(ctx, done.id, std.mem.eql(u8, done.outcome, "removed"));
        }
    }
}

fn raise_many(ctx: *Ctx, events: []const Event.Emitted) !void {
    std.debug.assert(events.len > 0);
    std.debug.assert(key_len_max > 0);

    var moves: std.ArrayList(Transitioned) = .empty;
    var subjects: std.ArrayList([]const u8) = .empty;

    for (events) |emitted| {
        const found = try sdk.changed_units.moved(ctx, emitted) orelse continue;

        if (found.unit.kind == .record) {
            try moves.append(ctx.arena, found.transition);
            try subjects.append(ctx.arena, found.transition.record);
        }
    }

    if (moves.items.len == 0) {
        return;
    }

    const ids_json = try std.json.Stringify.valueAlloc(ctx.arena, subjects.items, .{});
    const found = try records.briefs(ctx.db, ctx.arena, ids_json);
    var keys: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (moves.items) |move| {
        const brief = brief_of(found, move.record);
        const live_now = if (brief) |record| try statuses.is_live(ctx, record.status) else false;

        if (!live_now and !try touches(ctx, move)) {
            continue;
        }

        var record_buffer: [key_len_max]u8 = undefined;
        var type_buffer: [key_len_max]u8 = undefined;

        try add_key(ctx, &keys, &seen, try record_key(&record_buffer, move.record));
        try add_key(ctx, &keys, &seen, all_records_key);

        if (brief) |record| {
            try add_key(ctx, &keys, &seen, try type_key(&type_buffer, record.type));
        }
    }

    if (keys.items.len == 0) {
        return;
    }

    var index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };

    try index.invalidate(keys.items, ctx.now_ms);
}

/// Whether a move changes what visitors see, wherever the record is now: out of live, and
/// into, out of or within the archive and the trash, and gone for good.
fn touches(ctx: *Ctx, move: Transitioned) !bool {
    std.debug.assert(move.to.len > 0);
    std.debug.assert(move.record.len > 0);

    const kept = [_][]const u8{ "archived", "trashed" };

    for (kept) |status| {
        if (std.mem.eql(u8, move.from, status) or std.mem.eql(u8, move.to, status)) {
            return true;
        }
    }

    if (std.mem.eql(u8, move.to, "destroyed")) {
        return true;
    }

    return move.from.len > 0 and try statuses.is_live(ctx, move.from);
}

fn brief_of(found: []const records.Brief, id: []const u8) ?records.Brief {
    std.debug.assert(id.len > 0);
    std.debug.assert(found.len <= 1 << 20);

    for (found) |brief| {
        if (std.mem.eql(u8, brief.id, id)) {
            return brief;
        }
    }

    return null;
}

fn add_key(
    ctx: *Ctx,
    keys: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    key: []const u8,
) !void {
    std.debug.assert(key.len > 0);
    std.debug.assert(keys.items.len == seen.count());

    if (seen.contains(key)) {
        return;
    }

    const kept = try ctx.arena.dupe(u8, key);

    try keys.append(ctx.arena, kept);
    try seen.put(ctx.arena, kept, {});
}

/// `record:<id>` and `type:<handle>` for a record that still exists; `records` for one
/// that is gone (a purge), which every listing depends on. Only while it is live, unless
/// `always`.
fn raise(ctx: *Ctx, record_id: []const u8, always: bool) !void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(record_id.len <= records.id_len);

    var record_buffer: [key_len_max]u8 = undefined;
    var type_buffer: [key_len_max]u8 = undefined;
    var index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };
    const found = try records.get(ctx.db, ctx.arena, record_id);
    const live_now = if (found) |record| try statuses.is_live(ctx, record.status) else false;

    if (!always and !live_now) {
        return;
    }

    if (found) |record| {
        const keys = [_][]const u8{
            try record_key(&record_buffer, record.id),
            try type_key(&type_buffer, record.type),
            all_records_key,
        };

        try index.invalidate(&keys, ctx.now_ms);
    } else {
        const keys = [_][]const u8{ try record_key(&record_buffer, record_id), all_records_key };

        try index.invalidate(&keys, ctx.now_ms);
    }
}

pub fn record_key(buffer: *[key_len_max]u8, id: []const u8) ![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(buffer.len == key_len_max);

    return std.fmt.bufPrint(buffer, "record:{s}", .{id});
}

pub fn type_key(buffer: *[key_len_max]u8, handle: []const u8) ![]const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(buffer.len == key_len_max);

    return std.fmt.bufPrint(buffer, "type:{s}", .{handle});
}

test "keys name the record and its type; a buffer too small refuses" {
    var buffer: [key_len_max]u8 = undefined;
    try std.testing.expectEqualStrings("record:abc", try record_key(&buffer, "abc"));
    try std.testing.expectEqualStrings("type:post", try type_key(&buffer, "post"));

    const long = "x" ** key_len_max;
    try std.testing.expectError(error.NoSpaceLeft, record_key(&buffer, long));
}
