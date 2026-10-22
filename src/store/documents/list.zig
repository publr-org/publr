//! The one query composed at runtime: which clauses a list has, and how many `?N` the
//! status filter takes, depend on the query. `build_list_sql` writes only literals and
//! placeholder numbers; every value still goes through `bind_query`.

const std = @import("std");
const db = @import("../../lib/db.zig");
const tables_module = @import("../tables.zig");
const list_filters = @import("list_filters.zig");

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
    /// A transition asked for by someone who may not publish; empty when none waits.
    requested: []const u8 = "",
    /// Who asked for it.
    requested_by: ?[]const u8 = null,
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

pub const Order = enum {
    updated_desc,
    updated_asc,
    created_desc,
    created_asc,
    title_asc,
    title_desc,
    status_asc,
    status_desc,
};

pub const Filter = list_filters.Filter;
pub const Operator = list_filters.Operator;
pub const filters_max = list_filters.filters_max;

/// An order by one of the record's own fields, by its indexed value; records without one
/// come last, ties by id.
pub const Sort = struct {
    field: []const u8,
    descending: bool = false,
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
    /// Of these types only the documents in one of `live_statuses`: a caller reading
    /// drafts of some types the list spans and only live records of the rest.
    live_type_ids: []const []const u8 = &.{},
    live_statuses: []const []const u8 = &.{},
    /// Only these documents: their ids as a JSON array of strings.
    ids_json: ?[]const u8 = null,
    changed: ?bool = null,
    /// Only documents with a transition waiting (true), or without one (false).
    requested: ?bool = null,
    search: ?[]const u8 = null,
    /// Conditions on the records' own fields, all of them kept.
    filters: []const Filter = &.{},
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
    /// Ordered by a field instead of `order`.
    sort: ?Sort = null,
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
            "r.app, r.requested, r.requested_by";
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
        const list_search = " AND r.id IN (SELECT record FROM " ++ tables.search ++
            " WHERE " ++ tables.search ++ " MATCH ?{d} AND slot = {s})";
        const FieldFilters = list_filters.Writer(values, tables.assignments);

        pub fn list(connection: *db.Db, arena: std.mem.Allocator, query: Query) Error![]Record {
            std.debug.assert(query.type_ids.len > 0 and query.type_ids.len <= type_ids_max);
            std.debug.assert(query.limit <= list_max);

            const text = try build_list_sql(arena, query);
            var select = try connection.prepare_dynamic(text);
            defer select.finalize();

            const next = try bind_query(&select, query);

            if (query.sort) |sort| {
                try select.bind_text(next, sort.field);
            }

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

            if (query.sort) |sort| {
                try write_by_field(arena, writer, query, sort);
            } else if (query.order == .title_asc or query.order == .title_desc) {
                const head = if (query.latest) list_latest_by_title else list_by_title;
                const direction = if (query.order == .title_desc) " DESC" else "";

                writer.writeAll(head) catch return error.OutOfMemory;
                _ = try write_conditions(writer, query);
                writer.print(" ORDER BY title.value{s}, r.id LIMIT {d} OFFSET {d}", .{
                    direction,
                    limit,
                    query.offset,
                }) catch return error.OutOfMemory;
            } else {
                const order: []const u8 = switch (query.order) {
                    .updated_desc => " ORDER BY r.updated_at DESC, r.id",
                    .updated_asc => " ORDER BY r.updated_at, r.id",
                    .created_desc => " ORDER BY r.created_at DESC, r.id",
                    .created_asc => " ORDER BY r.created_at, r.id",
                    .status_asc => " ORDER BY r.status, r.id",
                    .status_desc => " ORDER BY r.status DESC, r.id",
                    .title_asc, .title_desc => unreachable,
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

        /// Ordered by a field's value, joined as `o` after the conditions' placeholders.
        fn write_by_field(
            arena: std.mem.Allocator,
            writer: *std.Io.Writer,
            query: Query,
            sort: Sort,
        ) Error!void {
            std.debug.assert(sort.field.len > 0);
            std.debug.assert(query.limit <= list_max);

            var conditions: std.Io.Writer.Allocating = .init(arena);
            const field = try write_conditions(&conditions.writer, query);
            const head = if (query.latest) select_latest else select_record;
            const slot = if (query.latest) latest_slot else live_slot;
            const direction = if (sort.descending) " DESC" else "";

            writer.print("{s} LEFT JOIN {s} o ON o.record = r.id AND o.ordinal = 0 " ++
                "AND o.field = ?{d} AND o.slot = {s} WHERE {s} ORDER BY o.value IS NULL, " ++
                "o.value{s}, r.id LIMIT {d} OFFSET {d}", .{
                head,
                values,
                field,
                slot,
                conditions.written(),
                direction,
                @min(query.limit, list_max),
                query.offset,
            }) catch return error.OutOfMemory;
        }

        /// One field's filter on the copy the list reads.
        fn write_filter(
            writer: *std.Io.Writer,
            query: Query,
            filter: Filter,
            bind_index: u32,
        ) Error!void {
            std.debug.assert(bind_index > 1);
            std.debug.assert(list_filters.valid(filter));

            const one_type = query.type_ids.len == 1;

            if (!query.latest) {
                return FieldFilters.write(writer, filter, live_slot, one_type, bind_index);
            }

            writer.writeAll(" AND (r.changed = 0") catch return error.OutOfMemory;
            try FieldFilters.write(writer, filter, live_slot, one_type, bind_index);
            writer.writeAll(" OR r.changed = 1") catch return error.OutOfMemory;
            try FieldFilters.write(writer, filter, pending_slot, one_type, bind_index);
            writer.writeAll(")") catch return error.OutOfMemory;
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

            try write_live_types(writer, query, &bind_index);

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

            if (query.requested) |requested| {
                const clause: []const u8 = if (requested)
                    " AND r.requested <> ''"
                else
                    " AND r.requested = ''";
                writer.writeAll(clause) catch return error.OutOfMemory;
            }

            std.debug.assert(query.filters.len <= filters_max);

            for (query.filters) |filter| {
                try write_filter(writer, query, filter, bind_index);
                bind_index += list_filters.binds_of(filter);
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

/// The types read live only: their documents in a live status, every other type's in any.
fn write_live_types(writer: *std.Io.Writer, query: Query, bind_index: *u32) Error!void {
    std.debug.assert(query.live_type_ids.len <= type_ids_max);
    std.debug.assert(query.live_statuses.len <= statuses_filter_max);

    if (query.live_type_ids.len == 0) {
        return;
    }

    writer.writeAll(" AND (r.type_id NOT IN (") catch return error.OutOfMemory;
    try write_placeholders(writer, @intCast(query.live_type_ids.len), bind_index);
    writer.writeAll(")") catch return error.OutOfMemory;

    if (query.live_statuses.len > 0) {
        writer.writeAll(" OR r.status IN (") catch return error.OutOfMemory;
        try write_placeholders(writer, @intCast(query.live_statuses.len), bind_index);
        writer.writeAll(")") catch return error.OutOfMemory;
    }

    writer.writeAll(")") catch return error.OutOfMemory;
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

    if (query.live_type_ids.len > 0) {
        for ([_][]const []const u8{ query.live_type_ids, query.live_statuses }) |list| {
            for (list) |text| {
                try select.bind_text(bind_index, text);
                bind_index += 1;
            }
        }
    }

    if (query.ids_json) |ids| {
        try select.bind_text(bind_index, ids);
        bind_index += 1;
    }

    for (query.filters) |filter| {
        bind_index = try list_filters.bind(select, filter, bind_index);
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
