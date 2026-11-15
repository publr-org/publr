//! This computer's rows carried into a database taken in from elsewhere (`site import
//! --keep-local`): whom it trusts to sign people in, and the sessions and devices of the
//! accounts the new database still has, so a pulled site keeps who is signed in here.
const std = @import("std");
const db = @import("../../lib/db.zig");

/// This machine's rows carried into the pulled database, for the accounts it still has.
const kept_rows = [_][:0]const u8{
    "INSERT OR REPLACE INTO settings SELECT * FROM here.settings " ++
        "WHERE key LIKE 'sign\\_on.%' ESCAPE '\\'",
    "INSERT OR IGNORE INTO sessions SELECT * FROM here.sessions " ++
        "WHERE user_id IN (SELECT id FROM users)",
    "INSERT OR IGNORE INTO devices SELECT * FROM here.devices " ++
        "WHERE user_id IN (SELECT id FROM users)",
};

/// This machine's rows in the database at `own` (whom it trusts to sign people in, its
/// sessions and devices, for the accounts `pulled` still has) carried into `pulled`.
pub fn keep_local_rows_of(own: []const u8, pulled: [:0]const u8) !void {
    std.debug.assert(own.len > 0);
    std.debug.assert(pulled.len > 0);

    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, pulled);
    defer connection.close();

    var attach = try connection.prepare("ATTACH DATABASE ?1 AS here");
    defer attach.finalize();

    try attach.bind_text(1, own);

    // SQLite counts ATTACH as a read-only statement, which `exec` refuses.
    const row = try attach.step();

    std.debug.assert(!row);

    inline for (kept_rows) |statement| {
        try connection.exec(statement);
    }
}
