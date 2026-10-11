const std = @import("std");
const db = @import("../lib/db.zig");
const ai = @import("../model/ai.zig");

/// One row of `ai_steps`. Field order is the column order of `select_step`.
pub const Step = struct {
    position: i64,
    kind: []const u8,
    summary: []const u8,
    detail: []const u8,
    failed: i64,
    href: []const u8,
    at: i64,
};

const select_step = "SELECT position, kind, summary, detail, failed, href, at FROM ai_steps";

pub const New = struct {
    kind: ai.StepKind,
    summary: []const u8,
    detail: []const u8,
    failed: bool = false,
    href: []const u8 = "",
};

/// Adds a step after the conversation's last. Its position, or null once the
/// conversation holds `ai.steps_max`.
pub fn append(
    connection: *db.Db,
    conversation_id: []const u8,
    new: New,
    now_ms: i64,
) db.Error!?u32 {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(new.summary.len <= ai.summary_len_max and new.detail.len <= ai.detail_len_max);

    const count = try count_of(connection, conversation_id);

    if (count >= ai.steps_max) {
        return null;
    }

    var statement = try connection.prepare(
        "INSERT INTO ai_steps (conversation_id, position, kind, summary, detail, failed, href, " ++
            "at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    );
    defer statement.finalize();

    try statement.bind_text(1, conversation_id);
    try statement.bind_int(2, count + 1);
    try statement.bind_text(3, @tagName(new.kind));
    try statement.bind_text(4, new.summary);
    try statement.bind_text(5, new.detail);
    try statement.bind_int(6, @intFromBool(new.failed));
    try statement.bind_text(7, new.href);
    try statement.bind_int(8, now_ms);
    try statement.exec();

    return count + 1;
}

/// A conversation's steps, in order.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conversation_id: []const u8,
) db.Error![]Step {
    return page(connection, arena, conversation_id, .{
        .limit = ai.steps_max,
        .oldest_first = true,
    });
}

/// Which of a conversation's steps a page reads: the ones between `after` and `before`
/// (0 for no bound), at most `limit`, the newest of them unless `oldest_first`.
pub const Window = struct {
    after: u32 = 0,
    before: u32 = 0,
    limit: u32,
    oldest_first: bool = false,
};

/// The steps in `window`, in order.
pub fn page(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conversation_id: []const u8,
    window: Window,
) db.Error![]Step {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(window.limit > 0 and window.limit <= ai.steps_max);

    const between = select_step ++
        " WHERE conversation_id = ?1 AND position > ?2 AND position < ?3 ORDER BY position";
    var select = if (window.oldest_first)
        try connection.prepare(between ++ " LIMIT ?4")
    else
        try connection.prepare(between ++ " DESC LIMIT ?4");
    defer select.finalize();

    try select.bind_text(1, conversation_id);
    try select.bind_int(2, window.after);
    try select.bind_int(3, if (window.before == 0) std.math.maxInt(i64) else window.before);
    try select.bind_int(4, window.limit);

    var rows: std.ArrayList(Step) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < window.limit);
        rows.append(arena, try select.read(Step, arena)) catch return error.OutOfMemory;
    }

    if (!window.oldest_first) {
        std.mem.reverse(Step, rows.items);
    }

    return rows.items;
}

/// The newest step whose address starts with `prefix` (any address for an empty one);
/// null when none has.
pub fn latest_at(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conversation_id: []const u8,
    prefix: []const u8,
) db.Error!?Step {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(prefix.len <= ai.href_len_max);

    var select = try connection.prepare(
        select_step ++ " WHERE conversation_id = ?1 AND href <> '' AND " ++
            "substr(href, 1, length(?2)) = ?2 ORDER BY position DESC LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, conversation_id);
    try select.bind_text(2, prefix);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Step, arena);
}

fn count_of(connection: *db.Db, conversation_id: []const u8) db.Error!u32 {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(ai.steps_max > 0);

    var select = try connection.prepare(
        "SELECT COUNT(*) AS count FROM ai_steps WHERE conversation_id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, conversation_id);

    if (!try select.step()) {
        return 0;
    }

    const Count = struct {
        count: i64,
    };
    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const counted = try select.read(Count, fixed.allocator());

    return @intCast(@max(0, counted.count));
}
