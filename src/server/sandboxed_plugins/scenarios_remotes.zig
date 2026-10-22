//! Remotes checked against the real thing, on the test plugins `shelf` (and its update
//! `shelf_next`), `labels` (needs shelf) and `stocktake` (works with shelf when it fits,
//! its internal `shelf.bin` included).
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const plugin_operations = @import("../../operations/plugin.zig");
const plugin_log = @import("../../operations/plugin/log.zig");
const records = @import("../../operations/record.zig");
const scenarios = @import("scenarios.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;

/// Adds the test module `name` from its bytes (as `file`), and enables it unless it is an
/// update of one already there.
pub fn put(scenario: *Scenario, file: []const u8, bytes: []const u8) !plugin_operations.Added {
    const arena = scenario.harness.fixed.allocator();

    std.debug.assert(bytes.len > 0);
    try scenario.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = file,
        .data = bytes,
    });

    const path = try std.mem.replaceOwned(u8, arena, scenario.path, "greeter.wasm", file);

    return scenario.add(path);
}

pub fn enable(scenario: *Scenario, name: []const u8) !void {
    var enabling = scenario.ctx(.system);

    std.debug.assert(name.len > 0);

    _ = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{name},
    });
}

fn detail(scenario: *Scenario, name: []const u8) !plugin_operations.Detail {
    var reading = scenario.ctx(.system);

    std.debug.assert(name.len > 0);

    return registry.SDK.dispatch(&reading, plugin_operations.Get, .{
        .name = name,
    });
}

/// How many runs of stocktake's hook on shelf's event its log shows.
fn heard(scenario: *Scenario) !u32 {
    var worker = scenario.ctx(.system);
    const drained = try registry.SDK.events.drain(&worker, 8);

    std.debug.assert(drained <= 8);

    var reading = scenario.ctx(.system);
    const logged = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "stocktake",
    });
    var count: u32 = 0;

    for (logged.lines) |line| {
        count += @intFromBool(std.mem.eql(u8, line.call, "event:shelf.restocked"));
    }

    return count;
}

test "remotes: absent is unavailable, fitting works, an update switches off what no longer fits" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try put(&scenario, "stocktake.wasm", @embedFile("sandboxed_plugin_stocktake"));
    try enable(&scenario, "stocktake");

    // No shelf: the remote is off, its call unavailable (not "not found"); the rest works.
    const take = "stocktake.take";
    const note = "{\"text\":\"Aisle 3\"}";

    try std.testing.expectError(error.Unavailable, scenario.call(admin, take, "{}"));
    _ = try scenario.call(admin, "stocktake.note", note);

    const absent = try detail(&scenario, "stocktake");

    try std.testing.expectEqual(@as(usize, 4), absent.off.len);
    try std.testing.expectEqualStrings("shelf isn't installed or enabled", absent.off[0].why);

    _ = try put(&scenario, "shelf.wasm", @embedFile("sandboxed_plugin_shelf"));
    try enable(&scenario, "shelf");
    try std.testing.expectEqual(@as(usize, 0), (try detail(&scenario, "stocktake")).off.len);

    var system = scenario.ctx(.system);
    const created = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "shelf.item",
        .document = "{\"title\":\"Tea\",\"sku\":\"A-1\",\"note\":\"not for stocktake\"}",
    });
    _ = try registry.SDK.dispatch(&system, records.Publish, .{
        .id = created.id,
    });

    try std.testing.expect(std.mem.indexOf(u8, try scenario.call(admin, take, "{}"), "1") != null);

    // A remote record read answers only the fields stocktake lists.
    var reading = scenario.ctx(admin);
    const input = try std.fmt.allocPrint(reading.arena, "{{\"id\":\"{s}\"}}", .{created.id});
    const got = try scenario.host.sandboxed_plugins().call_as(
        &reading,
        "stocktake",
        "record.get",
        input,
    );

    try std.testing.expect(std.mem.indexOf(u8, got, "Tea") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "not for stocktake") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "A-1") == null);

    // Its hook on shelf's event runs while it fits.
    _ = try scenario.call(admin, "shelf.restock", "{\"sku\":\"A-1\"}");
    try std.testing.expectEqual(@as(u32, 1), try heard(&scenario));

    // labels needs sku as text: it fits 0.1.0, and stops an update that changes it.
    _ = try put(&scenario, "labels.wasm", @embedFile("sandboxed_plugin_labels"));
    try enable(&scenario, "labels");
    _ = try put(&scenario, "shelf-next.wasm", @embedFile("sandboxed_plugin_shelf_next"));

    const reviewed = (try detail(&scenario, "shelf")).update.?;

    try std.testing.expectEqual(@as(usize, 1), reviewed.stops.len);
    try std.testing.expect(std.mem.startsWith(u8, reviewed.stops[0], "labels: "));
    try std.testing.expectEqual(@as(usize, 3), reviewed.switches_off.len);

    var updating = scenario.ctx(.system);
    const stopped = registry.SDK.dispatch(&updating, plugin_operations.Update, .{
        .name = "shelf",
    });

    try std.testing.expectError(error.Failed, stopped);

    // Its records go first: an update that drops a field keeps no values in it.
    var clearing = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&clearing, records.Delete, .{
        .id = created.id,
    });
    clearing = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&clearing, records.Purge, .{
        .id = created.id,
    });

    var stopping = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&stopping, plugin_operations.Disable, .{
        .names = &.{"labels"},
    });
    updating = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&updating, plugin_operations.Update, .{
        .name = "shelf",
    });

    // The check ran again: count is gone, the event's payload changed and a bin's count is
    // text now, so those three are off; the item still fits; stocktake's own operation
    // still works.
    try std.testing.expectError(error.Unavailable, scenario.call(admin, take, "{}"));
    _ = try scenario.call(admin, "stocktake.note", note);
    _ = try scenario.call(admin, "shelf.restock", "{\"sku\":7}");
    try std.testing.expectEqual(@as(u32, 1), try heard(&scenario));

    const updated = try detail(&scenario, "stocktake");

    try std.testing.expectEqual(@as(usize, 3), updated.off.len);
    try std.testing.expectEqualStrings("shelf.count", updated.off[0].name);
    try std.testing.expectEqualStrings(
        "shelf 0.2.0 has no operation shelf.count",
        updated.off[0].why,
    );

    // An internal record's fields are checked by kind, as a content record's are.
    try std.testing.expectEqualStrings("shelf.bin", updated.off[2].name);
    try std.testing.expectEqualStrings(
        "shelf 0.2.0 keeps count on shelf.bin as string, not a whole number",
        updated.off[2].why,
    );

    // labels can't be enabled now, and says why.
    try std.testing.expectError(error.Failed, enable(&scenario, "labels"));

    const blocked = try detail(&scenario, "labels");

    try std.testing.expectEqualStrings(
        "shelf 0.2.0 has no sku on shelf.item",
        blocked.blocked[0],
    );
}
