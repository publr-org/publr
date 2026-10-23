const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const types = @import("../content_type.zig");
const records = @import("../record.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// For tests: the `post` type every record test writes against.
pub fn post_type(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.now_ms >= 0);

    const definition = try model.content_type.encode(ctx.arena, model.content_type.test_post);

    _ = try registry.SDK.dispatch(ctx, types.Create, .{
        .definition = definition,
    });
}

/// For tests: a new record of `handle`, made live by publishing it.
pub fn published(ctx: *Ctx, handle: []const u8, document: []const u8) Error!records.Create.Out {
    std.debug.assert(handle.len > 0);
    std.debug.assert(document.len > 0);

    var created = try registry.SDK.dispatch(ctx, records.Create, .{
        .type = handle,
        .document = document,
    });
    const moved = try registry.SDK.dispatch(ctx, records.Publish, .{
        .id = created.id,
    });

    created.status = moved.status;
    created.version = moved.version;

    return created;
}
