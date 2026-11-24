//! The core ledger through installed plugins: `points` moves its own accounts and meets every
//! refusal by name; `kiosk` hands its cash to `points pay` and reads points' accounts under
//! its `ledger.read` grant; a hold's expiry runs as core's queued job on a test clock.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const queued_jobs = @import("../queued_jobs.zig");
const clock = @import("../../operations/clock.zig");
const identity = @import("../../adapters/rest/identity.zig");

const Scenario = scenarios.Scenario;
const Project = @import("../project.zig").Project;
const admin = scenarios.admin;

const Acted = struct {
    failure: []const u8,
    transfer: []const u8,
    amount: i64,
    made: bool,
    posted: i64,
    available: i64,
    account: []const u8,
    notes: u32,
};

fn installed(scenario: *Scenario, kiosk: bool) !void {
    _ = try scenarios_remotes.put(scenario, "points.wasm", @embedFile("sandboxed_plugin_points"));
    try scenarios_remotes.enable(scenario, "points");

    if (kiosk) {
        _ = try scenarios_remotes.put(scenario, "kiosk.wasm", @embedFile("sandboxed_plugin_kiosk"));
        try scenarios_remotes.enable(scenario, "kiosk");
    }

    std.debug.assert(scenario.path.len > 0);
}

/// `points act` with `input`; its answer read.
fn act(scenario: *Scenario, input: []const u8) !Acted {
    const arena = scenario.harness.fixed.allocator();
    const answer = try scenario.call(admin, "points.act", input);

    std.debug.assert(input.len > 0);

    return std.json.parseFromSliceLeaky(Acted, arena, answer, .{});
}

fn expect_refused(scenario: *Scenario, input: []const u8, refusal: []const u8) !void {
    const acted = try act(scenario, input);

    std.debug.assert(refusal.len > 0);

    try std.testing.expectEqualStrings(refusal, acted.failure);
    try std.testing.expect(!acted.made);
}

test "the ledger moves a plugin's own accounts, answers retries, refuses by name" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario, false);

    const earned = try act(&scenario, "{\"action\":\"earn\",\"id\":\"e1\",\"amount\":1000}");

    try std.testing.expect(earned.made);
    try std.testing.expectEqual(@as(i64, 1000), earned.posted);

    // The same id again answers the first; anything different is refused.
    const again = try act(&scenario, "{\"action\":\"earn\",\"id\":\"e1\",\"amount\":1000}");

    try std.testing.expect(!again.made);
    try std.testing.expectEqualStrings(earned.transfer, again.transfer);
    try std.testing.expectEqual(@as(i64, 1000), again.posted);
    try expect_refused(&scenario, "{\"action\":\"earn\",\"id\":\"e1\",\"amount\":999}", "Taken");

    // Never below zero: refused, or with up_to as much as there is.
    const spend = "{\"action\":\"spend\",\"id\":\"s1\",\"amount\":5000}";

    try expect_refused(&scenario, spend, "Overdrawn");

    const up_to = try act(&scenario, "{\"action\":\"spend\",\"id\":\"s2\",\"amount\":5000," ++
        "\"minutes\":1}");

    try std.testing.expectEqual(@as(i64, 1000), up_to.amount);
    try std.testing.expectEqual(@as(i64, 0), up_to.posted);
    _ = try act(&scenario, "{\"action\":\"earn\",\"id\":\"e2\",\"amount\":1000}");

    try holds(&scenario);
    try others(&scenario);

    var reading = scenario.ctx(admin);
    const checked = try registry.SDK.call_json(&reading, "ledger.check", "{}");

    try std.testing.expect(std.mem.indexOf(u8, checked, "\"in_balance\":true") != null);
    try unbalanced(&scenario);
}

/// A total changed behind the ledger's back (only a bug can) is found by the check: its unit
/// out of balance by the difference, its account named. An account nobody opened is none.
fn unbalanced(scenario: *Scenario) !void {
    var missing = scenario.ctx(admin);

    try std.testing.expectError(error.Failed, registry.SDK.call_json(
        &missing,
        "ledger.balance",
        "{\"account\":\"0190c8a3d2e1000014f2a6b9\"}",
    ));
    try std.testing.expectEqualStrings("NoAccount", missing.failure.?.name);

    try scenario.harness.fixture.connection.exec("UPDATE ledger_accounts SET debits_posted = " ++
        "debits_posted + 7 WHERE unit = 'points.points' AND name = 'held'");

    var reading = scenario.ctx(admin);
    const checked = try registry.SDK.call_json(&reading, "ledger.check", "{}");

    std.debug.assert(checked.len > 0);

    try std.testing.expect(std.mem.indexOf(u8, checked, "\"in_balance\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, checked, "\"difference\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, checked, "\"accounts\":[{\"account\"") != null);
}

fn holds(scenario: *Scenario) !void {
    const held = try act(scenario, "{\"action\":\"hold\",\"id\":\"h1\",\"amount\":400}");

    std.debug.assert(held.made);

    try std.testing.expectEqual(@as(i64, 1000), held.posted);
    try std.testing.expectEqual(@as(i64, 600), held.available);
    try expect_refused(scenario, "{\"action\":\"post\",\"id\":\"h1\",\"amount\":500}", "OverHold");

    const posted = try act(scenario, "{\"action\":\"post\",\"id\":\"h1\",\"amount\":300}");

    try std.testing.expectEqual(@as(i64, 700), posted.posted);
    try std.testing.expectEqual(@as(i64, 700), posted.available);

    const reposted = try act(scenario, "{\"action\":\"post\",\"id\":\"h1\",\"amount\":300}");

    try std.testing.expect(!reposted.made);
    try std.testing.expectEqualStrings(posted.transfer, reposted.transfer);
    try expect_refused(scenario, "{\"action\":\"void\",\"id\":\"h1\"}", "Settled");

    _ = try act(scenario, "{\"action\":\"hold\",\"id\":\"h2\",\"amount\":100,\"minutes\":30}");

    const voided = try act(scenario, "{\"action\":\"void\",\"id\":\"h2\"}");

    try std.testing.expect(voided.made);
    try std.testing.expectEqual(@as(i64, 700), voided.available);
    try std.testing.expect(!(try act(scenario, "{\"action\":\"void\",\"id\":\"h2\"}")).made);
    try expect_refused(scenario, "{\"action\":\"post\",\"id\":\"h2\"}", "Settled");
    try expect_refused(scenario, "{\"action\":\"post\",\"id\":\"nothing\"}", "NoHold");
}

fn others(scenario: *Scenario) !void {
    const arena = scenario.harness.fixed.allocator();
    const earned = try act(scenario, "{\"action\":\"earn\",\"id\":\"e3\",\"amount\":600}");

    std.debug.assert(earned.made);

    const reverse = try std.fmt.allocPrint(arena, "{{\"action\":\"reverse\",\"id\":\"r1\"," ++
        "\"amount\":200,\"target\":\"{s}\"}}", .{earned.transfer});
    const reversed = try act(scenario, reverse);

    try std.testing.expectEqual(@as(i64, 1100), reversed.posted);

    const over = try std.fmt.allocPrint(arena, "{{\"action\":\"reverse\",\"id\":\"r2\"," ++
        "\"amount\":500,\"target\":\"{s}\"}}", .{earned.transfer});

    try expect_refused(scenario, over, "OverReversed");
    try expect_refused(scenario, "{\"action\":\"mismatch\",\"id\":\"m1\"}", "UnitMismatch");
    try expect_refused(scenario, "{\"action\":\"unbalanced\",\"id\":\"u1\"}", "Unbalanced");
    try expect_refused(scenario, "{\"action\":\"huge\",\"id\":\"x1\"}", "TooLarge");

    _ = try act(scenario, "{\"action\":\"close\"}");
    try expect_refused(scenario, "{\"action\":\"earn\",\"id\":\"e4\",\"amount\":1}", "Closed");
    _ = try act(scenario, "{\"action\":\"reopen\"}");

    // 100 points at 0.015 PLN a point: 1.50 PLN in the member's wallet.
    const swapped = try act(scenario, "{\"action\":\"convert\",\"id\":\"c1\",\"amount\":100}");

    try std.testing.expectEqual(@as(i64, 150), swapped.amount);
    try std.testing.expectEqual(@as(i64, 1000), swapped.posted);
}

test "a refused chain takes the plugin's records back with it; caught, only itself" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario, false);
    _ = try act(&scenario, "{\"action\":\"earn\",\"id\":\"e1\",\"amount\":100}");

    var refused = scenario.ctx(admin);
    const input = "{\"action\":\"chain_fail\",\"id\":\"cf\",\"amount\":100}";

    try std.testing.expectError(
        error.Failed,
        registry.SDK.call_json(&refused, "points.act", input),
    );
    try std.testing.expectEqualStrings("Overdrawn", refused.failure.?.name);

    // Uncaught: the note and the chain's first transfer went with the call.
    const after = try act(&scenario, "{\"action\":\"balance\",\"id\":\"cf\"}");

    try std.testing.expectEqual(@as(i64, 100), after.posted);
    try std.testing.expectEqual(@as(u32, 0), after.notes);

    // Caught: the chain undid itself, the note the plugin kept stays.
    const caught = try act(&scenario, "{\"action\":\"chain_caught\",\"id\":\"cc\",\"amount\":100}");

    try std.testing.expectEqualStrings("Overdrawn", caught.failure);
    try std.testing.expectEqual(@as(i64, 100), caught.posted);
    try std.testing.expectEqual(@as(u32, 1), caught.notes);
}

test "a plugin moves another's account only when handed it; reads follow ledger.read" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario, true);

    const arena = scenario.harness.fixed.allocator();
    const Bought = struct {
        transfer: []const u8,
        made_for: []const u8,
        cash: i64,
    };
    const answer = try scenario.call(admin, "kiosk.buy", "{\"id\":\"sale-1\",\"amount\":100}");
    const bought = try std.json.parseFromSliceLeaky(Bought, arena, answer, .{});

    try std.testing.expectEqualStrings("kiosk", bought.made_for);
    try std.testing.expectEqual(@as(i64, 0), bought.cash);

    const member = try act(&scenario, "{\"action\":\"earn\",\"id\":\"e1\",\"amount\":50}");
    const target = try std.fmt.allocPrint(arena, "{{\"account\":\"{s}\"}}", .{member.account});
    const raided = try scenario.call(admin, "kiosk.raid", target);
    const peeked = try scenario.call(admin, "kiosk.peek", target);

    try std.testing.expect(std.mem.indexOf(u8, raided, "\"failure\":\"NotYours\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, peeked, "\"posted\":50") != null);

    // Points reads none of kiosk's, and moves it only inside the call kiosk made.
    const shown = try scenario.call(admin, "ledger.get", try std.fmt.allocPrint(
        arena,
        "{{\"transfer\":\"{s}\"}}",
        .{bought.transfer},
    ));
    const Shown = struct {
        credit: []const u8,
    };
    const cash = (try std.json.parseFromSliceLeaky(Shown, arena, shown, .{
        .ignore_unknown_fields = true,
    })).credit;
    const move = try std.fmt.allocPrint(arena, "{{\"action\":\"move_other\",\"id\":\"o1\"," ++
        "\"target\":\"{s}\"}}", .{cash});
    const read = try std.fmt.allocPrint(arena, "{{\"action\":\"read_other\"," ++
        "\"target\":\"{s}\"}}", .{cash});

    try expect_refused(&scenario, move, "NotYours");
    try expect_refused(&scenario, read, "NotYours");

    // People never write: the ledger's writes are plugin code's.
    try std.testing.expectError(
        error.Denied,
        scenario.call(admin, "ledger.open", "{\"name\":\"held\",\"unit\":\"PLN\"}"),
    );
}

test "a hold's expiry voids it once the clock passes it; posting it then is refused" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario, false);

    var project: Project = .{
        .connection = &scenario.harness.fixture.connection,
        .auth = &scenario.harness.auth,
        .io = std.testing.io,
        .sandboxed_plugins = scenario.host.sandboxed_plugins(),
    };

    project.outside.production = false;

    const arena = scenario.harness.fixed.allocator();
    var system = identity.context(&project, arena, .system);

    _ = try registry.SDK.dispatch(&system, clock.SetClock, .{
        .ahead_ms = 0,
    });

    var acting = identity.context(&project, arena, admin);

    _ = try registry.SDK.call_json(&acting, "points.act", "{\"action\":\"earn\",\"id\":\"e1\"," ++
        "\"amount\":100}");
    _ = try registry.SDK.call_json(&acting, "points.act", "{\"action\":\"hold\",\"id\":\"h1\"," ++
        "\"amount\":60,\"minutes\":30}");

    var later = identity.context(&project, arena, .system);

    _ = try registry.SDK.dispatch(&later, clock.SetClock, .{
        .ahead_ms = 31 * 60 * 1000,
    });

    var ticks: queued_jobs.Clock = .{};

    queued_jobs.tick(&project, std.testing.allocator, &ticks, project.now_ms());

    var after = identity.context(&project, arena, admin);
    const answer = try registry.SDK.call_json(&after, "points.act", "{\"action\":\"post\"," ++
        "\"id\":\"h1\"}");
    const acted = try std.json.parseFromSliceLeaky(Acted, arena, answer, .{});

    try std.testing.expectEqualStrings("Expired", acted.failure);
    try std.testing.expectEqual(@as(i64, 100), acted.available);

    var reading = identity.context(&project, arena, admin);
    const checked = try registry.SDK.call_json(&reading, "ledger.check", "{}");

    try std.testing.expect(std.mem.indexOf(u8, checked, "\"in_balance\":true") != null);
}

test "transfers are found by name and reason a page at a time; sums are added up, none read" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try installed(&scenario, false);

    for ([_][]const u8{ "e1", "e2", "e3" }) |id| {
        const input = try std.fmt.allocPrint(
            scenario.harness.fixed.allocator(),
            "{{\"action\":\"earn\",\"id\":\"{s}\",\"amount\":100}}",
            .{id},
        );

        _ = try act(&scenario, input);
    }

    _ = try act(&scenario, "{\"action\":\"spend\",\"id\":\"s1\",\"amount\":30}");

    const Found = struct {
        transfers: []const struct {
            transfer: []const u8,
            reason: []const u8,
            amount: i64,
        },
        next: []const u8,
    };
    const arena = scenario.harness.fixed.allocator();
    const options: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
    };
    var reading = scenario.ctx(admin);
    const named = "{\"name\":\"held\",\"plugin\":\"points\",";
    const first = try std.json.parseFromSliceLeaky(Found, arena, try registry.SDK.call_json(
        &reading,
        "ledger.find",
        named ++ "\"reason\":\"earned\",\"limit\":2}",
    ), options);

    try std.testing.expectEqual(@as(usize, 2), first.transfers.len);
    try std.testing.expect(first.next.len > 0);

    const rest_input = try std.fmt.allocPrint(
        arena,
        "{s}\"reason\":\"earned\",\"limit\":2,\"after\":\"{s}\"}}",
        .{ named, first.next },
    );
    const rest = try std.json.parseFromSliceLeaky(Found, arena, try registry.SDK.call_json(
        &reading,
        "ledger.find",
        rest_input,
    ), options);

    try std.testing.expectEqual(@as(usize, 1), rest.transfers.len);
    try std.testing.expectEqualStrings("", rest.next);

    const newest = try std.json.parseFromSliceLeaky(Found, arena, try registry.SDK.call_json(
        &reading,
        "ledger.find",
        named ++ "\"newest\":true,\"limit\":1}",
    ), options);

    try std.testing.expectEqualStrings("spent", newest.transfers[0].reason);
    try std.testing.expectEqual(@as(i64, 30), newest.transfers[0].amount);

    // Nothing to read by, a page past 200, a name with no owner: refused.
    for ([_][]const u8{ "{}", "{\"reason\":\"earned\"}", named ++ "\"limit\":201}" }) |bad| {
        try std.testing.expectError(error.Invalid, registry.SDK.call_json(
            &reading,
            "ledger.find",
            bad,
        ));
    }

    const totals = try registry.SDK.call_json(&reading, "ledger.totals", named ++
        "\"reason\":\"earned\"}");

    try std.testing.expect(std.mem.indexOf(u8, totals, "\"credits_posted\":300") != null);
    try std.testing.expect(std.mem.indexOf(u8, totals, "\"spent\"") == null);
}
