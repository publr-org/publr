//! Every `record.*` notice becomes changed keys in the dependency index, so the built site
//! (`adapters/site`) rebuilds exactly the pages and fragments that read the record or its
//! type. Raised inside the operation's transaction: a rolled-back write raises nothing.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const records = @import("../../store/records.zig");

const Ctx = sdk.Ctx;
const Event = sdk.Event;

pub const notice_prefix = "record.";
/// The key every listing render records, raised when a change cannot be pinned to a type.
pub const all_records_key = "records";
pub const key_len_max: u32 = 128;

pub const RecordChanged = struct {
    pub const stage: sdk.middleware.Stage = .on;

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

        raise(ctx, notice.subject) catch |err| {
            ctx.dependency_failure = true;
            std.log.debug("site changes: {s} not raised: {s}", .{
                notice.subject,
                @errorName(err),
            });
        };
    }
};

/// `record:<id>` and `type:<handle>` for a record that still exists; `records` for one
/// that is gone (a purge), which every listing depends on.
fn raise(ctx: *Ctx, record_id: []const u8) !void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(record_id.len <= records.id_len);

    var record_buffer: [key_len_max]u8 = undefined;
    var type_buffer: [key_len_max]u8 = undefined;
    var index: deps.Index = .{ .db = ctx.db, .options = .{ .quiet_ms = deps.quiet_ms } };
    const found = try records.get(ctx.db, ctx.arena, record_id);

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
