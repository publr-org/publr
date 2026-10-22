//! The record or term each typed transition event moved (`post.transitioned`): what a move
//! over many tells its readers per record, as a move of its own does.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const flow = @import("../../model/flow.zig");
const changed_units = @import("../changed_units.zig");
const records = @import("../../operations/record.zig");
const terms = @import("../../operations/term.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Kind = changed_units.Kind;
const Unit = changed_units.Unit;

/// What a transition event says: the record or term as a unit, and its move.
pub const Move = struct {
    unit: Unit,
    transition: flow.Transitioned,
};

/// An intrinsic listener, inside the write, handing `keep` the record or term each
/// transition event of `kinds` moved.
pub fn Moves(comptime kinds: []const Kind, comptime keep: changed_units.Keep) type {
    comptime std.debug.assert(kinds.len > 0);

    return struct {
        pub const stage: sdk.middleware.Stage = .on;
        pub const intrinsic = true;

        pub fn run(ctx: *Ctx, event: sdk.Event) void {
            std.debug.assert(ctx.now_ms >= 0);

            const emitted = switch (event) {
                .emitted => |found| found,
                else => return,
            };
            const found = moved(ctx, emitted) catch |err| {
                std.log.warn("changed units: {s} not read: {t}", .{ emitted.name, err });
                return;
            };
            const move = found orelse return;

            if (changed_units.listed(kinds, move.unit.kind)) {
                keep(ctx, emitted.name, move.unit);
            }
        }
    };
}

/// The record or term a transition event moved: a type's handle names a record, a
/// taxonomy's a term. Null for any other event.
pub fn moved(ctx: *Ctx, emitted: sdk.Event.Emitted) Error!?Move {
    std.debug.assert(emitted.name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const handle = handle_of(emitted.name) orelse return null;
    const payload = std.json.parseFromSliceLeaky(flow.Transitioned, ctx.arena, emitted.subject, .{
        .ignore_unknown_fields = true,
    }) catch return null;

    if (payload.record.len == 0) {
        return null;
    }

    const kind: Kind = if (try records.domain.definition.find(ctx, handle) != null)
        .record
    else if (try terms.domain.definition.find(ctx, handle) != null)
        .term
    else
        return null;

    return .{
        .unit = .{
            .kind = kind,
            .key = payload.record,
        },
        .transition = payload,
    };
}

/// `post` of `post.transitioned`, `shop.product` of `shop.product_transitioned`.
fn handle_of(name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    const plain = ".transitioned";

    if (std.mem.endsWith(u8, name, flow.any_suffix)) {
        const handle = name[0 .. name.len - flow.any_suffix.len];

        if (std.mem.indexOfScalar(u8, handle, '.') != null) {
            return handle;
        }
    }

    if (std.mem.endsWith(u8, name, plain)) {
        const handle = name[0 .. name.len - plain.len];

        if (handle.len > 0 and std.mem.indexOfScalar(u8, handle, '.') == null) {
            return handle;
        }
    }

    return null;
}

test "a transition event names its type's handle; other events none" {
    try std.testing.expectEqualStrings("post", handle_of("post.transitioned").?);
    try std.testing.expectEqualStrings("shop.product", handle_of("shop.product_transitioned").?);
    try std.testing.expectEqual(@as(?[]const u8, null), handle_of("record.save"));
    try std.testing.expectEqual(@as(?[]const u8, null), handle_of("a.b.transitioned"));
    try std.testing.expectEqual(@as(?[]const u8, null), handle_of("post_transitioned"));
}
