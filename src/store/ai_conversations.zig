const std = @import("std");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");
const db = @import("../lib/db.zig");
const ai = @import("../model/ai.zig");

pub const id_len = ids.len;

/// One row of `ai_conversations`. Field order is the column order of `select_conversation`.
pub const Conversation = struct {
    id: []const u8,
    user_id: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    scope: []const u8,
    state: []const u8,
    answer: []const u8,
    device_id: []const u8,
    input_tokens: i64,
    output_tokens: i64,
    created_at: i64,
    updated_at: i64,
    cached_tokens: i64,
};

const select_conversation = "SELECT id, user_id, prompt, provider, model, scope, state, " ++
    "answer, device_id, input_tokens, output_tokens, created_at, updated_at, cached_tokens " ++
    "FROM ai_conversations";

pub const New = struct {
    user_id: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    scope: []const u8,
};

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    new: New,
    now_ms: i64,
) db.Error![]const u8 {
    std.debug.assert(new.user_id.len > 0 and new.prompt.len > 0);
    std.debug.assert(new.prompt.len <= ai.prompt_len_max);

    var id_buffer: [id_len]u8 = undefined;
    const made = try next_id.next("ai_conversations", connection, io, now_ms, &id_buffer);
    const id = arena.dupe(u8, made) catch return error.OutOfMemory;

    var statement = try connection.prepare(
        "INSERT INTO ai_conversations (id, user_id, prompt, provider, model, scope, state, " ++
            "created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', ?7, ?7)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, new.user_id);
    try statement.bind_text(3, new.prompt);
    try statement.bind_text(4, new.provider);
    try statement.bind_text(5, new.model);
    try statement.bind_text(6, new.scope);
    try statement.bind_int(7, now_ms);
    try statement.exec();

    return id;
}

pub fn get(
    connection: *db.Db,
    arena: std.mem.Allocator,
    id: []const u8,
) db.Error!?Conversation {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    var select = try connection.prepare(select_conversation ++ " WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Conversation, arena);
}

/// A person's conversations, newest first.
/// A person's conversations, newest first, `limit` of them from `offset`.
pub fn list_by_user(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_id: []const u8,
    offset: u32,
    limit: u32,
) db.Error![]Conversation {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(limit > 0 and limit <= ai.listed_max);

    var select = try connection.prepare(select_conversation ++
        " WHERE user_id = ?1 ORDER BY created_at DESC, id DESC LIMIT ?2 OFFSET ?3");
    defer select.finalize();

    try select.bind_text(1, user_id);
    try select.bind_int(2, limit);
    try select.bind_int(3, offset);

    var rows: std.ArrayList(Conversation) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(Conversation, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// How many conversations a person has.
pub fn count_by_user(connection: *db.Db, user_id: []const u8) db.Error!u32 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*) FROM ai_conversations WHERE user_id = ?1");
    defer select.finalize();

    try select.bind_text(1, user_id);

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// Moves a conversation to `state`. False when it is unknown.
pub fn set_state(
    connection: *db.Db,
    id: []const u8,
    state: ai.State,
    now_ms: i64,
) db.Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(now_ms >= 0);

    var statement = try connection.prepare(
        "UPDATE ai_conversations SET state = ?1, updated_at = ?2 WHERE id = ?3",
    );
    defer statement.finalize();

    try statement.bind_text(1, @tagName(state));
    try statement.bind_int(2, now_ms);
    try statement.bind_text(3, id);
    try statement.exec();

    return connection.changes() == 1;
}

/// The conversation runs as no device: its next turn makes one.
pub fn release_device(connection: *db.Db, id: []const u8) db.Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 64);

    var statement = try connection.prepare(
        "UPDATE ai_conversations SET device_id = '' WHERE id = ?1",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.exec();
}

pub fn set_device(connection: *db.Db, id: []const u8, device_id: []const u8) db.Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(device_id.len > 0);

    var statement = try connection.prepare(
        "UPDATE ai_conversations SET device_id = ?1 WHERE id = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, device_id);
    try statement.bind_text(2, id);
    try statement.exec();
}

/// Starts another turn: running again, its device to be made anew.
pub fn resume_turn(connection: *db.Db, id: []const u8, now_ms: i64) db.Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(now_ms >= 0);

    var statement = try connection.prepare(
        "UPDATE ai_conversations SET state = 'running', device_id = '', updated_at = ?1 " ++
            "WHERE id = ?2",
    );
    defer statement.finalize();

    try statement.bind_int(1, now_ms);
    try statement.bind_text(2, id);
    try statement.exec();
}

/// The devices of the turns still running or stopping.
pub fn unfinished_devices(
    connection: *db.Db,
    arena: std.mem.Allocator,
) db.Error![]const []const u8 {
    std.debug.assert(ai.listed_max > 0);
    std.debug.assert(connection.transaction_depth >= 0);

    var select = try connection.prepare(
        "SELECT device_id FROM ai_conversations " ++
            "WHERE state IN ('running', 'stopping') AND device_id != '' LIMIT 1024",
    );
    defer select.finalize();

    const Row = struct {
        device_id: []const u8,
    };
    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        const row = try select.read(Row, arena);

        found.append(arena, row.device_id) catch return error.OutOfMemory;
    }

    return found.items;
}

/// Ends every turn still running or stopping: their agents went with the server that started
/// them. Answers how many.
/// The conversations a server left working, to carry on; the ones being stopped end.
pub fn left_working(
    connection: *db.Db,
    arena: std.mem.Allocator,
    now_ms: i64,
) db.Error![]const []const u8 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(ai.listed_max > 0);

    var stop = try connection.prepare(
        "UPDATE ai_conversations SET state = 'stopped', answer = 'Stopped.', device_id = '', " ++
            "updated_at = ?1 WHERE state = 'stopping'",
    );
    defer stop.finalize();

    try stop.bind_int(1, now_ms);
    try stop.exec();

    var select = try connection.prepare(
        "SELECT id FROM ai_conversations WHERE state = 'running' LIMIT 1024",
    );
    defer select.finalize();

    const Row = struct {
        id: []const u8,
    };
    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        const row = try select.read(Row, arena);

        found.append(arena, row.id) catch return error.OutOfMemory;
    }

    return found.items;
}

pub fn interrupt_all(connection: *db.Db, answer: []const u8, now_ms: i64) db.Error!u32 {
    std.debug.assert(answer.len > 0);
    std.debug.assert(now_ms >= 0);

    var statement = try connection.prepare(
        "UPDATE ai_conversations SET state = 'failed', answer = ?1, device_id = '', " ++
            "updated_at = ?2 WHERE state IN ('running', 'stopping')",
    );
    defer statement.finalize();

    try statement.bind_text(1, answer);
    try statement.bind_int(2, now_ms);
    try statement.exec();

    return connection.changes();
}

pub const Ending = struct {
    state: ai.State,
    answer: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cached_tokens: u64 = 0,
};

pub fn finish(connection: *db.Db, id: []const u8, ending: Ending, now_ms: i64) db.Error!void {
    std.debug.assert(ending.state.over());
    std.debug.assert(ending.answer.len <= ai.answer_len_max);

    var statement = try connection.prepare(
        "UPDATE ai_conversations SET state = ?1, answer = ?2, " ++
            "input_tokens = input_tokens + ?3, output_tokens = output_tokens + ?4, " ++
            "updated_at = ?5, cached_tokens = cached_tokens + ?7 WHERE id = ?6",
    );
    defer statement.finalize();

    try statement.bind_text(1, @tagName(ending.state));
    try statement.bind_text(2, ending.answer);
    try statement.bind_int(3, @intCast(@min(ending.input_tokens, std.math.maxInt(i63))));
    try statement.bind_int(4, @intCast(@min(ending.output_tokens, std.math.maxInt(i63))));
    try statement.bind_int(5, now_ms);
    try statement.bind_text(6, id);
    try statement.bind_int(7, @intCast(@min(ending.cached_tokens, std.math.maxInt(i63))));
    try statement.exec();
}

/// Gives a conversation another id: what the documented examples name.
pub fn rename(connection: *db.Db, from: []const u8, to: []const u8) db.Error!void {
    std.debug.assert(from.len == id_len);
    std.debug.assert(to.len == id_len);

    var statement = try connection.prepare("UPDATE ai_conversations SET id = ?1 WHERE id = ?2");
    defer statement.finalize();

    try statement.bind_text(1, to);
    try statement.bind_text(2, from);
    try statement.exec();
}

/// The words the model is writing, so far: what a page watching shows before they are a
/// step. Empty once they are.
pub fn set_draft(connection: *db.Db, id: []const u8, draft: []const u8) db.Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(draft.len <= ai.detail_len_max);

    var statement = try connection.prepare("UPDATE ai_conversations SET draft = ?1 WHERE id = ?2");
    defer statement.finalize();

    try statement.bind_text(1, draft);
    try statement.bind_text(2, id);
    try statement.exec();
}

pub fn draft_of(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) db.Error![]const u8 {
    std.debug.assert(id.len > 0);

    var select = try connection.prepare("SELECT draft FROM ai_conversations WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return "";
    }

    const Row = struct {
        draft: []const u8,
    };

    return (try select.read(Row, arena)).draft;
}

/// The conversation whose turn runs as `device_id`, if one does.
pub fn by_device(
    connection: *db.Db,
    arena: std.mem.Allocator,
    device_id: []const u8,
) db.Error!?[]const u8 {
    std.debug.assert(device_id.len > 0);

    var select = try connection.prepare("SELECT id FROM ai_conversations WHERE device_id = ?1");
    defer select.finalize();

    try select.bind_text(1, device_id);

    if (!try select.step()) {
        return null;
    }

    const Row = struct {
        id: []const u8,
    };

    return (try select.read(Row, arena)).id;
}
