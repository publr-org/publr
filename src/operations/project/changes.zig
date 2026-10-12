//! A `record.*` notice that changes what visitors see becomes changed keys in the dependency
//! index, so the built site (`adapters/site`) rebuilds exactly the pages and fragments that
//! read the record or its type. The built site holds live documents only: an edit kept as
//! pending changes, or written into a record no visitor sees, rebuilds nothing (a preview
//! renders those on request). Raised inside the operation's transaction: a rolled-back
//! write raises nothing.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const records = @import("../../store/records.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Event = sdk.Event;

pub const notice_prefix = "record.";
/// The key every listing render records, raised when a change cannot be pinned to a type.
pub const all_records_key = "records";
pub const key_len_max: u32 = 128;

pub const RecordChanged = struct {
    pub const stage: sdk.middleware.Stage = .on;
    /// Part of the write: a page the write changed and the index never heard of would stay
    /// stale, so a key not raised fails the write.
    pub const intrinsic = true;

    pub fn run(ctx: *Ctx, event: Event) void {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(notice_prefix.len > 0);

        const notice = switch (event) {
            .notice => |notice| notice,
            else => return,
        };

        if (!std.mem.startsWith(u8, notice.name, notice_prefix) or notice.subject.len == 0) {
            return;
        }

        raise(ctx, notice.name[notice_prefix.len..], notice.subject) catch |err| {
            ctx.dependency_failure = true;
            std.log.debug("site changes: {s} not raised: {s}", .{
                notice.subject,
                @errorName(err),
            });
        };
    }

    /// A write over many records: every key they raise, raised at once.
    pub fn run_many(ctx: *Ctx, notices: []const Event.Notice) void {
        std.debug.assert(notices.len > 0);
        std.debug.assert(ctx.db.transaction_depth >= 1);

        raise_many(ctx, notices) catch |err| {
            ctx.dependency_failure = true;
            std.log.debug("site changes: {d} not raised: {s}", .{
                notices.len,
                @errorName(err),
            });
        };
    }
};

fn raise_many(ctx: *Ctx, notices: []const Event.Notice) !void {
    std.debug.assert(notices.len > 0);
    std.debug.assert(key_len_max > 0);

    var subjects: std.ArrayList([]const u8) = .empty;

    for (notices) |notice| {
        if (std.mem.startsWith(u8, notice.name, notice_prefix) and notice.subject.len > 0) {
            try subjects.append(ctx.arena, notice.subject);
        }
    }

    if (subjects.items.len == 0) {
        return;
    }

    const ids_json = try std.json.Stringify.valueAlloc(ctx.arena, subjects.items, .{});
    const found = try records.briefs(ctx.db, ctx.arena, ids_json);
    var keys: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (notices) |notice| {
        if (!std.mem.startsWith(u8, notice.name, notice_prefix) or notice.subject.len == 0) {
            continue;
        }

        const brief = brief_of(found, notice.subject);
        const live_now = if (brief) |record| registry.Statuses.is_live(record.status) else false;
        const action = notice.name[notice_prefix.len..];

        if (action.len == 0 or !touches_live(action, live_now)) {
            continue;
        }

        var record_buffer: [key_len_max]u8 = undefined;
        var type_buffer: [key_len_max]u8 = undefined;

        try add_key(ctx, &keys, &seen, try record_key(&record_buffer, notice.subject));
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

/// Whether a record notice changes what visitors see. Pending changes never do; a save, a
/// creation or a status move does only while the record is live afterwards (going out of
/// live has its own notices); publishing, unpublishing, deleting, restoring and purging
/// always do.
pub fn touches_live(action: []const u8, live_now: bool) bool {
    std.debug.assert(action.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, action, '.') == null);

    const pending = [_][]const u8{ "changed", "changes_saved", "changes_discarded" };
    const while_live = [_][]const u8{ "saved", "created", "transitioned" };

    for (pending) |name| {
        if (std.mem.eql(u8, action, name)) {
            return false;
        }
    }

    for (while_live) |name| {
        if (std.mem.eql(u8, action, name)) {
            return live_now;
        }
    }

    return true;
}

/// `record:<id>` and `type:<handle>` for a record that still exists; `records` for one
/// that is gone (a purge), which every listing depends on.
fn raise(ctx: *Ctx, action: []const u8, record_id: []const u8) !void {
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
    const live_now = if (found) |record| registry.Statuses.is_live(record.status) else false;

    if (action.len == 0 or !touches_live(action, live_now)) {
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

test "only what visitors see raises: pending changes never, saves while live" {
    try std.testing.expect(!touches_live("changed", true));
    try std.testing.expect(!touches_live("changes_saved", true));
    try std.testing.expect(!touches_live("changes_discarded", true));
    try std.testing.expect(!touches_live("saved", false));
    try std.testing.expect(touches_live("saved", true));
    try std.testing.expect(!touches_live("created", false));
    try std.testing.expect(touches_live("unpublished", false));
    try std.testing.expect(touches_live("deleted", false));
    try std.testing.expect(touches_live("purged", false));
    try std.testing.expect(touches_live("published", true));
}
