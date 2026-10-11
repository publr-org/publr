const std = @import("std");
const db = @import("../lib/db.zig");
const ai = @import("../model/ai.zig");

/// One row of `ai_pictures`. Field order is the column order of the select.
pub const Picture = struct {
    asked: i64,
    media_key: []const u8,
};

/// Keeps an ask's pictures, in order.
pub fn insert(
    connection: *db.Db,
    conversation_id: []const u8,
    asked: u32,
    media_keys: []const []const u8,
) db.Error!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(media_keys.len <= ai.pictures_max);

    var statement = try connection.prepare(
        "INSERT INTO ai_pictures (conversation_id, asked, ordinal, media_key) " ++
            "VALUES (?1, ?2, ?3, ?4)",
    );
    defer statement.finalize();

    for (media_keys, 0..) |media_key, ordinal| {
        statement.reset();
        try statement.bind_text(1, conversation_id);
        try statement.bind_int(2, asked);
        try statement.bind_int(3, @intCast(ordinal));
        try statement.bind_text(4, media_key);
        try statement.exec();
    }
}

/// A conversation's pictures, by ask and then in order.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conversation_id: []const u8,
) db.Error![]Picture {
    std.debug.assert(conversation_id.len > 0);

    const limit = ai.pictures_max * ai.steps_max;
    var select = try connection.prepare(
        "SELECT asked, media_key FROM ai_pictures WHERE conversation_id = ?1 " ++
            "ORDER BY asked, ordinal LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, conversation_id);
    try select.bind_int(2, limit);

    var rows: std.ArrayList(Picture) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(Picture, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}
