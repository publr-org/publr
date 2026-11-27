//! Queued work's context: `publr.QueueCtx`, declared in `publr/queue_ctx.zig`.
const std = @import("std");

pub const QueueCtx = @import("../../publr/queue_ctx.zig").QueueCtx;

/// The plugin's context under either: what the SDK's own calls (record handles, queries)
/// take, so they work in a request and in queued work alike.
pub fn base_of(ctx: anytype) BaseOf(@TypeOf(ctx)) {
    if (comptime std.meta.Child(@TypeOf(ctx)) == QueueCtx) {
        return ctx.base;
    }

    return ctx;
}

fn BaseOf(comptime Pointer: type) type {
    const Child = std.meta.Child(Pointer);

    if (Child == QueueCtx) {
        return @FieldType(Child, "base");
    }

    return Pointer;
}
