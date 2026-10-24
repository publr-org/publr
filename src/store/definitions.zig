//! A definitions table (`content_types`, `taxonomies`): the schema rows. The definition
//! itself (fields, validation, JSON) is `model/content_type.zig`.

const std = @import("std");
const db = @import("../lib/db.zig");
const content_type = @import("../model/content_type.zig");
const status_model = @import("../model/status.zig");
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
    /// Where the type lives (empty: Global) and who it is shared with.
    app: []const u8 = "",
    shared: ?content_type.Shared = null,
    /// Private: the roles that reach it besides administrators; empty: every role.
    roles: []const []const u8 = &.{},
    menu: content_type.Menu = .{},
    view: content_type.View = .{},
    icon: []const u8 = "",
    /// A taxonomy that never reaches the site.
    internal: bool = false,
};

pub fn Store(comptime tables: tables_module.Tables) type {
    return struct {
        /// The tables this store's definitions and their documents live in.
        pub const names = tables;
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
            "coalesce(json_extract(definition, '$.app'), ''), " ++
            "coalesce(json_extract(definition, '$.shared'), ''), " ++
            "coalesce(json_extract(definition, '$.roles'), ''), " ++
            "coalesce(json_extract(definition, '$.menu'), ''), " ++
            "coalesce(json_extract(definition, '$.view'), ''), " ++
            "coalesce(json_extract(definition, '$.icon'), ''), " ++
            "coalesce(json_extract(definition, '$.internal'), 0), " ++
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
            app: []const u8,
            shared: []const u8,
            roles: []const u8,
            menu: []const u8,
            view: []const u8,
            icon: []const u8,
            internal: bool,
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

                try briefs.append(arena, try brief_read(&select, arena));
            }

            return briefs.items;
        }

        /// Every type's own statuses, as their flows keep them (`flow.statuses`): read
        /// straight from the JSON, no definition decoded. Namespaced, so no two share an id.
        pub fn own_statuses(
            connection: *db.Db,
            arena: std.mem.Allocator,
        ) Error![]const status_model.Status {
            std.debug.assert(list_max > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var select = try connection.prepare(
                "SELECT own.value ->> 'id', own.value ->> 'label', " ++
                    "coalesce(own.value ->> 'color', 'neutral'), " ++
                    "coalesce(own.value ->> 'live', 0), coalesce(own.value ->> 'listed', 1), " ++
                    "coalesce(own.value ->> 'alias', '') " ++
                    "FROM " ++ table ++ ", json_each(definition, '$.flow.statuses') AS own " ++
                    "ORDER BY 1 LIMIT ?1",
            );
            defer select.finalize();

            // With core's, at most `statuses_max` in all: what one list's buffer holds.
            const own_max = status_model.statuses_max - status_model.core_statuses.len;

            try select.bind_int(1, own_max);

            var found: std.ArrayList(status_model.Status) = .empty;

            while (try select.step()) {
                const row = try select.read(struct {
                    id: []const u8,
                    label: []const u8,
                    color: []const u8,
                    live: i64,
                    listed: i64,
                    alias: []const u8,
                }, arena);

                std.debug.assert(found.items.len < own_max);

                try found.append(arena, .{
                    .id = row.id,
                    .label = row.label,
                    .color = std.meta.stringToEnum(status_model.Color, row.color) orelse .neutral,
                    .live = row.live != 0,
                    .listed = row.listed != 0,
                    .alias = row.alias,
                });
            }

            return found.items;
        }

        /// Where a reading of the definitions by name stands: after this name and id; the
        /// empty one is before every definition.
        pub const BriefKey = struct {
            name: []const u8 = "",
            id: []const u8 = "",
        };

        /// The next `limit` definitions after `after`, by name, for a reading that goes
        /// through them in pages.
        pub fn briefs_after(
            connection: *db.Db,
            arena: std.mem.Allocator,
            after: BriefKey,
            limit_count: u32,
        ) Error![]Brief {
            std.debug.assert(limit_count > 0 and limit_count <= list_max);
            std.debug.assert(connection.transaction_depth <= 8);

            var select = try connection.prepare("SELECT " ++ brief_columns ++
                " WHERE (name, id) > (?1, ?2) ORDER BY name, id LIMIT ?3");
            defer select.finalize();

            try select.bind_text(1, after.name);
            try select.bind_text(2, after.id);
            try select.bind_int(3, limit_count);

            var briefs: std.ArrayList(Brief) = .empty;

            while (try select.step()) {
                std.debug.assert(briefs.items.len < limit_count);

                try briefs.append(arena, try brief_read(&select, arena));
            }

            return briefs.items;
        }

        /// One definition's brief, by id; null when there is none.
        pub fn brief_by_id(
            connection: *db.Db,
            arena: std.mem.Allocator,
            id: []const u8,
        ) Error!?Brief {
            std.debug.assert(id.len > 0);
            std.debug.assert(id.len <= 128);

            var select = try connection.prepare("SELECT " ++ brief_columns ++ " WHERE id = ?1");
            defer select.finalize();

            try select.bind_text(1, id);

            if (!try select.step()) {
                return null;
            }

            return try brief_read(&select, arena);
        }

        fn brief_read(select: *db.Statement, arena: std.mem.Allocator) Error!Brief {
            const columns = try select.read(BriefColumns, arena);

            std.debug.assert(columns.id.len > 0);

            const kind = std.meta.stringToEnum(content_type.Kind, columns.kind) orelse {
                return error.Invalid;
            };

            if (columns.fields_len < 0 or columns.fields_len > field.fields_max) {
                return error.Invalid;
            }

            return .{
                .id = columns.id,
                .handle = columns.handle,
                .name = columns.name,
                .kind = kind,
                .public = columns.public,
                .system = columns.system,
                .owner = columns.owner,
                .editor = columns.editor,
                .fields_len = @intCast(columns.fields_len),
                .app = columns.app,
                .shared = try shared_of(arena, columns.shared),
                .roles = try roles_of(arena, columns.roles),
                .menu = try part_of(content_type.Menu, arena, columns.menu),
                .view = try part_of(content_type.View, arena, columns.view),
                .icon = columns.icon,
                .internal = columns.internal,
            };
        }

        /// A part of a definition's JSON (`menu`, `view`): absent reads as its defaults.
        fn part_of(comptime Part: type, arena: std.mem.Allocator, text: []const u8) Error!Part {
            std.debug.assert(text.len <= content_type.definition_bytes_max);

            if (text.len == 0) {
                return .{};
            }

            const options: std.json.ParseOptions = .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            };
            return std.json.parseFromSliceLeaky(Part, arena, text, options) catch |err| {
                return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
            };
        }

        /// The `roles` of a definition's JSON: absent reads as none.
        fn roles_of(arena: std.mem.Allocator, text: []const u8) Error![]const []const u8 {
            std.debug.assert(text.len <= content_type.definition_bytes_max);

            if (text.len == 0) {
                return &.{};
            }

            const options: std.json.ParseOptions = .{
                .allocate = .alloc_always,
            };

            const Roles = []const []const u8;

            return std.json.parseFromSliceLeaky(Roles, arena, text, options) catch |err| {
                return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
            };
        }

        /// The `shared` of a definition's JSON: absent, or the object `Shared` encodes to.
        fn shared_of(arena: std.mem.Allocator, text: []const u8) Error!?content_type.Shared {
            std.debug.assert(text.len <= content_type.definition_bytes_max);

            if (text.len == 0) {
                return null;
            }

            const options: std.json.ParseOptions = .{
                .allocate = .alloc_always,
            };

            const Shared = content_type.Shared;

            return std.json.parseFromSliceLeaky(Shared, arena, text, options) catch |err| {
                return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
            };
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
