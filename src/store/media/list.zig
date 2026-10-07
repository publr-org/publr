//! The library as the explorer sees it: the files a filter matches, newest first, and how
//! many each folder, tag and month would hold with the rest of the filter kept. A folder
//! holds what is filed under it and below it (`record_terms` lists every ancestor); tags
//! narrow together, a file must carry each one.

const std = @import("std");
const db = @import("../../lib/db.zig");
const Row = @import("../media.zig").Row;

pub const tags_max: u32 = 16;
pub const search_len_max: u32 = 200;
const binds_max: u32 = tags_max + 8;

pub const Folder = union(enum) {
    any,
    /// Files in no folder.
    unsorted,
    /// Files taken in from the media folder that no one has looked at yet, in any folder.
    unreviewed,
    /// A folder's term id: the files in it and in the folders below it.
    term: []const u8,
};

pub const Filter = struct {
    folder: Folder = .any,
    /// Term ids; a file must carry every one.
    tags: []const []const u8 = &.{},
    /// Part of the file name or the title.
    search: []const u8 = "",
    /// Uploaded within the year, or the month of it, by the server's calendar (UTC).
    year: ?u32 = null,
    month: ?u32 = null,
    /// What kind of file: an image, a video, a sound, a PDF, or anything else.
    kind: ?Kind = null,
    /// How large: under 1 MiB, 1 to 10 MiB, over 10 MiB.
    size: ?Size = null,
    /// Only the files signed-in users alone may open, or only the others.
    private: ?bool = null,
};

pub const Kind = enum { image, video, audio, pdf, other };
pub const Size = enum { small, medium, large };

const mebibyte: i64 = 1 << 20;

/// Which part of the filter a count leaves out: a folder's count keeps everything but the
/// folder, a month's everything but the date.
const Leave = enum { nothing, folder, date };

const Bind = union(enum) { text: []const u8, int: i64 };

const Where = struct {
    sql: std.ArrayList(u8) = .empty,
    binds: [binds_max]Bind = undefined,
    binds_len: u32 = 0,

    fn add(where: *Where, arena: std.mem.Allocator, clause: []const u8, bind: ?Bind) !void {
        std.debug.assert(clause.len > 0);
        std.debug.assert(where.binds_len < binds_max);

        try where.sql.appendSlice(arena, " AND ");

        if (bind) |value| {
            where.binds[where.binds_len] = value;
            where.binds_len += 1;

            const placeholder = try std.fmt.allocPrint(arena, "?{d}", .{where.binds_len});
            const numbered = try std.mem.replaceOwned(u8, arena, clause, "?N", placeholder);

            try where.sql.appendSlice(arena, numbered);
        } else {
            try where.sql.appendSlice(arena, clause);
        }
    }

    fn bind_all(where: *const Where, statement: *db.Statement) db.Error!void {
        std.debug.assert(where.binds_len <= binds_max);

        for (where.binds[0..where.binds_len], 1..) |bind, index| {
            switch (bind) {
                .text => |text| try statement.bind_text(@intCast(index), text),
                .int => |number| try statement.bind_int(@intCast(index), number),
            }
        }
    }
};

const from = " FROM media m JOIN records r ON r.id = m.record WHERE r.status <> 'deleted'";
const in_term = " SELECT 1 FROM record_terms t WHERE t.record = m.record AND t.slot = 'live'";
const title_value = "SELECT v.value FROM record_values v WHERE v.record = m.record " ++
    "AND v.slot = 'live' AND v.field = 'title' AND v.ordinal = 0";

fn where_of(arena: std.mem.Allocator, filter: Filter, leave: Leave) !Where {
    std.debug.assert(filter.tags.len <= tags_max);
    std.debug.assert(filter.search.len <= search_len_max);

    var where: Where = .{};

    if (leave != .folder) {
        switch (filter.folder) {
            .any => {},
            .unsorted => try where.add(arena, "NOT EXISTS (" ++ in_term ++
                " AND t.field = 'media_folders')", null),
            .unreviewed => try where.add(arena, "m.unreviewed = 1", null),
            .term => |term| try where.add(arena, "EXISTS (" ++ in_term ++
                " AND t.field = 'media_folders' AND t.term = ?N)", .{ .text = term }),
        }
    }

    for (filter.tags) |tag| {
        try where.add(arena, "EXISTS (" ++ in_term ++ " AND t.field = 'media_tags' AND " ++
            "t.term = ?N)", .{ .text = tag });
    }

    if (filter.kind) |kind| {
        try where.add(arena, switch (kind) {
            .image => "m.mime_type LIKE 'image/%'",
            .video => "m.mime_type LIKE 'video/%'",
            .audio => "m.mime_type LIKE 'audio/%'",
            .pdf => "m.mime_type = 'application/pdf'",
            .other => "m.mime_type NOT LIKE 'image/%' AND m.mime_type NOT LIKE 'video/%' " ++
                "AND m.mime_type NOT LIKE 'audio/%' AND m.mime_type <> 'application/pdf'",
        }, null);
    }

    if (filter.size) |size| {
        switch (size) {
            .small => try where.add(arena, "m.size < ?N", .{ .int = mebibyte }),
            .medium => {
                try where.add(arena, "m.size >= ?N", .{ .int = mebibyte });
                try where.add(arena, "m.size <= ?N", .{ .int = 10 * mebibyte });
            },
            .large => try where.add(arena, "m.size > ?N", .{ .int = 10 * mebibyte }),
        }
    }

    if (filter.private) |private| {
        try where.add(arena, if (private) "m.private = 1" else "m.private = 0", null);
    }

    if (filter.search.len > 0) {
        const pattern = try like_pattern(arena, filter.search);

        try where.add(arena, "(m.filename LIKE ?N ESCAPE '\\' OR EXISTS (" ++ title_value ++
            " AND v.value LIKE ?N ESCAPE '\\'))", .{ .text = pattern });
    }

    if (leave != .date) {
        if (range_of(filter)) |range| {
            try where.add(arena, "m.created_at >= ?N", .{ .int = range.start_ms });
            try where.add(arena, "m.created_at < ?N", .{ .int = range.end_ms });
        }
    }

    return where;
}

fn like_pattern(arena: std.mem.Allocator, search: []const u8) ![]const u8 {
    std.debug.assert(search.len > 0);
    std.debug.assert(search.len <= search_len_max);

    var pattern: std.ArrayList(u8) = .empty;

    try pattern.append(arena, '%');

    for (search) |char| {
        if (char == '%' or char == '_' or char == '\\') {
            try pattern.append(arena, '\\');
        }

        try pattern.append(arena, char);
    }

    try pattern.append(arena, '%');

    return pattern.items;
}

const Range = struct { start_ms: i64, end_ms: i64 };

fn range_of(filter: Filter) ?Range {
    std.debug.assert(filter.month == null or (filter.month.? >= 1 and filter.month.? <= 12));

    const year = filter.year orelse return null;

    if (year < 1970 or year > 9999) {
        return null;
    }

    const month = filter.month;
    const start = days_before(year, month orelse 1);
    const end = if (month) |known|
        (if (known == 12) days_before(year + 1, 1) else days_before(year, known + 1))
    else
        days_before(year + 1, 1);

    std.debug.assert(end > start);

    return .{ .start_ms = start * std.time.ms_per_day, .end_ms = end * std.time.ms_per_day };
}

/// Days from 1970-01-01 to the first of `month` in `year`.
fn days_before(year: u32, month: u32) i64 {
    std.debug.assert(year >= 1970);
    std.debug.assert(month >= 1 and month <= 12);

    var days: i64 = 0;
    var current: u32 = 1970;

    while (current < year) : (current += 1) {
        days += std.time.epoch.getDaysInYear(@intCast(current));
    }

    var index: u32 = 1;

    while (index < month) : (index += 1) {
        days += std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(index));
    }

    return days;
}

pub const Item = struct {
    record: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    size: i64,
    width: ?i64,
    height: ?i64,
    storage_key: []const u8,
    private: bool,
    created_at: i64,
    unreviewed: bool,
    missing: bool,
    title: []const u8,
};

pub const page_max: u32 = 200;

/// The files the filter matches, newest first.
pub fn items(
    connection: *db.Db,
    arena: std.mem.Allocator,
    filter: Filter,
    limit: u32,
    offset: u32,
) ![]const Item {
    std.debug.assert(limit > 0 and limit <= page_max);
    std.debug.assert(filter.tags.len <= tags_max);

    const where = try where_of(arena, filter, .nothing);
    const sql = try std.fmt.allocPrint(
        arena,
        "SELECT m.record, m.filename, m.mime_type, m.size, m.width, m.height, " ++
            "m.storage_key, m.private, m.created_at, m.unreviewed, m.missing, " ++
            "COALESCE((" ++ title_value ++
            "), m.filename){s}{s} ORDER BY m.created_at DESC, m.record DESC LIMIT {d} OFFSET {d}",
        .{ from, where.sql.items, limit, offset },
    );
    var select = try connection.prepare_dynamic(sql);
    defer select.finalize();

    try where.bind_all(&select);

    var found: std.ArrayList(Item) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(Item, arena));
    }

    std.debug.assert(found.items.len <= limit);

    return found.items;
}

pub fn count(connection: *db.Db, arena: std.mem.Allocator, filter: Filter) !u32 {
    std.debug.assert(filter.tags.len <= tags_max);
    std.debug.assert(filter.search.len <= search_len_max);

    const where = try where_of(arena, filter, .nothing);

    return count_where(connection, arena, where);
}

fn count_where(connection: *db.Db, arena: std.mem.Allocator, where: Where) !u32 {
    std.debug.assert(where.binds_len <= binds_max);

    const sql = try std.fmt.allocPrint(arena, "SELECT COUNT(*){s}{s}", .{ from, where.sql.items });
    var select = try connection.prepare_dynamic(sql);
    defer select.finalize();

    try where.bind_all(&select);

    const stepped = try select.step();

    std.debug.assert(stepped);

    return @intCast(select.read_int());
}

/// The filter's files in no folder: what Unsorted would hold.
pub fn unsorted_count(connection: *db.Db, arena: std.mem.Allocator, filter: Filter) !u32 {
    std.debug.assert(filter.tags.len <= tags_max);

    var unsorted = filter;

    unsorted.folder = .unsorted;

    return count(connection, arena, unsorted);
}

/// The filter's files no one has looked at yet: what Unreviewed would hold.
pub fn unreviewed_count(connection: *db.Db, arena: std.mem.Allocator, filter: Filter) !u32 {
    std.debug.assert(filter.tags.len <= tags_max);

    var unreviewed = filter;

    unreviewed.folder = .unreviewed;

    return count(connection, arena, unreviewed);
}

/// The filter's files without its folder: what All files would hold.
pub fn all_count(connection: *db.Db, arena: std.mem.Allocator, filter: Filter) !u32 {
    std.debug.assert(filter.tags.len <= tags_max);

    var everywhere = filter;

    everywhere.folder = .any;

    return count(connection, arena, everywhere);
}

pub const TermCount = struct { term: []const u8, count: i64 };

pub const Classification = enum { folders, tags };

/// How many of the filter's files each folder or tag would hold: a folder's count leaves
/// the chosen folder out, a tag's keeps the chosen tags (a file must carry them and it).
pub fn term_counts(
    connection: *db.Db,
    arena: std.mem.Allocator,
    filter: Filter,
    classification: Classification,
) ![]const TermCount {
    std.debug.assert(filter.tags.len <= tags_max);
    std.debug.assert(filter.search.len <= search_len_max);

    const leave: Leave = if (classification == .folders) .folder else .nothing;
    const field = if (classification == .folders) "media_folders" else "media_tags";
    const where = try where_of(arena, filter, leave);
    const sql = try std.fmt.allocPrint(
        arena,
        "SELECT c.term, COUNT(*) FROM media m JOIN records r ON r.id = m.record " ++
            "JOIN record_terms c ON c.record = m.record AND c.slot = 'live' " ++
            "AND c.field = '{s}' WHERE r.status <> 'deleted'{s} GROUP BY c.term",
        .{ field, where.sql.items },
    );
    var select = try connection.prepare_dynamic(sql);
    defer select.finalize();

    try where.bind_all(&select);

    var found: std.ArrayList(TermCount) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(TermCount, arena));
    }

    return found.items;
}

pub const Period = struct { year: i64, month: i64, count: i64 };

/// The months the filter's files were uploaded in, newest first, ignoring its date.
pub fn periods(connection: *db.Db, arena: std.mem.Allocator, filter: Filter) ![]const Period {
    std.debug.assert(filter.tags.len <= tags_max);
    std.debug.assert(filter.search.len <= search_len_max);

    const where = try where_of(arena, filter, .date);
    const moment = "m.created_at / 1000, 'unixepoch'";
    const sql = try std.fmt.allocPrint(
        arena,
        "SELECT CAST(strftime('%Y', " ++ moment ++ ") AS INTEGER) AS year, " ++
            "CAST(strftime('%m', " ++ moment ++ ") AS INTEGER) AS month, COUNT(*){s}{s} " ++
            "GROUP BY year, month ORDER BY year DESC, month DESC LIMIT 240",
        .{ from, where.sql.items },
    );
    var select = try connection.prepare_dynamic(sql);
    defer select.finalize();

    try where.bind_all(&select);

    var found: std.ArrayList(Period) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(Period, arena));
    }

    return found.items;
}

/// For the tests of the library's tables: a `media` type and one record of it.
pub fn seed_record(connection: *db.Db, record: []const u8) !void {
    std.debug.assert(record.len > 0);
    std.debug.assert(record.len < 64);

    try connection.exec(
        "INSERT OR IGNORE INTO content_types (id, handle, name, icon, public, system, " ++
            "editor, editor_config, definition, created_at, updated_at) VALUES ('tm', " ++
            "'media', 'Media', '', 0, 1, 'form', '{}', '{}', 0, 0)",
    );

    var insert = try connection.prepare(
        "INSERT INTO records (id, type_id, status, changed, version, created_at, " ++
            "updated_at) VALUES (?1, 'tm', 'published', 0, 1, 0, 0)",
    );
    defer insert.finalize();

    try insert.bind_text(1, record);
    try insert.exec();
}

test "range_of: a year, a month, December into the next year" {
    const year = range_of(.{ .year = 2026 }).?;
    const october = range_of(.{ .year = 2026, .month = 10 }).?;
    const december = range_of(.{ .year = 2026, .month = 12 }).?;

    try std.testing.expectEqual(@as(i64, 1_767_225_600_000), year.start_ms);
    try std.testing.expectEqual(@as(i64, 1_798_761_600_000), year.end_ms);
    try std.testing.expectEqual(@as(i64, 1_790_812_800_000), october.start_ms);
    try std.testing.expectEqual(year.end_ms, december.end_ms);
    try std.testing.expect(range_of(.{ .month = 3 }) == null);
}

test "like_pattern: wildcards in the search are taken literally" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("%cat%", try like_pattern(arena_state.allocator(), "cat"));
    try std.testing.expectEqualStrings(
        "%50\\%\\_off%",
        try like_pattern(arena_state.allocator(), "50%_off"),
    );
}
