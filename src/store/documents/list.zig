//! The one query composed at runtime: which clauses a list has, and how many `?N` the
//! status filter takes, depend on the query. `build_list_sql` writes only literals and
//! placeholder numbers; every value still goes through `bind_query`.

const std = @import("std");
const db = @import("../../lib/db.zig");
const tables_module = @import("../tables.zig");

pub const list_max: u32 = 200;
pub const statuses_filter_max: u32 = 64;
pub const type_ids_max: u32 = 256;
pub const Error = db.Error || error{ NotFound, Conflict };

/// What a write over many documents needs of each: in column order of `select_gathered`.
pub const Match = struct {
    /// Its place among the gathered.
    position: i64,
    id: []const u8,
    type_id: []const u8,
    status: []const u8,
    changed: bool,
    created_by: ?[]const u8,
    title: ?[]const u8,
};

/// One row of the documents table, with what every reader wants next to it: the
/// definition's handle, and the live title and slug (from the definition's `title_field`
/// and its slug field, found in the definition by SQLite's JSON functions). Field order
/// is the column order of `select_record`: the struct is what `Statement.read` fills.
pub const Record = struct {
    id: []const u8,
    type_id: []const u8,
    type: []const u8,
    status: []const u8,
    changed: bool,
    version: i64,
    title: []const u8,
    slug: ?[]const u8,
    created_by: ?[]const u8,
    updated_by: ?[]const u8,
    created_at: i64,
    updated_at: i64,
    /// The app it belongs to (`app.zon`'s `.name`); null for the project's own.
    app: ?[]const u8 = null,
};

/// Only the documents whose ids a JSON array lists.
const list_ids = " AND r.id IN (SELECT value FROM json_each(?{d}))";

/// The copy a list reads of the record `r`: the live one, or its latest.
const live_slot = "'live'";
const pending_slot = "'pending'";
const latest_slot = "(CASE WHEN r.changed THEN 'pending' ELSE 'live' END)";

/// A condition on the copy a list reads, its `{s}` the slot. The latest copy depends on
/// the row (`r.changed`), and a subquery naming it would run again for every row (a
/// search over every record, each time); split by `r.changed`, each half runs once.
fn write_slotted(
    writer: *std.Io.Writer,
    query: Query,
    comptime clause: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    std.debug.assert(query.type_ids.len > 0);
    std.debug.assert(std.mem.startsWith(u8, clause, " AND "));

    if (!query.latest) {
        writer.print(clause, args ++ .{live_slot}) catch return error.OutOfMemory;
        return;
    }

    writer.writeAll(" AND (r.changed = 0") catch return error.OutOfMemory;
    writer.print(clause, args ++ .{live_slot}) catch return error.OutOfMemory;
    writer.writeAll(" OR r.changed = 1") catch return error.OutOfMemory;
    writer.print(clause, args ++ .{pending_slot}) catch return error.OutOfMemory;
    writer.writeAll(")") catch return error.OutOfMemory;
}

/// Which app's documents a list keeps: one app's, or the project's own (no app).
pub const App = union(enum) {
    none,
    name: []const u8,
};

pub const Order = enum { updated_desc, created_desc, created_asc, title_asc };

pub const Filter = struct {
    field: []const u8,
    text: ?[]const u8 = null,
    int: ?i64 = null,
    real: ?f64 = null,
    ref: ?[]const u8 = null,
    /// `ref` is a term: match through the membership index, ancestors included.
    membership: bool = false,
    /// Any of these values, a JSON array of text: references or text, compared as stored.
    values_json: ?[]const u8 = null,
};

/// Who created or last saved a document: this user, or (`exclude`) anyone but this user.
pub const Author = struct {
    id: []const u8,
    exclude: bool = false,
};

pub const Query = struct {
    /// The definitions the list spans, never empty: one for a type's own list, every type
    /// the caller may read for a list across the content.
    type_ids: []const []const u8,
    statuses: ?[]const []const u8 = null,
    /// Only these documents: their ids as a JSON array of strings.
    ids_json: ?[]const u8 = null,
    changed: ?bool = null,
    search: ?[]const u8 = null,
    /// A value of one field; only meaningful when the list spans one type.
    filter: ?Filter = null,
    created_by: ?Author = null,
    updated_by: ?Author = null,
    /// Bounds on the timestamps, milliseconds: `after` inclusive, `before` exclusive.
    created_after_ms: ?i64 = null,
    created_before_ms: ?i64 = null,
    updated_after_ms: ?i64 = null,
    updated_before_ms: ?i64 = null,
    app: ?App = null,
    /// Match, name and order by each record's latest copy (its pending changes when it has
    /// some, else its live document) instead of the live one: what the admin and the API
    /// read. A page drawn for a visitor reads live copies only.
    latest: bool = false,
    order: Order = .updated_desc,
    limit: u32 = 50,
    offset: u32 = 0,
};

/// One bound on a timestamp column, in the order they are written and bound.
const Bound = struct {
    column: []const u8,
    operator: []const u8,
    value: ?i64,
};

fn bounds_of(query: Query) [4]Bound {
    std.debug.assert(query.type_ids.len > 0);
    std.debug.assert(query.limit <= list_max);

    return .{
        .{
            .column = "created_at",
            .operator = ">=",
            .value = query.created_after_ms,
        },
        .{
            .column = "created_at",
            .operator = "<",
            .value = query.created_before_ms,
        },
        .{
            .column = "updated_at",
            .operator = ">=",
            .value = query.updated_after_ms,
        },
        .{
            .column = "updated_at",
            .operator = "<",
            .value = query.updated_before_ms,
        },
    };
}

pub fn List(comptime tables: tables_module.Tables) type {
    return struct {
        const table = tables.documents;
        const values = tables.values;

        /// The columns of a Record, in order, from the documents table `r` joined with
        /// its definition `t` and its live title `title` and slug `slug` values.
        const record_columns = "r.id, r.type_id, t.handle, r.status, r.changed, r.version, " ++
            "title.value, slug.value, r.created_by, r.updated_by, r.created_at, r.updated_at, " ++
            "r.app";
        fn joins(comptime slot: []const u8) []const u8 {
            comptime std.debug.assert(slot.len > 0);

            return "JOIN " ++ tables.definitions ++ " t ON t.id = r.type_id " ++
                "LEFT JOIN " ++ values ++ " title ON title.record = r.id AND title.slot = " ++
                slot ++ " AND title.ordinal = 0 " ++
                "AND title.field = json_extract(t.definition, '$.title_field') " ++
                "LEFT JOIN " ++ values ++ " slug ON slug.record = r.id AND slug.slot = " ++
                slot ++ " AND slug.ordinal = 0 AND slug.field = (SELECT f.value ->> 'name' " ++
                "FROM field_groups g, json_each(g.definition, '$.fields') f " ++
                "WHERE g.scope = '" ++ tables.definitions ++ "' AND g.owner = t.id " ++
                "AND f.value ->> 'kind' = 'slug' " ++
                "LIMIT 1)";
        }
        const record_joins = joins(live_slot);
        const latest_joins = joins(latest_slot);
        pub const select_record = "SELECT " ++ record_columns ++ " FROM " ++ table ++ " r " ++
            record_joins;
        const select_latest = "SELECT " ++ record_columns ++ " FROM " ++ table ++ " r " ++
            latest_joins;

        /// The joins bring one row per document, so a list ordered by a row column picks
        /// its page from the table alone and joins the page; a list ordered by title needs
        /// the join first.
        const list_by_record = "SELECT " ++ record_columns ++ " FROM (SELECT * FROM " ++
            table ++ " r WHERE ";
        const list_by_title = select_record ++ " WHERE ";
        const list_latest_by_title = select_latest ++ " WHERE ";
        // Over one type, bound first (`?1`), the lookup index finds the records holding the
        // value, instead of each record of the type being checked in turn.
        const list_filter_one_type = " AND r.id IN (SELECT v.record FROM " ++ values ++
            " v WHERE v.type_id = ?1 AND v.field = ?{d} AND v.value = ?{d} " ++
            "AND v.slot = {s} AND v.kind <> 'long')";
        const list_filter = " AND EXISTS (SELECT 1 FROM " ++ values ++ " v WHERE " ++
            "v.record = r.id AND v.type_id = r.type_id AND v.field = ?{d} AND v.value = ?{d} " ++
            "AND v.slot = {s} AND v.kind <> 'long')";
        const list_filter_any = " AND r.id IN (SELECT v.record FROM " ++ values ++
            " v WHERE v.type_id = ?1 AND v.field = ?{d} AND v.value IN " ++
            "(SELECT value FROM json_each(?{d})) AND v.slot = {s} AND v.kind <> 'long')";
        const list_search = " AND r.id IN (SELECT record FROM " ++ tables.search ++
            " WHERE " ++ tables.search ++ " MATCH ?{d} AND slot = {s})";
        const list_membership = " AND EXISTS (SELECT 1 FROM " ++ (tables.assignments orelse "") ++
            " m WHERE m.record = r.id AND m.field = ?{d} AND m.term = ?{d} AND m.slot = {s})";

        pub fn list(connection: *db.Db, arena: std.mem.Allocator, query: Query) Error![]Record {
            std.debug.assert(query.type_ids.len > 0 and query.type_ids.len <= type_ids_max);
            std.debug.assert(query.limit <= list_max);

            const text = try build_list_sql(arena, query);
            var select = try connection.prepare_dynamic(text);
            defer select.finalize();

            _ = try bind_query(&select, query);

            var records: std.ArrayList(Record) = .empty;

            while (try select.step()) {
                std.debug.assert(records.items.len < list_max);
                const row = try select.read(Record, arena);
                records.append(arena, row) catch return error.OutOfMemory;
            }

            return records.items;
        }

        /// Every document the conditions keep, gathered into a temporary table of this
        /// connection, in id order: a write over every one of them reads them a part at a
        /// time (`gathered`) without asking the conditions again. Answers how many.
        pub fn gather(connection: *db.Db, arena: std.mem.Allocator, query: Query) Error!u32 {
            std.debug.assert(query.type_ids.len > 0 and query.type_ids.len <= type_ids_max);
            std.debug.assert(connection.transaction_depth >= 1);

            try connection.exec("CREATE TEMP TABLE IF NOT EXISTS " ++ gathered_table ++
                " (id TEXT NOT NULL)");
            try connection.exec("DELETE FROM temp." ++ gathered_table);

            var sql: std.Io.Writer.Allocating = .init(arena);
            const head = "INSERT INTO temp." ++ gathered_table ++ " (id) SELECT r.id FROM " ++
                table ++ " r WHERE ";

            sql.writer.writeAll(head) catch return error.OutOfMemory;
            _ = try write_conditions(&sql.writer, query);
            sql.writer.writeAll(" ORDER BY r.id") catch return error.OutOfMemory;

            var insert = try connection.prepare_dynamic(sql.written());
            defer insert.finalize();

            _ = try bind_query(&insert, query);
            try insert.exec();

            return @intCast(connection.changes());
        }

        /// The gathered documents after `position`, up to `limit`, as they are now.
        pub fn gathered(
            connection: *db.Db,
            arena: std.mem.Allocator,
            position: i64,
            limit: u32,
        ) Error![]Match {
            std.debug.assert(position >= 0);
            std.debug.assert(limit > 0 and limit <= list_max);

            var select = try connection.prepare(select_gathered);
            defer select.finalize();

            try select.bind_int(1, position);
            try select.bind_int(2, limit);

            var rows: std.ArrayList(Match) = .empty;

            while (try select.step()) {
                std.debug.assert(rows.items.len < limit);
                rows.append(arena, try select.read(Match, arena)) catch return error.OutOfMemory;
            }

            return rows.items;
        }

        /// The gathered documents forgotten.
        pub fn release(connection: *db.Db) Error!void {
            std.debug.assert(connection.transaction_depth <= 8);
            std.debug.assert(gathered_table.len > 0);

            try connection.exec("DROP TABLE IF EXISTS temp." ++ gathered_table);
        }

        const gathered_table = "gathered_" ++ table;
        const select_gathered = "SELECT g.rowid, r.id, r.type_id, r.status, r.changed, " ++
            "r.created_by, title.value FROM temp." ++ gathered_table ++ " g JOIN " ++ table ++
            " r ON r.id = g.id JOIN " ++ tables.definitions ++ " t ON t.id = r.type_id " ++
            "LEFT JOIN " ++ values ++ " title ON title.record = r.id " ++
            "AND title.slot = 'live' AND title.ordinal = 0 " ++
            "AND title.field = json_extract(t.definition, '$.title_field') " ++
            "WHERE g.rowid > ?1 ORDER BY g.rowid LIMIT ?2";

        /// How many documents the query's conditions keep, its limit and offset aside.
        pub fn count(connection: *db.Db, arena: std.mem.Allocator, query: Query) Error!u32 {
            std.debug.assert(query.type_ids.len > 0 and query.type_ids.len <= type_ids_max);
            std.debug.assert(query.limit <= list_max);

            var sql: std.Io.Writer.Allocating = .init(arena);
            const head = "SELECT COUNT(*) AS count FROM " ++ table ++ " r WHERE ";

            sql.writer.writeAll(head) catch return error.OutOfMemory;
            _ = try write_conditions(&sql.writer, query);

            var select = try connection.prepare_dynamic(sql.written());
            defer select.finalize();

            _ = try bind_query(&select, query);

            if (!try select.step()) {
                return 0;
            }

            const counted = try select.read(struct {
                count: i64,
            }, arena);

            return @intCast(@max(0, counted.count));
        }

        fn build_list_sql(arena: std.mem.Allocator, query: Query) Error![]const u8 {
            std.debug.assert(query.type_ids.len > 0);
            std.debug.assert(query.limit <= list_max);

            var sql: std.Io.Writer.Allocating = .init(arena);
            const writer = &sql.writer;
            const limit = @min(query.limit, list_max);
            const paging = .{ limit, query.offset };

            if (query.order == .title_asc) {
                const head = if (query.latest) list_latest_by_title else list_by_title;

                writer.writeAll(head) catch return error.OutOfMemory;
                _ = try write_conditions(writer, query);
                writer.print(" ORDER BY title.value, r.id LIMIT {d} OFFSET {d}", paging) catch {
                    return error.OutOfMemory;
                };
            } else {
                const order: []const u8 = switch (query.order) {
                    .updated_desc => " ORDER BY r.updated_at DESC, r.id",
                    .created_desc => " ORDER BY r.created_at DESC, r.id",
                    .created_asc => " ORDER BY r.created_at, r.id",
                    .title_asc => unreachable,
                };

                writer.writeAll(list_by_record) catch return error.OutOfMemory;
                _ = try write_conditions(writer, query);
                writer.print("{s} LIMIT {d} OFFSET {d}) r {s}{s}", .{
                    order,
                    limit,
                    query.offset,
                    if (query.latest) latest_joins else record_joins,
                    order,
                }) catch return error.OutOfMemory;
            }

            return sql.toOwnedSlice() catch return error.OutOfMemory;
        }

        /// One field's value: through the membership index for a term, the lookup index
        /// over one type, each record checked over several; any of several values (over
        /// one type only).
        fn write_filter(
            writer: *std.Io.Writer,
            query: Query,
            filter: Filter,
            bind_index: u32,
        ) Error!void {
            std.debug.assert(bind_index > 1);
            std.debug.assert(filter.values_json == null or query.type_ids.len == 1);

            const args = .{ bind_index, bind_index + 1 };
            const has_assignments = comptime (tables.assignments != null);

            if (filter.values_json != null) {
                try write_slotted(writer, query, list_filter_any, args);
            } else if (has_assignments and filter.membership) {
                try write_slotted(writer, query, list_membership, args);
            } else if (query.type_ids.len == 1) {
                try write_slotted(writer, query, list_filter_one_type, args);
            } else {
                try write_slotted(writer, query, list_filter, args);
            }
        }

        /// Every condition on `r`, with placeholders numbered as `bind_query` binds them;
        /// answers the next placeholder's number.
        fn write_conditions(writer: *std.Io.Writer, query: Query) Error!u32 {
            std.debug.assert(query.type_ids.len > 0);
            std.debug.assert(query.type_ids.len <= type_ids_max);

            var bind_index: u32 = 1;

            writer.writeAll("r.type_id IN (") catch return error.OutOfMemory;
            try write_placeholders(writer, @intCast(query.type_ids.len), &bind_index);
            writer.writeAll(")") catch return error.OutOfMemory;

            if (query.statuses) |statuses| {
                std.debug.assert(statuses.len <= statuses_filter_max);
                writer.writeAll(" AND r.status IN (") catch return error.OutOfMemory;
                try write_placeholders(writer, @intCast(statuses.len), &bind_index);
                writer.writeAll(")") catch return error.OutOfMemory;
            }

            if (query.ids_json != null) {
                writer.print(list_ids, .{bind_index}) catch return error.OutOfMemory;
                bind_index += 1;
            }

            if (query.changed) |changed| {
                const clause: []const u8 = if (changed)
                    " AND r.changed = 1"
                else
                    " AND r.changed = 0";
                writer.writeAll(clause) catch return error.OutOfMemory;
            }

            if (query.filter) |filter| {
                try write_filter(writer, query, filter, bind_index);
                bind_index += 2;
            }

            if (query.search != null) {
                try write_slotted(writer, query, list_search, .{bind_index});
                bind_index += 1;
            }

            try write_author(writer, "created_by", query.created_by, &bind_index);
            try write_author(writer, "updated_by", query.updated_by, &bind_index);

            for (bounds_of(query)) |bound| {
                if (bound.value != null) {
                    const args = .{ bound.column, bound.operator, bind_index };
                    writer.print(" AND r.{s} {s} ?{d}", args) catch return error.OutOfMemory;
                    bind_index += 1;
                }
            }

            if (query.app) |app| {
                try write_app(writer, app, bind_index);

                if (app == .name) {
                    bind_index += 1;
                }
            }

            return bind_index;
        }
    };
}

/// Which app's records: one app's (its name bound at `bind_index`), or the project's own.
fn write_app(writer: *std.Io.Writer, app: App, bind_index: u32) Error!void {
    std.debug.assert(bind_index > 0);

    switch (app) {
        .none => writer.writeAll(" AND r.app IS NULL") catch return error.OutOfMemory,
        .name => writer.print(" AND r.app = ?{d}", .{bind_index}) catch {
            return error.OutOfMemory;
        },
    }
}

/// `?1, ?2, ?3`: one placeholder per item, from `bind_index` on, which moves past them.
fn write_placeholders(writer: *std.Io.Writer, count: u32, bind_index: *u32) Error!void {
    std.debug.assert(count > 0);
    std.debug.assert(bind_index.* > 0);

    for (0..count) |index| {
        const separator = if (index == 0) "" else ", ";
        writer.print("{s}?{d}", .{ separator, bind_index.* }) catch return error.OutOfMemory;
        bind_index.* += 1;
    }
}

/// A document by (or, excluded, not by) a user; a document nobody is recorded for never
/// matches an author and always counts as not by them.
fn write_author(
    writer: *std.Io.Writer,
    column: []const u8,
    author: ?Author,
    bind_index: *u32,
) Error!void {
    std.debug.assert(column.len > 0);
    std.debug.assert(bind_index.* > 0);

    const wanted = author orelse return;
    const index = bind_index.*;

    if (wanted.exclude) {
        const args = .{ column, column, index };
        writer.print(" AND (r.{s} IS NULL OR r.{s} <> ?{d})", args) catch return error.OutOfMemory;
    } else {
        writer.print(" AND r.{s} = ?{d}", .{ column, index }) catch return error.OutOfMemory;
    }

    bind_index.* += 1;
}

/// Binds every value the conditions take; answers the next placeholder's number.
fn bind_query(select: *db.Statement, query: Query) Error!u31 {
    std.debug.assert(query.type_ids.len > 0);
    std.debug.assert(query.limit <= list_max);

    var bind_index: u31 = 1;

    for (query.type_ids) |type_id| {
        try select.bind_text(bind_index, type_id);
        bind_index += 1;
    }

    if (query.statuses) |statuses| {
        for (statuses) |status| {
            try select.bind_text(bind_index, status);
            bind_index += 1;
        }
    }

    if (query.ids_json) |ids| {
        try select.bind_text(bind_index, ids);
        bind_index += 1;
    }

    if (query.filter) |filter| {
        try select.bind_text(bind_index, filter.field);

        if (filter.values_json) |given| {
            try select.bind_text(bind_index + 1, given);
        } else if (filter.text) |text| {
            try select.bind_text(bind_index + 1, text);
        } else if (filter.real) |real| {
            try select.bind_real(bind_index + 1, real);
        } else if (filter.ref) |ref| {
            try select.bind_text(bind_index + 1, ref);
        } else {
            try select.bind_int(bind_index + 1, filter.int orelse 0);
        }

        bind_index += 2;
    }

    if (query.search) |search| {
        try select.bind_text(bind_index, search);
        bind_index += 1;
    }

    for ([_]?Author{ query.created_by, query.updated_by }) |author| {
        if (author) |wanted| {
            try select.bind_text(bind_index, wanted.id);
            bind_index += 1;
        }
    }

    for (bounds_of(query)) |bound| {
        if (bound.value) |value| {
            try select.bind_int(bind_index, value);
            bind_index += 1;
        }
    }

    if (query.app) |app| {
        if (app == .name) {
            try select.bind_text(bind_index, app.name);
            bind_index += 1;
        }
    }

    return bind_index;
}
