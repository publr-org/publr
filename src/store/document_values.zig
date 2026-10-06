//! A values table (`record_values`, `term_values`) and its search index: one row per field
//! value per slot. What a document becomes in rows, and back, is `model/document.zig`;
//! this file only stores, promotes, looks up and deletes them.

const std = @import("std");
const db = @import("../lib/db.zig");
const field = @import("../model/field.zig");
const kinds = @import("../model/kinds.zig");
const document = @import("../model/document.zig");
const tables_module = @import("tables.zig");

const Def = field.Def;
const Value = std.json.Value;
const Row = document.Row;
const Stored = document.Stored;
const rows_max = document.rows_max;

pub const Error = db.Error || error{Invalid};

/// The slot of the document everyone reads; other slots (`pending`, a plugin's own) are
/// copies edited aside and never indexed.
pub const live = "live";
pub const pending = "pending";
pub const slot_len_max: u32 = 64;

pub const Referrer = struct { record_id: []const u8, field: []const u8 };
pub const Slots = enum { live, editing };
/// A value row with the record it belongs to, from a read of many records.
pub const Owned = struct { record: []const u8, row: Row };

pub fn Store(comptime tables: tables_module.Tables) type {
    return struct {
        const table = tables.values;
        const search = tables.search;
        const field_scope = "type_id = ?1 AND (field = ?2 OR " ++
            "substr(field, 1, length(?2) + 1) = ?2 || '.')";

        pub fn write(
            known: []const kinds.Kind,
            connection: *db.Db,
            record_id: []const u8,
            slot: []const u8,
            type_id: []const u8,
            fields: []const Def,
            value: Value,
        ) Error!void {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(slot.len > 0 and slot.len <= slot_len_max);

            var buffer: [document.flat_max]document.Flat = undefined;
            const flat = try document.flatten(known, fields, value, &buffer);

            try clear(connection, record_id, slot);

            var insert = try connection.prepare(
                "INSERT INTO " ++ table ++ " (record, slot, type_id, field, ordinal, kind, " ++
                    "value) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            );
            defer insert.finalize();

            var fts = try connection.prepare(
                "INSERT INTO " ++ search ++ " (text, record, slot, type_id, field) " ++
                    "VALUES (?1, ?2, ?3, ?4, ?5)",
            );
            defer fts.finalize();

            for (flat) |row| {
                insert.reset();
                try insert.bind_text(1, record_id);
                try insert.bind_text(2, slot);
                try insert.bind_text(3, type_id);
                try insert.bind_text(4, row.field);
                try insert.bind_int(5, row.ordinal);
                try insert.bind_text(6, @tagName(row.column));

                switch (row.value) {
                    .text => |text| try insert.bind_text(7, text),
                    .integer => |number| try insert.bind_int(7, number),
                    .real => |number| try insert.bind_real(7, number),
                }

                try insert.exec();

                if (row.searchable) {
                    fts.reset();
                    try fts.bind_text(1, row.value.text);
                    try fts.bind_text(2, record_id);
                    try fts.bind_text(3, slot);
                    try fts.bind_text(4, type_id);
                    try fts.bind_text(5, row.field);
                    try fts.exec();
                }
            }
        }

        pub fn clear(connection: *db.Db, record_id: []const u8, slot: ?[]const u8) db.Error!void {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            const statements = [_][:0]const u8{
                "DELETE FROM " ++ table ++ " WHERE record = ?1 AND (?2 IS NULL OR slot = ?2)",
                "DELETE FROM " ++ search ++ " WHERE record = ?1 AND (?2 IS NULL OR slot = ?2)",
            };

            inline for (statements) |sql| {
                var statement = try connection.prepare(sql);
                defer statement.finalize();

                try statement.bind_text(1, record_id);
                try statement.bind_optional_text(2, slot);
                try statement.exec();
            }
        }

        /// Make one slot the other: the target's rows go, the source's rows take its name.
        /// Nothing happens when the source slot is empty; answers whether it did.
        pub fn promote(
            connection: *db.Db,
            record_id: []const u8,
            from: []const u8,
            to: []const u8,
        ) db.Error!bool {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(!std.mem.eql(u8, from, to));

            if (!try has_slot(connection, record_id, from)) {
                return false;
            }

            try clear(connection, record_id, to);

            const statements = [_][:0]const u8{
                "UPDATE " ++ table ++ " SET slot = ?3 WHERE record = ?1 AND slot = ?2",
                "UPDATE " ++ search ++ " SET slot = ?3 WHERE record = ?1 AND slot = ?2",
            };

            inline for (statements) |sql| {
                var statement = try connection.prepare(sql);
                defer statement.finalize();

                try statement.bind_text(1, record_id);
                try statement.bind_text(2, from);
                try statement.bind_text(3, to);
                try statement.exec();
            }

            return true;
        }

        /// Every slot a document has values in.
        pub fn slots_of(
            connection: *db.Db,
            arena: std.mem.Allocator,
            record_id: []const u8,
        ) db.Error![][]const u8 {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(slot_len_max > 0);

            var select = try connection.prepare(
                "SELECT DISTINCT slot FROM " ++ table ++ " WHERE record = ?1 ORDER BY slot",
            );
            defer select.finalize();

            try select.bind_text(1, record_id);

            const Slot = struct { slot: []const u8 };
            var slots: std.ArrayList([]const u8) = .empty;

            while (try select.step()) {
                std.debug.assert(slots.items.len < 1000);

                const found = try select.read(Slot, arena);
                slots.append(arena, found.slot) catch return error.OutOfMemory;
            }

            return slots.items;
        }

        pub fn has_slot(connection: *db.Db, record_id: []const u8, slot: []const u8) db.Error!bool {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(slot.len > 0);

            var select = try connection.prepare(
                "SELECT 1 FROM " ++ table ++ " WHERE record = ?1 AND slot = ?2 LIMIT 1",
            );
            defer select.finalize();

            try select.bind_text(1, record_id);
            try select.bind_text(2, slot);

            return try select.step();
        }

        pub fn read(
            connection: *db.Db,
            arena: std.mem.Allocator,
            record_id: []const u8,
            slot: []const u8,
        ) db.Error![]Row {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(slot.len > 0);

            var select = try connection.prepare(
                "SELECT field, ordinal, value FROM " ++ table ++ " WHERE record = ?1 " ++
                    "AND slot = ?2 ORDER BY field, ordinal",
            );
            defer select.finalize();

            try select.bind_text(1, record_id);
            try select.bind_text(2, slot);

            const Cell = struct { field: []const u8, ordinal: i64, value: db.Any };
            var rows: std.ArrayList(Row) = .empty;

            while (try select.step()) {
                std.debug.assert(rows.items.len < rows_max);

                const cell = try select.read(Cell, arena);
                const stored: Stored = switch (cell.value) {
                    .integer => |number| .{ .integer = number },
                    .real => |number| .{ .real = number },
                    .text => |text| .{ .text = text },
                    .blob, .null => unreachable,
                };

                rows.append(arena, .{
                    .field = cell.field,
                    .ordinal = cell.ordinal,
                    .value = stored,
                }) catch return error.OutOfMemory;
            }

            return rows.items;
        }

        /// The rows of many records' copies in `slot`, one query for a page of them:
        /// grouped by record, each record's in `field, ordinal` order.
        pub fn read_many(
            connection: *db.Db,
            arena: std.mem.Allocator,
            record_ids: []const []const u8,
            slot: []const u8,
        ) Error![]const Owned {
            std.debug.assert(slot.len > 0);
            std.debug.assert(record_ids.len <= 1024);

            if (record_ids.len == 0) {
                return &.{};
            }

            const ids = std.json.Stringify.valueAlloc(arena, record_ids, .{}) catch {
                return error.OutOfMemory;
            };
            var select = try connection.prepare(
                "SELECT record, field, ordinal, value FROM " ++ table ++ " WHERE record IN " ++
                    "(SELECT value FROM json_each(?1)) AND slot = ?2 " ++
                    "ORDER BY record, field, ordinal",
            );
            defer select.finalize();

            try select.bind_text(1, ids);
            try select.bind_text(2, slot);

            const Cell = struct {
                record: []const u8,
                field: []const u8,
                ordinal: i64,
                value: db.Any,
            };
            var rows: std.ArrayList(Owned) = .empty;

            while (try select.step()) {
                std.debug.assert(rows.items.len < rows_max * record_ids.len);

                const cell = try select.read(Cell, arena);
                const stored: Stored = switch (cell.value) {
                    .integer => |number| .{ .integer = number },
                    .real => |number| .{ .real = number },
                    .text => |text| .{ .text = text },
                    .blob, .null => unreachable,
                };

                rows.append(arena, .{ .record = cell.record, .row = .{
                    .field = cell.field,
                    .ordinal = cell.ordinal,
                    .value = stored,
                } }) catch return error.OutOfMemory;
            }

            return rows.items;
        }

        /// The records pointing at the target: through their live values, or (`editing`)
        /// their live or pending ones, what an editor sees.
        pub fn referrers(
            connection: *db.Db,
            arena: std.mem.Allocator,
            target_id: []const u8,
            slots: Slots,
        ) db.Error![]Referrer {
            std.debug.assert(target_id.len > 0);
            std.debug.assert(rows_max > 0);

            const select_live = "SELECT DISTINCT record, field FROM " ++ table ++
                " WHERE slot = 'live' AND kind = 'ref' AND value = ?1 ORDER BY record, field";
            const select_editing = "SELECT DISTINCT record, field FROM " ++ table ++
                " WHERE slot IN ('live', 'pending') AND kind = 'ref' AND value = ?1 " ++
                "ORDER BY record, field";
            var select = switch (slots) {
                .live => try connection.prepare(select_live),
                .editing => try connection.prepare(select_editing),
            };
            defer select.finalize();

            try select.bind_text(1, target_id);

            var found: std.ArrayList(Referrer) = .empty;

            while (try select.step()) {
                std.debug.assert(found.items.len < rows_max);
                const row = try select.read(Referrer, arena);
                found.append(arena, row) catch return error.OutOfMemory;
            }

            return found.items;
        }

        /// Another document of a type (not `except`) holding a text value in a field, if any
        /// (unique lookups).
        pub fn find_by_text(
            connection: *db.Db,
            arena: std.mem.Allocator,
            type_id: []const u8,
            path: []const u8,
            text: []const u8,
            except: []const u8,
        ) db.Error!?[]const u8 {
            std.debug.assert(type_id.len > 0);
            std.debug.assert(path.len > 0);

            var select = try connection.prepare(
                "SELECT record FROM " ++ table ++ " WHERE type_id = ?1 AND field = ?2 " ++
                    "AND value = ?3 AND slot = 'live' AND kind <> 'long' AND record <> ?4 LIMIT 1",
            );
            defer select.finalize();

            try select.bind_text(1, type_id);
            try select.bind_text(2, path);
            try select.bind_text(3, text);
            try select.bind_text(4, except);

            if (!try select.step()) {
                return null;
            }

            const Found = struct { record: []const u8 };
            return (try select.read(Found, arena)).record;
        }

        /// Another document of a type (not `except`) holding a whole-number value in a field.
        pub fn find_by_integer(
            connection: *db.Db,
            arena: std.mem.Allocator,
            type_id: []const u8,
            path: []const u8,
            number: i64,
            except: []const u8,
        ) db.Error!?[]const u8 {
            std.debug.assert(type_id.len > 0);
            std.debug.assert(path.len > 0);

            var select = try connection.prepare(
                "SELECT record FROM " ++ table ++ " WHERE type_id = ?1 AND field = ?2 " ++
                    "AND value = ?3 AND slot = 'live' AND kind = 'int' AND record <> ?4 LIMIT 1",
            );
            defer select.finalize();

            try select.bind_text(1, type_id);
            try select.bind_text(2, path);
            try select.bind_int(3, number);
            try select.bind_text(4, except);

            if (!try select.step()) {
                return null;
            }

            const Found = struct { record: []const u8 };
            return (try select.read(Found, arena)).record;
        }

        /// One whole-number value of a document's slot (ordinal 0), or null when absent.
        pub fn read_integer(
            connection: *db.Db,
            arena: std.mem.Allocator,
            record_id: []const u8,
            slot: []const u8,
            path: []const u8,
        ) db.Error!?i64 {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(path.len > 0);

            var select = try connection.prepare(
                "SELECT value FROM " ++ table ++ " WHERE record = ?1 AND slot = ?2 " ++
                    "AND field = ?3 AND ordinal = 0 AND kind = 'int'",
            );
            defer select.finalize();

            try select.bind_text(1, record_id);
            try select.bind_text(2, slot);
            try select.bind_text(3, path);

            if (!try select.step()) {
                return null;
            }

            const Found = struct { value: i64 };
            return (try select.read(Found, arena)).value;
        }

        /// Every pointer at a document, in every slot of every document, removed: how many.
        pub fn delete_references(connection: *db.Db, target_id: []const u8) db.Error!u32 {
            std.debug.assert(target_id.len > 0);
            std.debug.assert(rows_max > 0);

            var statement = try connection.prepare(
                "DELETE FROM " ++ table ++ " WHERE kind = 'ref' AND value = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, target_id);
            try statement.exec();

            return connection.changes();
        }

        /// One text value of a document's slot (ordinal 0), or null when absent.
        pub fn read_text(
            connection: *db.Db,
            arena: std.mem.Allocator,
            record_id: []const u8,
            slot: []const u8,
            path: []const u8,
        ) db.Error!?[]const u8 {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(path.len > 0);

            var select = try connection.prepare(
                "SELECT value FROM " ++ table ++ " WHERE record = ?1 AND slot = ?2 " ++
                    "AND field = ?3 AND ordinal = 0 AND kind <> 'int' AND kind <> 'real'",
            );
            defer select.finalize();

            try select.bind_text(1, record_id);
            try select.bind_text(2, slot);
            try select.bind_text(3, path);

            if (!try select.step()) {
                return null;
            }

            const Found = struct { value: []const u8 };
            return (try select.read(Found, arena)).value;
        }

        pub fn delete_field(
            connection: *db.Db,
            type_id: []const u8,
            path: []const u8,
        ) db.Error!u32 {
            std.debug.assert(type_id.len > 0);
            std.debug.assert(path.len > 0);

            var removed: u32 = 0;
            const statements = [_][:0]const u8{
                "DELETE FROM " ++ table ++ " WHERE " ++ field_scope,
                "DELETE FROM " ++ search ++ " WHERE " ++ field_scope,
            };

            inline for (statements) |sql| {
                var statement = try connection.prepare(sql);
                defer statement.finalize();

                try statement.bind_text(1, type_id);
                try statement.bind_text(2, path);
                try statement.exec();
                removed += connection.changes();
            }

            return removed;
        }

        pub fn count_field(connection: *db.Db, type_id: []const u8, path: []const u8) db.Error!u32 {
            std.debug.assert(type_id.len > 0);
            std.debug.assert(path.len > 0);

            var select = try connection.prepare(
                "SELECT count(*) FROM " ++ table ++ " WHERE " ++ field_scope,
            );
            defer select.finalize();

            try select.bind_text(1, type_id);
            try select.bind_text(2, path);

            std.debug.assert(try select.step());

            return @intCast(select.read_int());
        }
    };
}
