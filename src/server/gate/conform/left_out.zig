const std = @import("std");
const db = @import("../../../lib/db.zig");
const rebuild = @import("rebuild.zig");
const sql = @import("sql.zig");

const Table = db.shape.Table;
const Work = rebuild.Work;
const quote = sql.quote;
const literal = sql.literal;
const exec = sql.exec;
const column_of = sql.column_of;
const read_text = sql.read_text;
const building = rebuild.building;

/// SQLite takes at most 127 arguments to a function: a row's values are read this many
/// columns to a query.
const columns_per_read: u32 = 50;
/// Each round leaves out the rows that refer to a row the round before left out.
const reference_rounds_max: u32 = db.shape.tables_max;

/// The values of each column this release does not have, kept rows only: a value that is
/// neither NULL nor the column's default.
pub fn leave_out_columns(work: *Work, expected: Table, live: Table) !void {
    std.debug.assert(work.connection.transaction_depth >= 1);
    std.debug.assert(std.mem.eql(u8, expected.name, live.name));

    const arena = work.arena;

    for (live.columns) |column| {
        if (column_of(expected, column.name) != null) {
            continue;
        }

        const value = try value_of(arena, column.name);
        const set = if (column.default) |default|
            try std.fmt.allocPrint(arena, " AND {s} IS NOT ({s})", .{ value, default })
        else
            "";
        var select = try work.connection.prepare_dynamic(try std.fmt.allocPrint(
            arena,
            "SELECT json_object('table', {s}, 'column', {s}, 'key', {s}, 'value', {s}) " ++
                "FROM {s} WHERE {s} IS NOT NULL{s} AND rowid IN (SELECT rowid FROM \"{s}\")",
            .{
                try literal(arena, live.name), try literal(arena, column.name),
                try key_of(arena, live),       value,
                try quote(arena, live.name),   try quote(arena, column.name),
                set,                           building,
            },
        ));
        defer select.finalize();

        while (try select.step()) {
            try work.values.append(arena, try read_text(&select, arena));
            try work.count(live.name, column.name);
        }
    }
}

/// Leaves out every row that refers to a missing one, as the rows a rebuild left out
/// leave their own behind, until none does.
pub fn references(work: *Work) !void {
    std.debug.assert(work.connection.transaction_depth >= 1);
    std.debug.assert(reference_rounds_max > 0);

    for (0..reference_rounds_max) |_| {
        const Row = struct {
            table: []const u8,
            rowid: ?i64,
        };
        var broken: std.ArrayList(Row) = .empty;
        var check = try work.connection.prepare(
            "SELECT \"table\", rowid FROM pragma_foreign_key_check",
        );
        defer check.finalize();

        while (try check.step()) {
            try broken.append(work.arena, try check.read(Row, work.arena));
        }

        if (broken.items.len == 0) {
            return;
        }

        const shape = try db.shape.read(work.connection, work.arena);

        for (broken.items) |row| {
            const found = shape.table(row.table) orelse return error.Sqlite;
            const rowid = row.rowid orelse return error.Sqlite;

            if (try row_exists(work, found.name, rowid)) {
                try leave_out_row(work, found, rowid);
                try exec(work.connection, try std.fmt.allocPrint(
                    work.arena,
                    "DELETE FROM {s} WHERE rowid = {d}",
                    .{ try quote(work.arena, found.name), rowid },
                ));
            }
        }
    }

    return error.TooBig;
}

fn row_exists(work: *Work, table_name: []const u8, rowid: i64) !bool {
    std.debug.assert(table_name.len > 0);
    std.debug.assert(work.connection.transaction_depth >= 1);

    var select = try work.connection.prepare_dynamic(try std.fmt.allocPrint(
        work.arena,
        "SELECT count(*) FROM {s} WHERE rowid = ?1",
        .{try quote(work.arena, table_name)},
    ));
    defer select.finalize();

    try select.bind_int(1, rowid);
    _ = try select.step();

    return select.read_int() == 1;
}

/// The row as JSON: its table, its key (the primary key, or the rowid), every value.
pub fn leave_out_row(work: *Work, live: Table, rowid: i64) !void {
    std.debug.assert(live.columns.len > 0);
    std.debug.assert(work.connection.transaction_depth >= 1);

    const arena = work.arena;
    var values: std.ArrayList(u8) = .empty;
    var start: u32 = 0;

    while (start < live.columns.len) : (start += columns_per_read) {
        const end: u32 = @intCast(@min(live.columns.len, start + columns_per_read));
        var pairs: std.ArrayList(u8) = .empty;

        for (live.columns[start..end], start..) |column, index| {
            try pairs.appendSlice(arena, if (index == start) "" else ", ");
            try pairs.print(arena, "{s}, {s}", .{
                try literal(arena, column.name),
                try value_of(arena, column.name),
            });
        }

        const part = try read_one(work, try std.fmt.allocPrint(
            arena,
            "SELECT json_object({s}) FROM {s} WHERE rowid = {d}",
            .{ pairs.items, try quote(arena, live.name), rowid },
        ));

        std.debug.assert(part.len >= 2);
        try values.appendSlice(arena, if (start == 0) "" else ",");
        try values.appendSlice(arena, part[1 .. part.len - 1]);
    }

    const key = try read_one(work, try std.fmt.allocPrint(
        arena,
        "SELECT {s} FROM {s} WHERE rowid = {d}",
        .{ try key_of(arena, live), try quote(arena, live.name), rowid },
    ));

    try work.rows.append(arena, try std.fmt.allocPrint(
        arena,
        "{{\"table\":{f},\"key\":{s},\"values\":{{{s}}}}}",
        .{ std.json.fmt(live.name, .{}), key, values.items },
    ));
    try work.count(live.name, null);
}

fn read_one(work: *Work, text: []const u8) ![]const u8 {
    std.debug.assert(text.len > 0);
    std.debug.assert(work.connection.transaction_depth >= 1);

    var select = try work.connection.prepare_dynamic(text);
    defer select.finalize();

    if (!try select.step()) {
        return error.Sqlite;
    }

    return read_text(&select, work.arena);
}

/// A JSON object of the row's primary key, or of its rowid when it has none.
fn key_of(arena: std.mem.Allocator, live: Table) ![]const u8 {
    std.debug.assert(live.name.len > 0);
    std.debug.assert(live.columns.len > 0);

    var pairs: std.ArrayList(u8) = .empty;

    for (live.columns) |column| {
        if (column.primary > 0) {
            try pairs.appendSlice(arena, if (pairs.items.len == 0) "" else ", ");
            try pairs.print(arena, "{s}, {s}", .{
                try literal(arena, column.name),
                try value_of(arena, column.name),
            });
        }
    }

    if (pairs.items.len == 0) {
        return "json_object('rowid', rowid)";
    }

    return std.fmt.allocPrint(arena, "json_object({s})", .{pairs.items});
}

/// A column's value as JSON can hold it: bytes become SQL's `x'…'` text.
fn value_of(arena: std.mem.Allocator, column: []const u8) ![]const u8 {
    std.debug.assert(column.len > 0);

    const name = try quote(arena, column);

    return std.fmt.allocPrint(
        arena,
        "(CASE typeof({s}) WHEN 'blob' THEN 'x''' || hex({s}) || '''' ELSE {s} END)",
        .{ name, name, name },
    );
}
