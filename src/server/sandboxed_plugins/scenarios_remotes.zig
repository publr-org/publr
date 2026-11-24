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

/// Whether stocktake's log has a line under `call`, once the queue ran.
fn said(scenario: *Scenario, call: []const u8) !bool {
    var worker = scenario.ctx(.system);
    const drained = try registry.SDK.jobs.drain(&worker, 8);

    std.debug.assert(drained <= 8);

    var reading = scenario.ctx(.system);
    const logged = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "stocktake",
    });

    for (logged.lines) |line| {
        if (std.mem.eql(u8, line.call, call)) {
            return true;
        }
    }

    return false;
}

/// How many runs of stocktake's hook on shelf's event its log shows.
fn heard(scenario: *Scenario) !u32 {
    var worker = scenario.ctx(.system);
    const drained = try registry.SDK.jobs.drain(&worker, 8);

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

    try std.testing.expectEqual(@as(usize, 5), absent.off.len);
    try std.testing.expectEqualStrings("shelf isn't installed or enabled", absent.off[0].why);

    _ = try put(&scenario, "shelf.wasm", @embedFile("sandboxed_plugin_shelf"));
    try enable(&scenario, "shelf");
    try std.testing.expectEqual(@as(usize, 0), (try detail(&scenario, "stocktake")).off.len);

    var system = scenario.ctx(.system);
    const created = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "shelf.item",
        .document = .{
            .text = "{\"title\":\"Tea\",\"sku\":\"A-1\",\"note\":\"not for stocktake\"}",
        },
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
    // Its `on` hook emitted an event of its own, outside any write: its other hook heard it.
    try std.testing.expect(try said(&scenario, "event:stocktake.noted"));

    // Nested installed calls give their working memory back: each of nine hundred costs the
    // call only the trail's note of it, never its input and answer.
    const few = try nested_cost(&scenario, 20);
    const many = try nested_cost(&scenario, 900);

    try std.testing.expect(many < few + 880 * 128);

    // So do its calls to Publr's own operations, each given back once it answered.
    const read_few = try reads_cost(&scenario, created.id, 5);
    const read_many = try reads_cost(&scenario, created.id, 200);

    try std.testing.expect(read_many < read_few + 200 * 128);

    // shelf's own `after` hook on its operation runs whoever calls it: a person, or
    // another installed plugin's code.
    const kept = "{\"sku\":\"KEPT\"}";

    try std.testing.expectError(error.Invalid, scenario.call(admin, "shelf.restock", kept));
    try std.testing.expectError(error.Invalid, scenario.call(admin, "stocktake.pass_on", kept));

    // The refusal's words reach the caller as they were said, through another installed
    // plugin's call too: kept past the memory each call gives back.
    const working_buffer = try std.testing.allocator.alloc(u8, 128 << 10);
    defer std.testing.allocator.free(working_buffer);

    for ([_][]const u8{ "shelf.restock", "stocktake.pass_on" }) |name| {
        var told = scenario.ctx(admin);
        var told_working: sdk.Scratch = .{
            .fixed = .init(working_buffer),
        };

        told.calls_set_aside = &told_working;

        const none = "{\"sku\":\"NONE\"}";

        try std.testing.expectError(error.Invalid, registry.SDK.call_json(&told, name, none));
        try std.testing.expectEqual(@as(usize, 1), told.problems.len);
        try std.testing.expectEqualStrings("No item has the SKU NONE", told.problems[0].message);

        var refused = scenario.ctx(admin);
        // Working memory set aside, as a request has: each call's given back as it ends.
        var working: sdk.Scratch = .{
            .fixed = .init(working_buffer),
        };

        refused.calls_set_aside = &working;

        try std.testing.expectError(error.Invalid, registry.SDK.call_json(&refused, name, kept));
        try std.testing.expectEqual(@as(usize, 1), refused.problems.len);
        try std.testing.expectEqualStrings("sku", refused.problems[0].field);
        try std.testing.expectEqualStrings(
            "Kept back: never restocked",
            refused.problems[0].message,
        );
    }

    // labels needs sku as text: it fits 0.1.0, and stops an update that changes it.
    _ = try put(&scenario, "labels.wasm", @embedFile("sandboxed_plugin_labels"));
    try enable(&scenario, "labels");
    _ = try put(&scenario, "shelf-next.wasm", @embedFile("sandboxed_plugin_shelf_next"));

    const reviewed = (try detail(&scenario, "shelf")).update.?;

    try std.testing.expectEqual(@as(usize, 1), reviewed.stops.len);
    try std.testing.expect(std.mem.startsWith(u8, reviewed.stops[0], "labels: "));
    try std.testing.expectEqual(@as(usize, 4), reviewed.switches_off.len);

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

    // The check ran again: count is gone, restock and the event take a number now and a
    // bin's count is text, so those four are off; the item still fits; stocktake's own operation
    // still works.
    try std.testing.expectError(error.Unavailable, scenario.call(admin, take, "{}"));
    _ = try scenario.call(admin, "stocktake.note", note);
    _ = try scenario.call(admin, "shelf.restock", "{\"sku\":7}");
    try std.testing.expectEqual(@as(u32, 1), try heard(&scenario));

    const updated = try detail(&scenario, "stocktake");

    try std.testing.expectEqual(@as(usize, 4), updated.off.len);
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

test "published interfaces: a provider of another plugin's contract, checked as its owner updates" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    // parcel_post was built against parcels' published interface, without its code.
    _ = try put(&scenario, "parcels.wasm", @embedFile("sandboxed_plugin_parcels"));
    try enable(&scenario, "parcels");
    _ = try put(&scenario, "parcel-post.wasm", @embedFile("sandboxed_plugin_parcel_post"));
    var granting = scenario.ctx(.system);

    _ = try registry.SDK.dispatch(&granting, plugin_operations.Enable, .{
        .names = &.{"parcel_post"},
        .grants = &.{.{
            .key = "http.fetch",
            .on = true,
        }},
    });

    const carriers = "parcels.carriers";

    const listed = try scenario.call(admin, carriers, "{}");

    try std.testing.expect(std.mem.indexOf(u8, listed, "parcel_post") != null);
    try std.testing.expectEqual(@as(usize, 0), (try detail(&scenario, "parcel_post")).blocked.len);

    // Asked at install: what parcel_post carries is kept, and parcels reads it back.
    const reading = scenario.ctx(.system);
    const kept = try @import("../../store.zig").settings.get(
        reading.db,
        reading.arena,
        "provider_answers.parcels.carrier.parcel_post",
    );

    try std.testing.expect(std.mem.indexOf(u8, kept.?, "parcels up to 30 kg") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept.?, "\"version\":\"0.1.0\"") != null);

    const facts = try scenario.call(admin, "parcels.facts", "{}");

    try std.testing.expectEqualStrings("{\"carries\":[\"parcels up to 30 kg\"]}", facts);
    try std.testing.expectEqualStrings("Tracked: answered 200", try tracked(&scenario));

    // An app listing parcels reaches its carriers too, at any depth of a call, without
    // listing each; never a plugin it does not list that provides none of its contracts.
    var visiting = scenario.ctx(.anonymous);

    visiting.app_plugins = &.{"parcels"};
    try registry.SDK.check_fence(&visiting, "parcel_post");
    try registry.SDK.check_fence(&visiting, "parcels");
    try std.testing.expectError(error.Denied, registry.SDK.check_fence(&visiting, "greeter"));

    // parcels 0.2.0 requires a part parcel_post does not answer: the update is stopped.
    _ = try put(&scenario, "parcels-next.wasm", @embedFile("sandboxed_plugin_parcels_next"));

    const reviewed = (try detail(&scenario, "parcels")).update.?;

    try std.testing.expectEqual(@as(usize, 1), reviewed.stops.len);
    try std.testing.expectEqualStrings(
        "parcel_post: parcels 0.2.0: parcels.carrier needs the part label",
        reviewed.stops[0],
    );

    var updating = scenario.ctx(.system);
    const stopped = registry.SDK.dispatch(&updating, plugin_operations.Update, .{
        .name = "parcels",
    });

    try std.testing.expectError(error.Failed, stopped);

    // Without the provider, parcels updates; the provider can't be enabled again, and says why.
    var stopping = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&stopping, plugin_operations.Disable, .{
        .names = &.{"parcel_post"},
    });
    updating = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&updating, plugin_operations.Update, .{
        .name = "parcels",
    });

    const none = try scenario.call(admin, carriers, "{}");

    try std.testing.expect(std.mem.indexOf(u8, none, "parcel_post") == null);
    try std.testing.expectError(error.Failed, enable(&scenario, "parcel_post"));
    try std.testing.expectEqualStrings(
        "parcels 0.2.0: parcels.carrier needs the part label",
        (try detail(&scenario, "parcel_post")).blocked[0],
    );
}

/// What parcels logged when its queued `tracking` asked parcel_post, whose part sends a
/// request out to this machine: from queued work, a contract's part may call out.
fn tracked(scenario: *Scenario) ![]const u8 {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const arena = scenario.harness.fixed.allocator();
    const input = try std.fmt.allocPrint(arena, "{{\"number\":\"http://localhost:{d}/track\"}}", .{
        server.socket.address.getPort(),
    });

    std.debug.assert(input.len > 0);
    _ = try scenario.call(admin, "parcels.follow", input);

    const answering = try std.Thread.spawn(.{}, scenarios.answer_once, .{ io, &server });
    var worker = scenario.ctx(.system);

    worker.outside.production = false;

    const drained = registry.SDK.jobs.drain(&worker, 8);
    var reading = scenario.ctx(.system);
    const logged = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "parcels",
    });
    const line = logged.lines[0].line;

    // Refused before it went out: the server is reached here, so it stops waiting.
    if (!std.mem.startsWith(u8, line, "Tracked")) {
        const stream = try server.socket.address.connect(io, .{
            .mode = .stream,
        });

        stream.close(io);
    }

    answering.join();
    try std.testing.expectEqual(@as(u32, 1), try drained);

    return line;
}

/// The call's memory `stocktake.read_many` takes reading shelf's `item` `times` times, its
/// working memory 128 KiB: more than the reads take together, it runs again in the call's own.
fn reads_cost(scenario: *Scenario, item: []const u8, times: u32) !u64 {
    var calling = scenario.ctx(admin);
    const input = try std.fmt.allocPrint(calling.arena, "{{\"item\":\"{s}\",\"times\":{d}}}", .{
        item,
        times,
    });
    const buffer = try std.testing.allocator.alloc(u8, 128 << 10);
    defer std.testing.allocator.free(buffer);

    var working: sdk.Scratch = .{
        .fixed = .init(buffer),
    };

    calling.calls_set_aside = &working;

    const before = scenario.harness.fixed.end_index;

    _ = try registry.SDK.call_json(&calling, "stocktake.read_many", input);

    std.debug.assert(scenario.harness.fixed.end_index >= before);
    std.debug.assert(working.fixed.end_index == 0);

    return @intCast(scenario.harness.fixed.end_index - before);
}

/// The call's memory `stocktake.count_many` takes asking `shelf.count` `times` times.
fn nested_cost(scenario: *Scenario, times: u32) !u64 {
    var calling = scenario.ctx(admin);
    const input = try std.fmt.allocPrint(calling.arena, "{{\"times\":{d}}}", .{times});

    // Its working memory set aside first, as any call before it would.
    _ = try calling.call_scratch();

    const before = scenario.harness.fixed.end_index;

    _ = try registry.SDK.call_json(&calling, "stocktake.count_many", input);

    std.debug.assert(scenario.harness.fixed.end_index >= before);

    return @intCast(scenario.harness.fixed.end_index - before);
}
