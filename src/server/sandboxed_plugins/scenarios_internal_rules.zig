const std = @import("std");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const Json = @import("../../sdk/operation.zig").Json;

/// `internal.create`'s input for one of till's moves: `document` is the record, as JSON.
fn move(scenario: *Scenario, document: []const u8) ![]const u8 {
    const arena = scenario.harness.fixed.allocator();

    std.debug.assert(document.len > 0);

    return std.json.Stringify.valueAlloc(arena, .{
        .plugin = "till",
        .kind = "move",
        .document = Json{
            .text = document,
        },
    }, .{});
}

/// `internal.save`'s input for till's move `id`.
fn save(arena: std.mem.Allocator, id: []const u8, document: []const u8) ![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(document.len > 0);

    return std.json.Stringify.valueAlloc(arena, .{
        .plugin = "till",
        .kind = "move",
        .id = id,
        .document = Json{
            .text = document,
        },
    }, .{});
}

fn installed(scenario: *Scenario) !void {
    std.debug.assert(@embedFile("sandboxed_plugin_till").len > 0);

    _ = try scenarios_remotes.put(scenario, "till.wasm", @embedFile("sandboxed_plugin_till"));
    try scenarios_remotes.enable(scenario, "till");
    _ = try scenarios_remotes.put(
        scenario,
        "postcard.wasm",
        @embedFile("sandboxed_plugin_postcard"),
    );
    try scenarios_remotes.enable(scenario, "postcard");
}

test "internal records run their field rules: bounds, a unique id, a provider" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario);

    const first = try move(&scenario, "{\"key\":\"t1\",\"count\":500}");

    _ = try scenario.call(admin, "internal.create", first);

    // The same id again is a conflict: a transfer sent twice is kept once.
    try std.testing.expectError(error.Conflict, scenario.call(admin, "internal.create", first));

    const too_much = try move(&scenario, "{\"key\":\"t2\",\"count\":200000}");
    const long_note = try move(&scenario, "{\"key\":\"t3\",\"count\":1," ++
        "\"note\":\"a note longer than twenty\"}");
    const no_provider = try move(&scenario, "{\"key\":\"t4\",\"count\":1," ++
        "\"told_by\":\"pigeon\"}");
    const told = try move(&scenario, "{\"key\":\"t5\",\"count\":1,\"told_by\":\"postcard\"}");
    // A repeater's own rule: at most three lines.
    const lines = "[{\"sku\":\"a\"},{\"sku\":\"b\"},{\"sku\":\"c\"},{\"sku\":\"d\"}]";
    const too_many = try move(&scenario, "{\"key\":\"t6\",\"count\":1,\"lines\":" ++
        lines ++ "}");
    const one_line = try move(&scenario, "{\"key\":\"t7\",\"count\":1,\"lines\":" ++
        "[{\"sku\":\"a\"}]}");

    try std.testing.expectError(error.Invalid, scenario.call(admin, "internal.create", too_many));
    _ = try scenario.call(admin, "internal.create", one_line);

    try std.testing.expectError(error.Invalid, scenario.call(admin, "internal.create", too_much));
    try std.testing.expectError(error.Invalid, scenario.call(admin, "internal.create", long_note));
    try std.testing.expectError(
        error.Invalid,
        scenario.call(admin, "internal.create", no_provider),
    );
    _ = try scenario.call(admin, "internal.create", told);

    // Found by its unique id; one refused left nothing behind.
    const found = try scenario.call(
        admin,
        "internal.find_one",
        "{\"plugin\":\"till\",\"kind\":\"move\",\"field\":\"key\",\"value\":\"t1\"}",
    );
    const missing = try scenario.call(
        admin,
        "internal.find_one",
        "{\"plugin\":\"till\",\"kind\":\"move\",\"field\":\"key\",\"value\":\"t2\"}",
    );

    try std.testing.expect(std.mem.indexOf(u8, found, "\"count\":500") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"record\":null") != null);
}

test "internal records: a save keeps its own unique value and runs the record's rule" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario);

    const arena = scenario.harness.fixed.allocator();
    const made = try scenario.call(
        admin,
        "internal.create",
        try move(&scenario, "{\"key\":\"t1\",\"count\":5}"),
    );
    _ = try scenario.call(
        admin,
        "internal.create",
        try move(&scenario, "{\"key\":\"t2\",\"count\":6}"),
    );
    const Made = struct {
        id: []const u8,
    };
    const id = (try std.json.parseFromSliceLeaky(Made, arena, made, .{
        .ignore_unknown_fields = true,
    })).id;

    _ = try scenario.call(admin, "internal.save", try save(arena, id, "{\"count\":7}"));
    try std.testing.expectError(
        error.Conflict,
        scenario.call(admin, "internal.save", try save(arena, id, "{\"key\":\"t2\"}")),
    );
    try std.testing.expectError(
        error.Invalid,
        scenario.call(admin, "internal.save", try save(arena, id, "{\"refund\":true}")),
    );
    _ = try scenario.call(
        admin,
        "internal.save",
        try save(arena, id, "{\"refund\":true,\"note\":\"broken cup\"}"),
    );
}

test "a plugin with users.own makes accounts of its own type only" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario);

    const made = try scenario.call(admin, "till.add", "{\"email\":\"ada@example.com\"}");

    try std.testing.expect(std.mem.indexOf(u8, made, "user_id") != null);
    try std.testing.expectError(
        error.Denied,
        scenario.call(admin, "till.add", "{\"email\":\"boss@example.com\",\"staff\":true}"),
    );

    const regulars = try scenario.call(admin, "user.list", "{\"user_type\":\"till_regular\"}");

    try std.testing.expect(std.mem.indexOf(u8, regulars, "ada@example.com") != null);
}

test "visitors sign up and ask for a new password on an app; nothing says who has one" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario);

    const visitors = @import("../../operations/user/visitors.zig");
    const store = @import("../../store.zig");
    const registry = @import("../registry.zig");
    var visiting = scenario.ctx(.anonymous);

    visiting.app = "www";
    visiting.app_address = "https://example.com";

    const signed_up = try registry.SDK.dispatch(&visiting, visitors.SignUp, .{
        .user_type = "till_regular",
        .email = "ada@example.com",
        .display_name = "Ada",
    });

    try std.testing.expect(signed_up.sent);

    const reading = scenario.ctx(.system);
    const account = (try store.users.find_by_email(
        reading.db,
        reading.arena,
        "ada@example.com",
    )).?;

    try std.testing.expectEqualStrings("till_regular", account.user.user_types[0]);
    try std.testing.expect(!account.user.active);

    // Asking again, or for someone with no account: the same answer.
    visiting = scenario.ctx(.anonymous);
    visiting.app = "www";
    visiting.app_address = "https://example.com";

    const again = try registry.SDK.dispatch(&visiting, visitors.RequestReset, .{
        .email = "ada@example.com",
    });
    const nobody = try registry.SDK.dispatch(&visiting, visitors.RequestReset, .{
        .email = "nobody@example.com",
    });

    try std.testing.expect(again.sent and nobody.sent);

    // Asking over and over: a few go through, then it waits, account or not.
    var asked: u32 = 0;
    var throttled = false;

    while (asked < 16 and !throttled) : (asked += 1) {
        _ = registry.SDK.dispatch(&visiting, visitors.RequestReset, .{
            .email = "grace@example.com",
        }) catch |err| {
            try std.testing.expectEqual(error.Throttled, err);
            throttled = true;
        };
    }

    try std.testing.expect(throttled and asked >= 2);

    // Not on an app the type opens: refused, without a reason.
    var elsewhere = scenario.ctx(.anonymous);

    elsewhere.app = "shop";
    elsewhere.app_address = "https://example.com/shop";
    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&elsewhere, visitors.SignUp, .{
        .user_type = "till_regular",
        .email = "bob@example.com",
        .display_name = "Bob",
    }));
}

test "a job follows an internal record's time: queued by its write, moved by an edit" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario);

    const job_queue = @import("../../store/job_queue.zig");
    const registry = @import("../registry.zig");
    const arena = scenario.harness.fixed.allocator();
    const now = scenario.ctx(.system).now_ms;
    const hour_ms: i64 = 60 * 60 * 1000;
    const document = try std.fmt.allocPrint(
        arena,
        "{{\"key\":\"r1\",\"count\":1,\"recount_at\":{d}}}",
        .{now + hour_ms},
    );
    const made = try scenario.call(admin, "internal.create", try move(&scenario, document));
    const Made = struct {
        id: []const u8,
    };
    const parsed = try std.json.parseFromSliceLeaky(Made, arena, made, .{
        .ignore_unknown_fields = true,
    });

    var worker = scenario.ctx(.system);
    const waiting = try job_queue.list(worker.db, worker.arena, 8);

    try std.testing.expectEqual(1, waiting.len);
    try std.testing.expectEqualStrings("recount", waiting[0].name);
    try std.testing.expectEqual(now + 2 * hour_ms, waiting[0].due_at);

    // Moved a day on: the run moves with it, once.
    const later = try std.fmt.allocPrint(arena, "{{\"recount_at\":{d}}}", .{now + 25 * hour_ms});

    _ = try scenario.call(admin, "internal.save", try save(arena, parsed.id, later));

    const moved = try job_queue.list(worker.db, worker.arena, 8);

    try std.testing.expectEqual(1, moved.len);
    try std.testing.expectEqual(now + 26 * hour_ms, moved[0].due_at);

    worker.now_ms = moved[0].due_at;
    try std.testing.expectEqual(1, try registry.SDK.jobs.drain(&worker, 8));
}

test "a plugin reads what a visitor brought, and answers the paths under its prefix" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario);

    const request_data = @import("../../sdk/request_data.zig");
    const registry = @import("../registry.zig");
    var door = scenario.ctx(.system);
    const visitor = "0123456789abcdef01234567";

    // Landing with the till's `ref` (and a tag nobody reads), then again with another.
    const tagged = "ref=ada&utm_source=news";

    try request_data.record(&door, visitor, "/tea", tagged, "https://a.example/");
    try request_data.record(&door, visitor, "/cups", "ref=bob", "");

    var calling = scenario.ctx(admin);

    calling.visitor = visitor;

    const seen = try registry.SDK.call_json(&calling, "till.seen", "{}");

    try std.testing.expectEqualStrings("{\"ref\":\"ada\"}", seen);

    // `/till/ada` is the till's to answer; `/tea` nobody's.
    const found = (try request_data.answering(&door, "/till/ada")).?;

    try std.testing.expectEqualStrings("till.follow", found.operation);
    try std.testing.expectEqualStrings("ada", found.rest);
    try std.testing.expect(try request_data.answering(&door, "/tea") == null);
}

/// `internal.create_many`'s input for till's moves: `documents`, a JSON array of records.
fn moves(scenario: *Scenario, comptime documents: []const u8) ![]const u8 {
    const arena = scenario.harness.fixed.allocator();

    std.debug.assert(documents.len > 0);

    const head = "{\"plugin\":\"till\",\"kind\":\"move\",\"documents\":";

    return arena.dupe(u8, head ++ documents ++ "}");
}

test "a record's rule runs once for a write of many, and only on its own kind of record" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario);
    _ = try scenarios_remotes.put(
        &scenario,
        "greeter.wasm",
        @embedFile("sandboxed_plugin_greeter"),
    );
    try scenarios_remotes.enable(&scenario, "greeter");

    const till = scenario.host.find_loaded("till").?;
    const before_two = till.entered;

    _ = try scenario.call(admin, "internal.create_many", try moves(
        &scenario,
        "[{\"key\":\"m1\",\"count\":1},{\"key\":\"m2\",\"count\":2}]",
    ));

    const for_two = till.entered - before_two;

    _ = try scenario.call(admin, "internal.create_many", try moves(
        &scenario,
        "[{\"key\":\"m3\",\"count\":1},{\"key\":\"m4\",\"count\":2}," ++
            "{\"key\":\"m5\",\"count\":3},{\"key\":\"m6\",\"count\":4}]",
    ));

    // Four records enter the plugin as often as two did: its rule hears them together.
    try std.testing.expect(for_two > 0);
    try std.testing.expectEqual(for_two, till.entered - before_two - for_two);

    // One of many that breaks the record's own rule refuses the write, all of it.
    try std.testing.expectError(error.Invalid, scenario.call(
        admin,
        "internal.create_many",
        try moves(&scenario, "[{\"key\":\"m7\",\"count\":1}," ++
            "{\"key\":\"m8\",\"count\":1,\"refund\":true}]"),
    ));

    const kept = try scenario.call(
        admin,
        "internal.find_one",
        "{\"plugin\":\"till\",\"kind\":\"move\",\"field\":\"key\",\"value\":\"m7\"}",
    );

    try std.testing.expect(std.mem.indexOf(u8, kept, "\"record\":null") != null);

    // Another plugin's record is none of till's: its write never starts till.
    const before_other = till.entered;

    _ = try scenario.call(
        admin,
        "internal.create",
        "{\"plugin\":\"greeter\",\"kind\":\"visit\"," ++
            "\"document\":{\"name\":\"Ada\",\"count\":1}}",
    );
    try std.testing.expectEqual(before_other, till.entered);

    // Records by id come in one read, in the order named, one that is not there left out.
    const found = try scenario.call(
        admin,
        "internal.find",
        "{\"plugin\":\"till\",\"kind\":\"move\",\"field\":\"key\",\"value\":\"m2\"}",
    );
    const Found = struct {
        records: []const struct {
            id: []const u8,
        },
    };
    const arena = scenario.harness.fixed.allocator();
    const second = (try std.json.parseFromSliceLeaky(Found, arena, found, .{
        .ignore_unknown_fields = true,
    })).records[0].id;
    const by_id = try scenario.call(admin, "internal.find", try std.fmt.allocPrint(
        arena,
        "{{\"plugin\":\"till\",\"kind\":\"move\",\"ids\":[\"nope\",\"{s}\"]," ++
            "\"fields\":[\"count\"]}}",
        .{second},
    ));

    try std.testing.expect(std.mem.indexOf(u8, by_id, "\"document\":{\"count\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, by_id, "\"key\"") == null);
}
