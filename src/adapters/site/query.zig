//! Optional native operation bridge. The HTTP host authenticates scope and publishes policy headers.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
fn OperationResult(comptime T: type) type {
    return struct {
        pub const publr_operation_result = true;
        value: T,
        policy: sdk.Ctx.OperationPolicy,
    };
}
const tracking = sdk.dependencies;

pub fn execute(comptime operation: anytype, ctx: *sdk.Ctx, arguments: anytype, secret: []const u8, scope: tracking.Scope, ttl_ms: ?u32) !OperationResult(@typeInfo(@typeInfo(@TypeOf(operation)).@"fn".return_type.?).error_union.payload) {
    var transaction = try ctx.db.transaction();
    defer transaction.rollback();
    var index: deps.Index = .{ .db = ctx.db, .options = .{} };
    const revision = try index.revision();
    var collected: tracking.Collector = .{ .arena = ctx.arena };
    var owned = ctx.collecting(&collected);
    const value = try @call(.auto, operation, .{&owned} ++ arguments);
    const tokens = try ctx.arena.alloc([]const u8, collected.keys.items.len);
    for (collected.keys.items, tokens) |key, *token| token.* = try tracking.token(ctx.arena, secret, scope, key);
    return .{ .value = value, .policy = .{
        .revision = revision,
        .revalidate = false,
        .no_store = !collected.complete,
        .expires = if (ttl_ms) |ttl| ctx.now_ms + ttl else null,
        .tags = tokens,
    } };
}

pub const Replay = struct { revision: u64, reset: bool, tags: []const []const u8 };

/// Poll only after commit. Reconnect from the last revision; reset expires every retained result.
pub fn replay(ctx: *sdk.Ctx, after: u64, secret: []const u8, scope: tracking.Scope) !Replay {
    var index: deps.Index = .{ .db = ctx.db, .options = .{} };
    const changes = try index.changes_since(ctx.arena, after);
    const tokens = try ctx.arena.alloc([]const u8, changes.keys.len);
    for (changes.keys, tokens) |key, *token| token.* = try tracking.token(ctx.arena, secret, scope, key);
    return .{ .revision = changes.revision, .reset = changes.reset, .tags = tokens };
}
