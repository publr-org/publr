//! What a write did to records that changes what visitors see becomes changed keys in the
//! dependency index, so the built site (`adapters/site`) rebuilds exactly the pages and
//! fragments that read the record or its type. Heard as any plugin hears it: around the
//! record operations that write a document, from their input and answer; every move goes
//! through `record.transition` or `record.delete`, and a move over many runs their hooks
//! per record. The built site holds live documents only: an edit kept as pending changes,
//! or written into a record no visitor sees, rebuilds nothing (a preview renders those on
//! request). Raised inside the operation's transaction: a rolled-back write raises nothing.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const records = @import("../../store/records.zig");
const statuses = @import("../status.zig");
const record_operations = @import("../record.zig");
const project_put = @import("put.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// The key every listing render records, raised when a change cannot be pinned to a type.
pub const all_records_key = "records";
pub const key_len_max: u32 = 128;

fn failed(ctx: *Ctx, err: anyerror) void {
    std.debug.assert(@errorName(err).len > 0);

    ctx.dependency_failure = true;
    std.log.debug("site changes: not raised: {s}", .{@errorName(err)});
}

/// The hooks on the record operations that write a document. A move is heard on both
/// sides: `before`, what visitors saw where it was; `after`, where it is now.
pub const hooks = [_]type{
    After(record_operations.Create, created),
    After(record_operations.Save, saved),
    After(record_operations.Publish, published),
    Before(record_operations.Transition, leaving),
    After(record_operations.Transition, moved),
    After(record_operations.Delete, trashed),
    After(record_operations.Purge, purged),
    After(project_put.Put, put),
};

fn Before(comptime Operation: type, comptime raised: anytype) type {
    return struct {
        pub const stage: sdk.hooks.Stage = .before;
        pub const operation = Operation.name;

        pub fn run(ctx: *Ctx, in: *Operation.In) Error!void {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(ctx.parent != null);

            raised(ctx, in) catch |err| {
                if (err == error.OutOfMemory) {
                    return error.OutOfMemory;
                }

                failed(ctx, err);
            };
        }
    };
}

fn After(comptime Operation: type, comptime raised: anytype) type {
    return struct {
        pub const stage: sdk.hooks.Stage = .after;
        pub const operation = Operation.name;

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

/// About to move out of where visitors see it: live, or kept in the archive or the trash.
fn leaving(ctx: *Ctx, in: *const record_operations.Transition.In) !void {
    std.debug.assert(in.id.len > 0);

    const record = try records.get(ctx.db, ctx.arena, in.id) orelse return;

    if (kept(record.status) or try statuses.is_live(ctx, record.status)) {
        try raise(ctx, in.id, true);
    }
}

/// Moved: live now, into the archive or the trash, or gone for good; `publish` named on a
/// live record applied its pending changes. A move asked for waits: nothing changed.
fn moved(
    ctx: *Ctx,
    in: *const record_operations.Transition.In,
    out: *const record_operations.Transition.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    if (!out.pending) {
        try raise(ctx, in.id, kept(out.status) or std.mem.eql(u8, out.status, "destroyed"));
    }
}

/// Into the trash, from wherever it was.
fn trashed(
    ctx: *Ctx,
    in: *const record_operations.Delete.In,
    _: *const record_operations.Delete.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    try raise(ctx, in.id, true);
}

/// The statuses whose records visitors may still reach: archived pages, the trash.
fn kept(status: []const u8) bool {
    return std.mem.eql(u8, status, "archived") or std.mem.eql(u8, status, "trashed");
}

fn purged(
    ctx: *Ctx,
    in: *const record_operations.Purge.In,
    _: *const record_operations.Purge.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    try raise(ctx, in.id, true);
}

/// Each record put as another copy keeps it, whatever its status was or is.
fn put(ctx: *Ctx, _: *const project_put.Put.In, out: *const project_put.Put.Out) !void {
    std.debug.assert(out.put.len <= project_put.units_max);

    for (out.put) |done| {
        const record = std.mem.eql(u8, done.kind, "record");

        if (record and !std.mem.eql(u8, done.outcome, "unchanged")) {
            try raise(ctx, done.id, true);
        }
    }
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
