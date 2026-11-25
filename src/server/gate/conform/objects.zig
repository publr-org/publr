const std = @import("std");
const db = @import("../../../lib/db.zig");
const rebuild = @import("rebuild.zig");
const conform = @import("../conform.zig");
const sql = @import("sql.zig");

/// The refused indexes and triggers of tables not rebuilt: one this release does not have
/// dropped, one it has otherwise (or not at all) made from its statement.
pub fn repair(
    work: *rebuild.Work,
    differences: []const db.shape.Difference,
    expected: db.shape.Shape,
    live: db.shape.Shape,
    rebuilt: []const []const u8,
) !void {
    std.debug.assert(work.connection.transaction_depth >= 1);
    std.debug.assert(rebuilt.len <= expected.tables.len);

    const arena = work.arena;

    for (differences) |difference| {
        if (difference.compatible) {
            continue;
        }

        const kind = conform.object_kind(difference.subject) orelse continue;
        const name = difference.subject[@tagName(kind).len + 1 ..];
        const found = object_of(live.objects, name);
        const wanted = object_of(expected.objects, name);
        const owner = if (found) |object| object.table else wanted.?.table;

        if (conform.index_of(rebuilt, owner) != null) {
            continue;
        }

        std.debug.assert(found != null or wanted != null);

        if (found != null) {
            try sql.exec(work.connection, try std.fmt.allocPrint(arena, "DROP {s} {s}", .{
                if (kind == .index) "INDEX" else "TRIGGER",
                try sql.quote(arena, name),
            }));
        }

        if (wanted != null) {
            const statement = try sql.statement_of(work.expected, arena, @tagName(kind), name);

            try sql.exec(work.connection, statement);
        }

        try work.changes.append(arena, .{
            .kind = if (wanted == null) .drop else .create,
            .name = difference.subject,
        });
    }
}

fn object_of(objects: []const db.shape.Object, name: []const u8) ?db.shape.Object {
    std.debug.assert(name.len > 0);
    std.debug.assert(objects.len <= db.shape.objects_max);

    for (objects) |object| {
        if (std.mem.eql(u8, object.name, name)) {
            return object;
        }
    }

    return null;
}
