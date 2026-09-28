//! A documents table (`records`, `terms`): one row per document with identity, status and
//! version. Its values live in the domain's values table; the list query is
//! `documents/list.zig`.

const std = @import("std");
const ids = @import("../lib/id.zig");
const db = @import("../lib/db.zig");
const tables_module = @import("tables.zig");
const list_module = @import("documents/list.zig");

pub const id_len = ids.len;
pub const list_max = list_module.list_max;
pub const statuses_filter_max = list_module.statuses_filter_max;
pub const type_ids_max = list_module.type_ids_max;
pub const document_bytes_max: u32 = 8 << 20;
pub const search_len_max: u32 = 256;
pub const Error = db.Error || error{ NotFound, Conflict };
pub const Order = list_module.Order;
pub const Filter = list_module.Filter;
pub const Author = list_module.Author;
pub const Query = list_module.Query;
pub const Record = list_module.Record;
pub const new_id = ids.random;

pub const Insert = struct {
    type_id: []const u8,
    created_by: ?[]const u8,
    status: []const u8,
};

pub fn Store(comptime tables: tables_module.Tables) type {
    return struct {
        const table = tables.documents;
        const List = list_module.List(tables);

        pub const list = List.list;
        pub const select_record = List.select_record;

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
            const id = arena.dupe(u8, new_id(io, &id_buffer)) catch return error.OutOfMemory;

            var statement = try connection.prepare(
                "INSERT INTO " ++ table ++ " (id, type_id, created_by, updated_by, status, " ++
                    "changed, version, created_at, updated_at) " ++
                    "VALUES (?1, ?2, ?3, ?3, ?4, 0, 1, ?5, ?5)",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try statement.bind_text(2, row.type_id);
            try statement.bind_optional_text(3, row.created_by);
            try statement.bind_text(4, row.status);
            try statement.bind_int(5, now_ms);
            try statement.exec();

            return id;
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
                    "updated_at = ?3, updated_by = ?4, changed = ?5 WHERE id = ?1",
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
