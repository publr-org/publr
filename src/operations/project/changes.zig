//! What a write did to records that changes what visitors see becomes changed keys in the
//! dependency index, so the built site (`adapters/site`) rebuilds exactly the pages and
//! fragments that read the record or its type. Heard as any plugin hears it: around the
//! record operations that write a document, from their input and answer; every move goes
//! through `record.transition` or `record.delete`, and a move over many runs their hooks
//! per record. The built site holds live documents only: an edit kept as pending changes
//! rebuilds nothing (a preview renders those on request). Internal records have no copy
//! visitors see, yet a page may show what is worked out from them ("only 3 left"): every
//! write to one raises its keys (`internal_changed`), and the pages that read it rebuild.
//! Raised inside the operation's transaction: a rolled-back write raises nothing.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const records = @import("../../store/records.zig");
const statuses = @import("../status.zig");
const record_operations = @import("../record.zig");
const project_put = @import("put.zig");
const term_operations = @import("../term.zig");
const terms = @import("../../store/terms.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// The key every listing render records, raised when a change cannot be pinned to a type.
pub const all_records_key = "records";
/// The same for terms: every term listing reads it, a term gone for good raises it.
pub const all_terms_key = "terms";
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
    After(term_operations.Create, term_created),
    After(term_operations.Save, term_saved),
    After(term_operations.Publish, term_published),
    Before(term_operations.Transition, term_leaving),
    After(term_operations.Transition, term_moved),
    After(term_operations.Delete, term_trashed),
    After(term_operations.Purge, term_purged),
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

/// Each record or term put as another copy keeps it, whatever its status was or is. An
/// internal record put raises its own keys as it lands (`put.zig`).
fn put(ctx: *Ctx, _: *const project_put.Put.In, out: *const project_put.Put.Out) !void {
    std.debug.assert(out.put.len <= project_put.units_max);

    for (out.put) |done| {
        if (std.mem.eql(u8, done.outcome, "unchanged")) {
            continue;
        }

        if (std.mem.eql(u8, done.kind, "record")) {
            try raise(ctx, done.id, true);
        } else if (std.mem.eql(u8, done.kind, "term")) {
            try raise_term(ctx, done.id, true);
        }
    }
}

/// Terms are shown as records are: the same moves raise, live ones only but for the trash.
fn term_created(
    ctx: *Ctx,
    _: *const term_operations.Create.In,
    out: *const term_operations.Create.Out,
) !void {
    std.debug.assert(out.id.len > 0);

    try raise_term(ctx, out.id, false);
}

fn term_saved(
    ctx: *Ctx,
    in: *const term_operations.Save.In,
    out: *const term_operations.Save.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    if (std.mem.eql(u8, out.outcome, "saved")) {
        try raise_term(ctx, in.id, false);
    }
}

/// Put live, or its pending changes applied (which answers `changed` false): live after it.
fn term_published(
    ctx: *Ctx,
    in: *const term_operations.Publish.In,
    out: *const term_operations.Publish.Out,
) !void {
    std.debug.assert(in.id.len > 0);
    std.debug.assert(out.status.len > 0);

    try raise_term(ctx, in.id, false);
}

fn term_leaving(ctx: *Ctx, in: *const term_operations.Transition.In) !void {
    std.debug.assert(in.id.len > 0);

    const term = try terms.get(ctx.db, ctx.arena, in.id) orelse return;

    if (kept(term.status) or try statuses.is_live(ctx, term.status)) {
        try raise_term(ctx, in.id, true);
    }
}

fn term_moved(
    ctx: *Ctx,
    in: *const term_operations.Transition.In,
    out: *const term_operations.Transition.Out,
) !void {
    std.debug.assert(in.id.len > 0);
    std.debug.assert(out.status.len > 0);

    try raise_term(ctx, in.id, kept(out.status));
}

fn term_trashed(
    ctx: *Ctx,
    in: *const term_operations.Delete.In,
    _: *const term_operations.Delete.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    try raise_term(ctx, in.id, true);
}

fn term_purged(
    ctx: *Ctx,
    in: *const term_operations.Purge.In,
    _: *const term_operations.Purge.Out,
) !void {
    std.debug.assert(in.id.len > 0);

    try raise_term(ctx, in.id, true);
}

/// `term:<id>`, `taxonomy:<handle>` and `terms` for a term that still exists; `term:<id>`
/// and `terms` for one gone for good. Only while it is live, unless `always`.
fn raise_term(ctx: *Ctx, term_id: []const u8, always: bool) !void {
    std.debug.assert(term_id.len > 0);
    std.debug.assert(term_id.len <= key_len_max);

    var term_buffer: [key_len_max]u8 = undefined;
    var taxonomy_buffer: [key_len_max]u8 = undefined;
    var index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };
    const found = try terms.get(ctx.db, ctx.arena, term_id);
    const live_now = if (found) |term| try statuses.is_live(ctx, term.status) else false;

    if (!always and !live_now) {
        return;
    }

    const own = try term_key(&term_buffer, term_id);

    if (found) |term| {
        const keys = [_][]const u8{
            own,
            try taxonomy_key(&taxonomy_buffer, term.type),
            all_terms_key,
        };

        try index.invalidate(&keys, ctx.now_ms);
    } else {
        try index.invalidate(&.{ own, all_terms_key }, ctx.now_ms);
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

/// An internal record written (`id`): `internal:<plugin>/<kind>/<id>`, read by a page that
/// got that record, and `internal:<plugin>/<kind>`, read by one that looked records up.
/// Records of the collection gone at once (null: expired, or the collection dropped):
/// `internal:<plugin>/<kind>/*`, which every page that got one of its records reads.
pub fn internal_changed(
    ctx: *Ctx,
    plugin: []const u8,
    kind: []const u8,
    id: ?[]const u8,
) !void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(kind.len > 0);

    std.debug.assert(id == null or !std.mem.eql(u8, id.?, internal_every));

    var record_buffer: [key_len_max]u8 = undefined;
    var collection_buffer: [key_len_max]u8 = undefined;
    var index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };
    const keys = [_][]const u8{
        try internal_key(&record_buffer, plugin, kind, id orelse internal_every),
        try internal_key(&collection_buffer, plugin, kind, null),
    };

    try index.invalidate(&keys, ctx.now_ms);
}

/// In place of a record's id: every record of the collection.
pub const internal_every = "*";

pub fn internal_key(
    buffer: *[key_len_max]u8,
    plugin: []const u8,
    kind: []const u8,
    id: ?[]const u8,
) ![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(kind.len > 0);

    if (id) |record_id| {
        return std.fmt.bufPrint(buffer, "internal:{s}/{s}/{s}", .{ plugin, kind, record_id });
    }

    return std.fmt.bufPrint(buffer, "internal:{s}/{s}", .{ plugin, kind });
}

pub fn record_key(buffer: *[key_len_max]u8, id: []const u8) ![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(buffer.len == key_len_max);

    return std.fmt.bufPrint(buffer, "record:{s}", .{id});
}

pub const Listed = enum { records, terms };

/// A listing read for a page being drawn for the built site: each type (or taxonomy) named,
/// and every record (or term), which a change no type pins down raises.
pub fn listed(
    ctx: *Ctx,
    of: Listed,
    handle: ?[]const u8,
    handles: []const []const u8,
) Error!void {
    std.debug.assert(handles.len <= 64 << 10);

    if (ctx.reads == null) {
        return;
    }

    var buffer: [key_len_max]u8 = undefined;
    const one: []const []const u8 = if (handle) |named| &.{named} else &.{};

    for ([_][]const []const u8{ one, handles }) |group| {
        for (group) |each| {
            if (each.len == 0) {
                continue;
            }

            const key = switch (of) {
                .records => type_key(&buffer, each),
                .terms => taxonomy_key(&buffer, each),
            } catch return error.Invalid;

            ctx.depends_on(key);
        }
    }

    ctx.depends_on(switch (of) {
        .records => all_records_key,
        .terms => all_terms_key,
    });
}

pub fn term_key(buffer: *[key_len_max]u8, id: []const u8) ![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(buffer.len == key_len_max);

    return std.fmt.bufPrint(buffer, "term:{s}", .{id});
}

pub fn taxonomy_key(buffer: *[key_len_max]u8, handle: []const u8) ![]const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(buffer.len == key_len_max);

    return std.fmt.bufPrint(buffer, "taxonomy:{s}", .{handle});
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
    try std.testing.expectEqualStrings(
        "internal:shop/stock/abc",
        try internal_key(&buffer, "shop", "stock", "abc"),
    );
    try std.testing.expectEqualStrings(
        "internal:shop/stock",
        try internal_key(&buffer, "shop", "stock", null),
    );

    const long = "x" ** key_len_max;
    try std.testing.expectError(error.NoSpaceLeft, record_key(&buffer, long));
}
