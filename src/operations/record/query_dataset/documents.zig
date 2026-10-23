//! A record as a query sees it, and the order queries read records in.

const std = @import("std");
const groq = @import("../../../lib/groq.zig");

const Value = groq.Value;

pub fn by_id(_: void, left: Value, right: Value) bool {
    std.debug.assert(left == .object and right == .object);

    const left_id = left.object.get("_id").?.string;
    const right_id = right.object.get("_id").?.string;

    return std.mem.order(u8, left_id, right_id) == .lt;
}

/// The columns a query sees as `_` attributes.
pub const Columns = struct {
    id: []const u8,
    type: []const u8,
    created_at: i64,
    updated_at: i64,
    /// The record's status as stored (`published`, `checkout.placed`); an internal record
    /// has none.
    status: ?[]const u8 = null,
};

/// A record as a query sees it: its columns as `_` attributes, its `status`, then its fields
/// as stored.
pub fn document_of(
    arena: std.mem.Allocator,
    record: Columns,
    text: []const u8,
) groq.DatasetError!Value {
    var builder: groq.values.ObjectBuilder = .{};
    var buffer: [40]u8 = undefined;

    try builder.put(arena, "_id", .{
        .string = record.id,
    });
    try builder.put(arena, "_type", .{
        .string = record.type,
    });
    try builder.put(arena, "_createdAt", .{
        .string = try arena.dupe(u8, groq.datetimes.format(&buffer, .{
            .seconds = @divFloor(record.created_at, 1000),
            .nanoseconds = @intCast(@mod(record.created_at, 1000) * 1_000_000),
        })),
    });
    try builder.put(arena, "_updatedAt", .{
        .string = try arena.dupe(u8, groq.datetimes.format(&buffer, .{
            .seconds = @divFloor(record.updated_at, 1000),
            .nanoseconds = @intCast(@mod(record.updated_at, 1000) * 1_000_000),
        })),
    });

    if (record.status) |status| {
        try builder.put(arena, "status", .{
            .string = status,
        });
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.DatasetFailed;
    };
    const converted = try groq.values.from_json(arena, parsed);

    if (converted == .object) {
        for (converted.object.keys, converted.object.values) |key, held| {
            try builder.put(arena, key, held);
        }
    }

    return .{
        .object = builder.object(),
    };
}
