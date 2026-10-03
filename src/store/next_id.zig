//! A new time-ordered id for a table (`lib/id.zig`): after the greatest one it holds for
//! the same millisecond, so ids made in one millisecond keep their order. SQLite has one
//! writer at a time, so two writers never read the same latest id.

const std = @import("std");
const db = @import("../lib/db.zig");
const ids = @import("../lib/id.zig");

pub fn next(
    comptime table: []const u8,
    connection: *db.Db,
    io: std.Io,
    now_ms: i64,
    out: *[ids.len]u8,
) db.Error![]const u8 {
    std.debug.assert(table.len > 0);
    std.debug.assert(now_ms >= 0);

    var low: [ids.len]u8 = undefined;
    var high: [ids.len]u8 = undefined;

    ids.millisecond_range(now_ms, &low, &high);

    var select = try connection.prepare("SELECT max(id) FROM " ++ table ++
        " WHERE id BETWEEN ?1 AND ?2");
    defer select.finalize();

    try select.bind_text(1, &low);
    try select.bind_text(2, &high);

    var latest_buffer: [ids.len]u8 = undefined;
    var latest: ?[]const u8 = null;

    if (try select.step()) {
        var scratch: [256]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&scratch);
        const Row = struct { id: ?[]const u8 };
        const row = try select.read(Row, fixed.allocator());

        if (row.id) |found| {
            if (found.len == ids.len) {
                @memcpy(&latest_buffer, found);
                latest = &latest_buffer;
            }
        }
    }

    return ids.ordered(io, now_ms, latest, out);
}
