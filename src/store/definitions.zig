//! A definitions table (`content_types`, `taxonomies`): the schema rows. The definition
//! itself (fields, validation, JSON) is `model/content_type.zig`.

const std = @import("std");
const db = @import("../lib/db.zig");
const content_type = @import("../model/content_type.zig");
const field = @import("../model/field.zig");
const groups = @import("field_groups.zig");
const tables_module = @import("tables.zig");

pub const Def = content_type.Def;
pub const id_len = content_type.id_len;
pub const list_max: u32 = 500;
pub const Error = db.Error || error{Invalid};

pub const Row = struct {
    id: []const u8,
    def: Def,
    created_at: i64,
    updated_at: i64,
};

/// What the lists show: read straight from the definition's JSON, so no row is decoded
/// into a `Def` on the way.
pub const Brief = struct {
    id: []const u8,
    handle: []const u8,
    name: []const u8,
    kind: content_type.Kind,
    public: bool,
    system: bool,
    owner: []const u8,
    editor: []const u8,
    fields_len: u32,
};

pub fn Store(comptime tables: tables_module.Tables) type {
    return struct {
        const table = tables.definitions;
        const scope: groups.Scope = @field(groups.Scope, table);
        const encode = content_type.encode;
        const decode = content_type.decode;
        const id_of = content_type.id_of;
        const limit = std.fmt.comptimePrint("{d}", .{list_max});

        pub fn insert(
            connection: *db.Db,
            arena: std.mem.Allocator,
            def: Def,
            now_ms: i64,
        ) Error![]const u8 {
            std.debug.assert(def.handle.len > 0);
            std.debug.assert(now_ms >= 0);

            var id_buffer: [id_len]u8 = undefined;
            const derived = id_of(def.handle, &id_buffer);
            const id = arena.dupe(u8, derived) catch return error.OutOfMemory;
            var shell = def;
            shell.fields = &.{};
            shell.group = .{};
            const definition = try encode(arena, shell);
            var transaction = try connection.transaction();
            defer transaction.rollback();

            var statement = try connection.prepare(
                "INSERT INTO " ++ table ++ " (id, handle, name, icon, public, editor, " ++
                    "editor_config, definition, created_at, updated_at, system) " ++
                    "VALUES (?1, ?2, ?3, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?11)",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try bind_def(&statement, def, definition);
            try statement.bind_int(10, now_ms);
            try statement.exec();

            try groups.put(connection, arena, scope, id, .{
                .fields = def.fields,
                .options = def.group,
            });
            try transaction.commit();

            return id;
        }

        pub fn update(
            connection: *db.Db,
            arena: std.mem.Allocator,
            id: []const u8,
            def: Def,
            now_ms: i64,
        ) Error!bool {
            std.debug.assert(id.len > 0);
            std.debug.assert(now_ms >= 0);

            var shell = def;
            shell.fields = &.{};
            shell.group = .{};
            const definition = try encode(arena, shell);
            var transaction = try connection.transaction();
            defer transaction.rollback();

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET handle = ?2, name = ?3, icon = ?5, " ++
                    "public = ?6, editor = ?7, editor_config = ?8, definition = ?9, " ++
                    "updated_at = ?10, system = ?11 WHERE id = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try bind_def(&statement, def, definition);
            try statement.bind_int(10, now_ms);
            try statement.exec();

            const changed = connection.changes() > 0;

            if (changed) {
                try groups.put(connection, arena, scope, id, .{
                    .fields = def.fields,
                    .options = def.group,
                });
            }

            try transaction.commit();
            return changed;
        }

        fn bind_def(statement: *db.Statement, def: Def, definition: []const u8) db.Error!void {
            std.debug.assert(definition.len > 0);
            std.debug.assert(def.handle.len > 0);

            try statement.bind_text(2, def.handle);
            try statement.bind_text(3, def.name);
            try statement.bind_text(5, def.icon);
            try statement.bind_int(6, if (def.public) 1 else 0);
            try statement.bind_text(7, def.editor);
            try statement.bind_text(8, def.editor_config);
            try statement.bind_text(9, definition);
            try statement.bind_int(11, if (def.system) 1 else 0);
        }

        const select_columns = "id, definition, created_at, updated_at FROM " ++ table;

        pub fn get_by_id(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?Row {
            std.debug.assert(id.len > 0);
            std.debug.assert(id.len <= 128);

            var select = try connection.prepare("SELECT " ++ select_columns ++ " WHERE id = ?1");
            defer select.finalize();

            try select.bind_text(1, id);

            return try read_row(connection, &select, arena);
        }

        pub fn get_by_handle(
            connection: *db.Db,
            arena: std.mem.Allocator,
            handle: []const u8,
        ) Error!?Row {
            std.debug.assert(handle.len > 0);
            std.debug.assert(handle.len <= 128);

            var select = try connection.prepare(
                "SELECT " ++ select_columns ++ " WHERE handle = ?1",
            );
            defer select.finalize();

            try select.bind_text(1, handle);

            return try read_row(connection, &select, arena);
        }

        pub fn list(connection: *db.Db, arena: std.mem.Allocator) Error![]Row {
            std.debug.assert(list_max > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var select = try connection.prepare(
                "SELECT " ++ select_columns ++ " ORDER BY name, id LIMIT " ++ limit,
            );
            defer select.finalize();

            var rows: std.ArrayList(Row) = .empty;

            while (try read_row(connection, &select, arena)) |row| {
                std.debug.assert(rows.items.len < list_max);
                try rows.append(arena, row);
            }

            return rows.items;
        }

        const brief_columns = "id, handle, name, json_extract(definition, '$.kind'), " ++
            "json_extract(definition, '$.public'), json_extract(definition, '$.system'), " ++
            "json_extract(definition, '$.owner'), json_extract(definition, '$.editor'), " ++
            "(SELECT json_array_length(field_groups.definition, '$.fields') " ++
            "FROM field_groups WHERE scope = '" ++ table ++ "' AND owner = " ++ table ++
            ".id) FROM " ++ table;

        const BriefColumns = struct {
            id: []const u8,
            handle: []const u8,
            name: []const u8,
            kind: []const u8,
            public: bool,
            system: bool,
            owner: []const u8,
            editor: []const u8,
            fields_len: i64,
        };

        pub fn list_briefs(connection: *db.Db, arena: std.mem.Allocator) Error![]Brief {
            std.debug.assert(list_max > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var select = try connection.prepare(
                "SELECT " ++ brief_columns ++ " ORDER BY name, id LIMIT " ++ limit,
            );
            defer select.finalize();

            var briefs: std.ArrayList(Brief) = .empty;

            while (try select.step()) {
                std.debug.assert(briefs.items.len < list_max);

                const columns = try select.read(BriefColumns, arena);
                const kind = std.meta.stringToEnum(content_type.Kind, columns.kind) orelse {
                    return error.Invalid;
                };

                if (columns.fields_len < 0 or columns.fields_len > field.fields_max) {
                    return error.Invalid;
                }

                try briefs.append(arena, .{
                    .id = columns.id,
                    .handle = columns.handle,
                    .name = columns.name,
                    .kind = kind,
                    .public = columns.public,
                    .system = columns.system,
                    .owner = columns.owner,
                    .editor = columns.editor,
                    .fields_len = @intCast(columns.fields_len),
                });
            }

            return briefs.items;
        }

        /// Deleting a definition cascades to its documents and values; the search index
        /// (a virtual table, no cascade) and the snapshots are cleared here.
        pub fn delete(connection: *db.Db, id: []const u8) db.Error!bool {
            std.debug.assert(id.len > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var transaction = try connection.transaction();
            defer transaction.rollback();

            const statements = [_][:0]const u8{
                "DELETE FROM " ++ tables.search ++ " WHERE type_id = ?1",
                "DELETE FROM snapshots WHERE record IN (SELECT id FROM " ++ tables.documents ++
                    " WHERE type_id = ?1)",
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

            if (removed) {
                try groups.delete(connection, scope, id);
            }

            try transaction.commit();

            return removed;
        }

        /// `select_columns`, in order.
        const Columns = struct {
            id: []const u8,
            definition: []const u8,
            created_at: i64,
            updated_at: i64,
        };

        fn read_row(
            connection: *db.Db,
            select: *db.Statement,
            arena: std.mem.Allocator,
        ) Error!?Row {
            std.debug.assert(id_len > 0);

            if (!try select.step()) {
                return null;
            }

            const columns = try select.read(Columns, arena);

            std.debug.assert(columns.definition.len > 0);

            var def = try decode(arena, columns.definition);
            const group = try groups.get(connection, arena, scope, columns.id) orelse
                return error.Invalid;
            def.fields = group.fields;
            def.group = group.options;

            return .{
                .id = columns.id,
                .def = def,
                .created_at = columns.created_at,
                .updated_at = columns.updated_at,
            };
        }
    };
}
