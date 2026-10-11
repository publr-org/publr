const std = @import("std");
const db = @import("../lib/db.zig");
const ai = @import("../model/ai.zig");

/// One row of `ai_browsers`. Field order is the column order of `select_browser`.
pub const Browser = struct {
    ready_at: i64,
    number: i64,
    state: []const u8,
    call: []const u8,
    answer: []const u8,
    failed: i64,
    picture: []const u8,
};

const select_browser = "SELECT ready_at, number, state, call, answer, failed, picture " ++
    "FROM ai_browsers WHERE conversation_id = ?1";

/// The conversation's browser, or null when none was ever there.
pub fn get(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conversation_id: []const u8,
) db.Error!?Browser {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(select_browser.len > 0);

    var select = try connection.prepare(select_browser);
    defer select.finalize();

    try select.bind_text(1, conversation_id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Browser, arena);
}

/// The workspace says the extension is there.
pub fn ready(connection: *db.Db, conversation_id: []const u8, now_ms: i64) db.Error!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(now_ms > 0);

    var statement = try connection.prepare(
        "INSERT INTO ai_browsers (conversation_id, ready_at) VALUES (?1, ?2) " ++
            "ON CONFLICT (conversation_id) DO UPDATE SET ready_at = excluded.ready_at",
    );
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.bind_int(2, now_ms);
    try statement.exec();
}

/// A call waits for the browser, after the one before it; its number.
pub fn call(connection: *db.Db, conversation_id: []const u8, text: []const u8) db.Error!u32 {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(text.len > 0 and text.len <= ai.browser_call_len_max);

    var statement = try connection.prepare(
        "INSERT INTO ai_browsers (conversation_id, number, state, call) " ++
            "VALUES (?1, 1, 'pending', ?2) ON CONFLICT (conversation_id) DO UPDATE SET " ++
            "number = number + 1, state = 'pending', call = excluded.call, answer = '', " ++
            "failed = 0, picture = '' RETURNING number",
    );
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.bind_text(2, text);

    if (!try statement.step()) {
        return error.Sqlite;
    }

    const number = statement.read_int();

    std.debug.assert(number > 0);

    return @intCast(number);
}

pub const Answer = struct {
    text: []const u8,
    failed: bool,
    picture: []const u8,
};

/// Call `number`'s answer, while it is the one pending. Whether it was.
pub fn answer(
    connection: *db.Db,
    conversation_id: []const u8,
    number: u32,
    given: Answer,
) db.Error!bool {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(given.picture.len <= ai.browser_picture_len_max);

    var statement = try connection.prepare(
        "UPDATE ai_browsers SET state = 'answered', answer = ?3, failed = ?4, picture = ?5 " ++
            "WHERE conversation_id = ?1 AND number = ?2 AND state = 'pending'",
    );
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.bind_int(2, number);
    try statement.bind_text(3, given.text);
    try statement.bind_int(4, @intFromBool(given.failed));
    try statement.bind_text(5, given.picture);
    try statement.exec();

    return connection.changes() == 1;
}

/// Nothing in flight: the turn ended, or the agent stopped waiting.
pub fn settle(connection: *db.Db, conversation_id: []const u8) db.Error!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(conversation_id.len <= 128);

    var statement = try connection.prepare(
        "UPDATE ai_browsers SET state = 'idle', call = '', answer = '', failed = 0, " ++
            "picture = '' WHERE conversation_id = ?1",
    );
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.exec();
}

/// The browser went away: the workspace closed, or the extension with it.
pub fn forget(connection: *db.Db, conversation_id: []const u8) db.Error!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(conversation_id.len <= 128);

    var statement = try connection.prepare("DELETE FROM ai_browsers WHERE conversation_id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.exec();
}
