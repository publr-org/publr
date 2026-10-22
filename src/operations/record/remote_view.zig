//! A record read by a plugin that describes its type with `publr.remote.record`: only the
//! fields it lists come back, the others are never handed to it; while that remote is off
//! (its plugin is not there, or it does not fit) the read answers `Unavailable`.
const std = @import("std");
const sdk = @import("../../sdk.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Grant = sdk.Grant;

/// `document` as the reading plugin may see it, for a record of the type `handle`.
pub fn view(
    ctx: *Ctx,
    granted: *const Grant,
    handle: []const u8,
    document: []const u8,
) Error![]const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const fields = granted.remote_fields(handle) orelse return document;

    if (ctx.sandboxed_plugins) |sandboxed| {
        if (sandboxed.remote_off(granted.remote_user, handle)) {
            return error.Unavailable;
        }
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, document, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    var kept: std.json.ObjectMap = .empty;

    for (fields) |field| {
        if (parsed.object.get(field.name)) |value| {
            kept.put(ctx.arena, field.name, value) catch return error.OutOfMemory;
        }
    }

    return sdk.stringify(ctx.arena, std.json.Value{
        .object = kept,
    });
}

/// `view` over a list's documents, in place.
pub fn view_all(
    ctx: *Ctx,
    granted: *const Grant,
    records: []const @import("../record.zig").Record,
    documents: [][]const u8,
) Error!void {
    std.debug.assert(records.len == documents.len);

    if (granted.remotes.len == 0) {
        return;
    }

    for (records, documents) |record, *document| {
        document.* = try view(ctx, granted, record.type, document.*);
    }
}

test "a remote record's read keeps only the listed fields" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const granted: Grant = .{
        .remote_user = "cart",
        .remotes = &.{.{
            .kind = .record,
            .name = "products.variant",
            .fields = &.{.{
                .name = "sku",
                .holds = .text,
            }},
        }},
    };
    const document =
        \\{"sku":"A-1","price":{"PLN":1200},"secret_note":"x"}
    ;

    const seen = try view(&ctx, &granted, "products.variant", document);
    try std.testing.expectEqualStrings("{\"sku\":\"A-1\"}", seen);

    const other = try view(&ctx, &granted, "products.product", document);
    try std.testing.expectEqualStrings(document, other);
}
