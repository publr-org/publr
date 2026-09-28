const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");

const tracking = sdk.dependencies;

/// An optional native operation bridge: the HTTP host authenticates the scope and publishes
/// the policy headers.
fn OperationResult(comptime Value: type) type {
    return struct {
        pub const publr_operation_result = true;
        value: Value,
        policy: sdk.Ctx.OperationPolicy,
    };
}

fn Payload(comptime operation: anytype) type {
    const returned = @typeInfo(@TypeOf(operation)).@"fn".return_type.?;

    return @typeInfo(returned).error_union.payload;
}

pub fn execute(
    comptime operation: anytype,
    ctx: *sdk.Ctx,
    arguments: anytype,
    secret: []const u8,
    scope: tracking.Scope,
    ttl_ms: ?u32,
) !OperationResult(Payload(operation)) {
    std.debug.assert(secret.len > 0);
    std.debug.assert(scope.site.len > 0);

    var transaction = try ctx.db.transaction();
    defer transaction.rollback();

    var index: deps.Index = .{ .db = ctx.db, .options = .{} };
    const revision = try index.revision();
    var collected: tracking.Collector = .{ .arena = ctx.arena };
    var owned = ctx.collecting(&collected);
    const value = try @call(.auto, operation, .{&owned} ++ arguments);
    const tokens = try tag_tokens(ctx.arena, secret, scope, collected.keys.items);

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
    std.debug.assert(secret.len > 0);
    std.debug.assert(scope.site.len > 0);

    var index: deps.Index = .{ .db = ctx.db, .options = .{} };
    const changes = try index.changes_since(ctx.arena, after);
    const tokens = try tag_tokens(ctx.arena, secret, scope, changes.keys);

    return .{ .revision = changes.revision, .reset = changes.reset, .tags = tokens };
}

fn tag_tokens(
    arena: std.mem.Allocator,
    secret: []const u8,
    scope: tracking.Scope,
    keys: []const []const u8,
) ![]const []const u8 {
    std.debug.assert(secret.len > 0);
    std.debug.assert(scope.authority.len > 0);

    const tokens = try arena.alloc([]const u8, keys.len);

    for (keys, tokens) |key, *token| {
        token.* = try tracking.token(arena, secret, scope, key);
    }

    return tokens;
}
