//! A transition asked for on a document (`records`, `terms`) by someone who may not publish,
//! waiting for someone who may: its name and who asked, one per document.

const std = @import("std");
const db = @import("../../lib/db.zig");
const tables_module = @import("../tables.zig");

pub const Error = db.Error || error{NotFound};

/// Resets the request wherever a status is written: whatever waited is settled.
pub const cleared_set = "requested = '', requested_by = NULL";

pub fn Requests(comptime tables: tables_module.Tables) type {
    return struct {
        const table = tables.documents;

        /// Keeps `transition` as asked by `by`, in place of any request before it.
        pub fn ask(
            connection: *db.Db,
            id: []const u8,
            transition: []const u8,
            by: ?[]const u8,
        ) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(transition.len > 0);

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET requested = ?2, requested_by = ?3 WHERE id = ?1",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try statement.bind_text(2, transition);
            try statement.bind_optional_text(3, by);
            try statement.exec();

            if (connection.changes() != 1) {
                return error.NotFound;
            }
        }

        /// Drops the request waiting on `id`, if any; whether one was there.
        pub fn clear(connection: *db.Db, id: []const u8) Error!bool {
            std.debug.assert(id.len > 0);
            std.debug.assert(connection.transaction_depth <= 8);

            var statement = try connection.prepare(
                "UPDATE " ++ table ++ " SET " ++ cleared_set ++
                    " WHERE id = ?1 AND requested <> ''",
            );
            defer statement.finalize();

            try statement.bind_text(1, id);
            try statement.exec();

            return connection.changes() == 1;
        }
    };
}
