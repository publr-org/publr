//! What only a built-in plugin does with the `publr.Ctx` it is handed, past what every
//! plugin does: `publr.Host.as_system(ctx)`, `database`, `state_of`, `io`, `mark_copy`,
//! `reload_plugins`. An installed build that asks for any of them does not compile.
const std = @import("std");
const guest = @import("../../sdk/plugin/guest.zig");
const Ctx = @import("../ctx.zig").Ctx;
const Database = @import("database.zig").Database;
const Error = @import("../operation.zig").Error;
const public_of = @import("../../sdk/operation.zig").public_of;

fn built_in(comptime name: []const u8) void {
    if (comptime guest.mode == .sandboxed) {
        @compileError("publr.Host." ++ name ++ " is for a built-in plugin");
    }
}

fn host(ctx: anytype) @TypeOf(@import("../../sdk/plugin/context.zig").host_of(ctx)) {
    return @import("../../sdk/plugin/context.zig").host_of(ctx);
}

fn PluginState(comptime Plugin: type) type {
    return @import("../../server/plugin_states.zig").StateOf(Plugin);
}

/// The same plugin, calling as Publr itself: past every role, for work no person and no
/// plugin's grants could do (signing a token for a project's owner while nobody is signed
/// in). What its grants cover is `ctx.as_plugin()`.
pub fn as_system(ctx: *Ctx) Error!*Ctx {
    comptime built_in("as_system");

    return host(ctx).as_system() catch |err| return public_of(err);
}

/// SQL on the plugin's own tables (`host.table`), inside the call's transaction.
pub fn database(ctx: *const Ctx) Database {
    comptime built_in("database");

    return host(ctx).database();
}

/// The state the plugin keeps for the life of the process (`host.state`); null where the
/// call runs with none made (a plugin's examples, a command with no server).
pub fn state_of(ctx: *const Ctx, comptime Plugin: type) ?*PluginState(Plugin) {
    comptime built_in("state_of");
    comptime std.debug.assert(@hasDecl(Plugin, "plugin"));

    const states = @import("../../server/plugin_states.zig");
    const held = host(ctx).inner.plugin_states orelse return null;

    return states.from(held, Plugin);
}

/// The process's I/O, for the plugin's own files and processes.
pub fn io(ctx: *const Ctx) std.Io {
    comptime built_in("io");

    return host(ctx).io();
}

/// The call runs on a copy of the site (an environment, a branch), not the site itself:
/// what the plugin keeping copies says before a call runs, so a `write` device publishes
/// there.
pub fn mark_copy(ctx: *Ctx) void {
    comptime built_in("mark_copy");

    host(ctx).mark_copy();
}

/// The installed plugins' rows changed underneath them (another copy's brought in): the
/// sandbox loads them again.
pub fn reload_plugins(ctx: *Ctx) void {
    comptime built_in("reload_plugins");

    host(ctx).reload_plugins();
}

test "publr.Host.database runs SQL on the plugin's own table, values bound in order" {
    const sdk = @import("../../sdk.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var inner = harness.ctx(.system);

    inner.plugin = "hello";

    var api: @import("../../sdk/plugin/context.zig").HostApi = .{
        .inner = &inner,
    };
    const ctx = api.ctx();
    const db = database(ctx);

    try inner.db.exec("CREATE TABLE shipping_shipments (carrier TEXT, sent_at INTEGER, note TEXT)");
    try db.exec(
        "INSERT INTO shipping_shipments (carrier, sent_at, note) VALUES (?, ?, ?)",
        .{ "inpost", @as(i64, 42), null },
    );

    var select = try db.prepare(
        "SELECT sent_at FROM shipping_shipments WHERE carrier = ?",
        .{"inpost"},
    );
    defer select.finalize();

    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(i64, 42), select.read_int());
    try std.testing.expect((try as_system(ctx)).caller().system);

    mark_copy(ctx);

    try std.testing.expect(inner.on_copy);
}
