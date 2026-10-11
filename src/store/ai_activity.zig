const std = @import("std");
const db = @import("../lib/db.zig");
const ai = @import("../model/ai.zig");

/// One row of `ai_activity`. Field order is the column order of the select.
pub const Activity = struct {
    doing: []const u8,
    since: i64,
};

/// What the conversation's agent does now, from `now_ms`.
pub fn set(
    connection: *db.Db,
    conversation_id: []const u8,
    doing: []const u8,
    now_ms: i64,
) db.Error!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(doing.len > 0 and doing.len <= ai.activity_len_max);

    var statement = try connection.prepare(
        "INSERT INTO ai_activity (conversation_id, doing, since) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT (conversation_id) DO UPDATE SET doing = excluded.doing, " ++
            "since = excluded.since",
    );
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.bind_text(2, doing);
    try statement.bind_int(3, now_ms);
    try statement.exec();
}

/// What the conversation's agent does now, or null between turns.
pub fn get(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conversation_id: []const u8,
) db.Error!?Activity {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(conversation_id.len <= 128);

    var select = try connection.prepare(
        "SELECT doing, since FROM ai_activity WHERE conversation_id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, conversation_id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Activity, arena);
}

/// The turn ended: nothing is being done.
pub fn clear(connection: *db.Db, conversation_id: []const u8) db.Error!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(conversation_id.len <= 128);

    var statement = try connection.prepare("DELETE FROM ai_activity WHERE conversation_id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.exec();
}
