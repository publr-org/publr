//! A documents table (`records`, `terms`): one row per document with identity, status and
//! version. Its values live in the domain's values table; the list query is
//! `documents/list.zig`.

const std = @import("std");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");
const db = @import("../lib/db.zig");
const tables_module = @import("tables.zig");
const list_module = @import("documents/list.zig");
const requests_module = @import("documents/requests.zig");

pub const id_len = ids.len;
pub const list_max = list_module.list_max;
pub const statuses_filter_max = list_module.statuses_filter_max;
pub const type_ids_max = list_module.type_ids_max;
pub const document_bytes_max: u32 = @import("../model/limits.zig").entry_bytes_max;
pub const search_len_max: u32 = 256;
pub const Error = db.Error || error{ NotFound, Conflict };
pub const Order = list_module.Order;
pub const Filter = list_module.Filter;
pub const Operator = list_module.Operator;
pub const Sort = list_module.Sort;
pub const Author = list_module.Author;
pub const Query = list_module.Query;
pub const Record = list_module.Record;
pub const Match = list_module.Match;

/// A document's status and its type's handle: what a change to many needs to know.
pub const Brief = struct {
    id: []const u8,
    status: []const u8,
    type: []const u8,
};

pub const App = list_module.App;

pub const Insert = struct {
    type_id: []const u8,
    created_by: ?[]const u8,
    status: []const u8,
    /// The app it belongs to; null for the project's own.
    app: ?[]const u8 = null,
};

/// Going into the trash keeps the status the document leaves (SQLite reads `status` as it
/// was); leaving it clears it.
const trashed_from_set = "trashed_from = CASE WHEN ?2 = 'trashed' THEN status " ++
    "WHEN status = 'trashed' THEN '' ELSE trashed_from END";
const trashed_many_set = "trashed_from = CASE WHEN ?3 = 'trashed' THEN status " ++
    "WHEN status = 'trashed' THEN '' ELSE trashed_from END";

pub fn Store(comptime tables: tables_module.Tables) type {
    return struct {
        const table = tables.documents;
        const List = list_module.List(tables);

        pub const list = List.list;
        pub const count = List.count;
        pub const gather = List.gather;
        pub const gathered = List.gathered;
        pub const release = List.release;
        pub const select_record = List.select_record;
        pub const ask = requests_module.Requests(tables).ask;
        pub const clear_request = requests_module.Requests(tables).clear;

        pub fn insert(
            connection: *db.Db,
            io: std.Io,
            arena: std.mem.Allocator,
            row: Insert,
            now_ms: i64,
        ) Error![]const u8 {
            std.debug.assert(row.type_id.len > 0);
            std.debug.assert(row.status.len > 0);

            var id_buffer: [id_len]u8 = undefined;
            const made = try next_id.next(table, connection, io, now_ms, &id_buffer);
            const id = arena.dupe(u8, made) catch return error.OutOfMemory;

            var statement = try connection.prepare(
                "INSERT INTO " ++ table ++ " (id, type_id, created_by, updated_by, status, " ++
                    "changed, version, created_at, updated_at, app) " ++
                    "VALUES (?1, ?2, ?3, ?3, ?4, 0, 1, ?5, ?5, ?6)",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try statement.bind_text(2, row.type_id);
            try statement.bind_optional_text(3, row.created_by);
            try statement.bind_text(4, row.status);
            try statement.bind_int(5, now_ms);
            try statement.bind_optional_text(6, row.app);
            try statement.exec();

            return id;
        }

        /// Each of many documents' status and type, by a JSON array of ids; the ones gone
        /// are left out.
        pub fn briefs(
            connection: *db.Db,
            arena: std.mem.Allocator,
            ids_json: []const u8,
        ) Error![]const Brief {
            std.debug.assert(ids_json.len >= 2 and ids_json[0] == '[');
            std.debug.assert(table.len > 0);

            var select = try connection.prepare(
                "SELECT r.id, r.status, t.handle FROM " ++ table ++ " r JOIN " ++
                    tables.definitions ++ " t ON t.id = r.type_id " ++
                    "WHERE r.id IN (SELECT value FROM json_each(?1))",
            );
            defer select.finalize();

            try select.bind_text(1, ids_json);

            var found: std.ArrayList(Brief) = .empty;

            while (try select.step()) {
                found.append(arena, try select.read(Brief, arena)) catch return error.OutOfMemory;
            }

            return found.items;
        }

        pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?Record {
            std.debug.assert(id.len > 0);
            std.debug.assert(id.len <= 128);

            var select = try connection.prepare(select_record ++ " WHERE r.id = ?1");
            defer select.finalize();

            try select.bind_text(1, id);

            if (!try select.step()) {
                return null;
            }

            return try select.read(Record, arena);
        }

        /// Bump the version after a document write and record whether edits are parked.
        pub fn save(
            connection: *db.Db,
            id: []const u8,
            updated_by: ?[]const u8,
            expected_version: ?i64,
            now_ms: i64,
            changed: bool,
        ) Error!i64 {
            std.debug.assert(id.len > 0);
            std.debug.assert(now_ms >= 0);

            const current = try current_version(connection, id);

            if (expected_version) |expected| {
                if (expected != current) {
                    return error.Conflict;
                }
            }

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET version = version + 1, updated_at = ?2, " ++
                    "updated_by = ?3, changed = ?4 WHERE id = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try statement.bind_int(2, now_ms);
            try statement.bind_optional_text(3, updated_by);
            try statement.bind_int(4, @intFromBool(changed));
            try statement.exec();

            std.debug.assert(connection.changes() == 1);

            return current + 1;
        }

        pub fn set_status(
            connection: *db.Db,
            id: []const u8,
            status: []const u8,
            expected_version: ?i64,
            now_ms: i64,
            updated_by: ?[]const u8,
            changed: bool,
        ) Error!i64 {
            std.debug.assert(id.len > 0);
            std.debug.assert(status.len > 0);

            const current = try current_version(connection, id);

            if (expected_version) |expected| {
                if (expected != current) {
                    return error.Conflict;
                }
            }

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET status = ?2, version = version + 1, " ++
                    "updated_at = ?3, updated_by = ?4, changed = ?5, " ++
                    trashed_from_set ++ ", " ++ requests_module.cleared_set ++ " WHERE id = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try statement.bind_text(2, status);
            try statement.bind_int(3, now_ms);
            try statement.bind_optional_text(4, updated_by);
            try statement.bind_int(5, @intFromBool(changed));
            try statement.exec();

            return current + 1;
        }

        /// Many documents moved to `status` in one statement, each a version on; `ids_json`
        /// and `applied_json` are JSON arrays of ids, the second the ones whose pending
        /// changes went live with the move, so they are no longer changed.
        pub fn set_status_many(
            connection: *db.Db,
            ids_json: []const u8,
            applied_json: []const u8,
            status: []const u8,
            now_ms: i64,
            updated_by: ?[]const u8,
        ) Error!u32 {
            std.debug.assert(ids_json.len >= 2 and ids_json[0] == '[');
            std.debug.assert(status.len > 0);

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET status = ?3, version = version + 1, " ++
                    "updated_at = ?4, updated_by = ?5, changed = changed AND id NOT IN " ++
                    "(SELECT value FROM json_each(?2)), " ++ trashed_many_set ++ ", " ++
                    requests_module.cleared_set ++
                    " WHERE id IN (SELECT value FROM json_each(?1))",
            );
            defer statement.finalize();

            try statement.bind_text(1, ids_json);
            try statement.bind_text(2, applied_json);
            try statement.bind_text(3, status);
            try statement.bind_int(4, now_ms);
            try statement.bind_optional_text(5, updated_by);
            try statement.exec();

            return @intCast(connection.changes());
        }

        /// The status a trashed document had before the trash, for `restore`; empty when
        /// it was never trashed or is not now.
        pub fn trashed_from(
            connection: *db.Db,
            arena: std.mem.Allocator,
            id: []const u8,
        ) Error![]const u8 {
            std.debug.assert(id.len > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var statement = try connection.prepare(
                "SELECT trashed_from FROM " ++ table ++ " WHERE id = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);

            if (!try statement.step()) {
                return error.NotFound;
            }

            const row = try statement.read(struct {
                trashed_from: []const u8,
            }, arena);

            return row.trashed_from;
        }

        /// Which app a document belongs to, null for the project's own. Not a version of
        /// the document: an editor's open copy stays current.
        pub fn set_app(connection: *db.Db, id: []const u8, app: ?[]const u8) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(app == null or app.?.len > 0);

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET app = ?2 WHERE id = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try statement.bind_optional_text(2, app);
            try statement.exec();

            if (connection.changes() == 0) {
                return error.NotFound;
            }
        }

        /// Every document of one app handed to another (an app renamed), or to the project
        /// (`to` null): how many moved.
        pub fn move_app(connection: *db.Db, from: []const u8, to: ?[]const u8) Error!u32 {
            std.debug.assert(from.len > 0);
            std.debug.assert(to == null or to.?.len > 0);

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET app = ?2 WHERE app = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, from);
            try statement.bind_optional_text(2, to);
            try statement.exec();

            return @intCast(connection.changes());
        }

        fn current_version(connection: *db.Db, id: []const u8) Error!i64 {
            std.debug.assert(id.len > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var select = try connection.prepare(
                "SELECT version FROM " ++ table ++ " WHERE id = ?1",
            );
            defer select.finalize();

            try select.bind_text(1, id);

            if (!try select.step()) {
                return error.NotFound;
            }

            return select.read_int();
        }

        pub fn delete(connection: *db.Db, id: []const u8) Error!bool {
            std.debug.assert(id.len > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            const statements = [_][:0]const u8{
                "DELETE FROM " ++ tables.search ++ " WHERE record = ?1",
                "DELETE FROM " ++ table ++ " WHERE id = ?1",
            };
            var removed = false;

            inline for (statements) |sql| {
                var statement = try connection.prepare(sql);
                defer statement.finalize();

                try statement.bind_text(1, id);
                try statement.exec();
                removed = connection.changes() > 0;
            }

            return removed;
        }

        /// Give a document another id (tests and examples want known ids): every table
        /// that names it.
        pub fn rename(connection: *db.Db, from: []const u8, to: []const u8) Error!void {
            std.debug.assert(from.len == id_len);
            std.debug.assert(to.len == id_len);

            try connection.exec("PRAGMA foreign_keys = OFF");
            defer connection.exec("PRAGMA foreign_keys = ON") catch unreachable;

            const statements = [_][:0]const u8{
                "UPDATE " ++ table ++ " SET id = ?1 WHERE id = ?2",
                "UPDATE snapshots SET record = ?1 WHERE record = ?2",
                "UPDATE " ++ tables.values ++ " SET record = ?1 WHERE record = ?2",
                "UPDATE " ++ tables.search ++ " SET record = ?1 WHERE record = ?2",
            };

            inline for (statements) |sql| {
                var statement = try connection.prepare(sql);
                defer statement.finalize();

                try statement.bind_text(1, to);
                try statement.bind_text(2, from);
                try statement.exec();
            }
        }

        pub fn count_in_status(
            connection: *db.Db,
            type_id: []const u8,
            status: []const u8,
        ) Error!u32 {
            std.debug.assert(type_id.len > 0);
            std.debug.assert(status.len > 0);

            var select = try connection.prepare(
                "SELECT count(*) FROM " ++ table ++ " WHERE type_id = ?1 AND status = ?2",
            );
            defer select.finalize();

            try select.bind_text(1, type_id);
            try select.bind_text(2, status);

            std.debug.assert(try select.step());

            return @intCast(select.read_int());
        }

        pub fn count_by_type(connection: *db.Db, type_id: []const u8) Error!u32 {
            std.debug.assert(type_id.len > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var select = try connection.prepare(
                "SELECT count(*) FROM " ++ table ++ " WHERE type_id = ?1",
            );
            defer select.finalize();

            try select.bind_text(1, type_id);

            std.debug.assert(try select.step());

            return @intCast(select.read_int());
        }
    };
}
