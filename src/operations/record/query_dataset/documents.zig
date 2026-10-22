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
};

/// A record as a query sees it: its columns as `_` attributes, then its fields as stored.
pub fn document_of(
    arena: std.mem.Allocator,
    record: Columns,
    text: []const u8,
    mask: []const []const u8,
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

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.DatasetFailed;
    };
    const converted = try groq.values.from_json(arena, parsed);

    if (converted == .object) {
        for (converted.object.keys, converted.object.values) |key, held| {
            if (!hidden(mask, key)) {
                try builder.put(arena, key, held);
            }
        }
    }

    return .{
        .object = builder.object(),
    };
}

/// Whether the grant hides a field: named itself, or a field inside it (`seo.title` hides
/// `seo`, the safe way round).
fn hidden(mask: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    for (mask) |path| {
        const top = path[0 .. std.mem.indexOfScalar(u8, path, '.') orelse path.len];

        if (std.mem.eql(u8, top, key)) {
            return true;
        }
    }

    return false;
}
