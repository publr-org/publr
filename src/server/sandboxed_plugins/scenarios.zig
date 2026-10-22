//! The sandbox end to end, on the test plugins (`testdata/`, built for
//! the sandbox by the build): added and enabled, called through the one
//! dispatch as different callers, its grants revoked and given back, removed.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../registry.zig");
const Host = @import("../sandboxed_plugins.zig").Host;
const plugin_operations = @import("../../operations/plugin.zig");
const user = @import("../../operations/user.zig");

const greeter_bytes = @embedFile("sandboxed_plugin_greeter");
const prices_bytes = @embedFile("sandboxed_plugin_prices");
const courier_bytes = @embedFile("sandboxed_plugin_courier");

pub const Scenario = struct {
    harness: sdk.testing.Harness,
    temporary: std.testing.TmpDir,
    host: Host,
    path: []const u8,

    pub fn init(scenario: *Scenario) !void {
        std.debug.assert(greeter_bytes.len > 0);

        try scenario.harness.init();
        errdefer scenario.harness.deinit();

        scenario.temporary = std.testing.tmpDir(.{});
        errdefer scenario.temporary.cleanup();

        try scenario.temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "greeter.wasm",
            .data = greeter_bytes,
        });

        const root = ".zig-cache/tmp/" ++ scenario.temporary.sub_path;

        scenario.path = try std.fmt.allocPrint(std.testing.allocator, "{s}/greeter.wasm", .{root});
        errdefer std.testing.allocator.free(scenario.path);

        const dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/plugins", .{root});
        defer std.testing.allocator.free(dir);

        try scenario.host.init(std.testing.allocator, std.testing.io, dir);

        var system = scenario.ctx(.system);

        try registry.SDK.bootstrap(&system);
        try user.seed_admin(&system);

        std.debug.assert(scenario.host.loaded.items.len == 0);
    }

    pub fn deinit(scenario: *Scenario) void {
        std.debug.assert(scenario.path.len > 0);

        scenario.host.deinit();
        std.testing.allocator.free(scenario.path);
        scenario.temporary.cleanup();
        scenario.harness.deinit();
    }

    pub fn ctx(scenario: *Scenario, who: sdk.Caller) sdk.Ctx {
        var made = scenario.harness.ctx(who);

        std.debug.assert(made.sandboxed_plugins == null);

        made.sandboxed_plugins = scenario.host.sandboxed_plugins();
        made.now_ms = 1_700_000_000_000;

        return made;
    }

    pub fn call(
        scenario: *Scenario,
        who: sdk.Caller,
        name: []const u8,
        input: []const u8,
    ) sdk.Error![]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(input.len > 0);

        var made = scenario.ctx(who);

        return registry.SDK.call_json(&made, name, input);
    }

    /// The `total` a greeter operation answers.
    fn total(scenario: *Scenario, who: sdk.Caller, name: []const u8, input: []const u8) !i64 {
        const answer = try scenario.call(who, name, input);
        const Total = struct {
            total: i64,
        };
        const arena = scenario.harness.fixed.allocator();
        const parsed = try std.json.parseFromSliceLeaky(Total, arena, answer, .{});

        std.debug.assert(parsed.total >= 0);

        return parsed.total;
    }

    /// Adds the fixture module as the local operator, then enables it.
    fn install(scenario: *Scenario) !plugin_operations.Detail {
        const added = try scenario.add(scenario.path);
        var enabling = scenario.ctx(.system);

        std.debug.assert(!added.update);

        const enabled = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
            .names = &.{added.name},
        });

        return enabled.plugins[0];
    }

    pub fn add(scenario: *Scenario, path: []const u8) !plugin_operations.Added {
        var system = scenario.ctx(.system);

        std.debug.assert(path.len > 0);

        return registry.SDK.dispatch(&system, plugin_operations.Add, .{
            .file = path,
        });
    }

    fn by_name(scenario: *Scenario, comptime Operation: type) !plugin_operations.Detail {
        var system = scenario.ctx(.system);

        return registry.SDK.dispatch(&system, Operation, .{
            .name = "greeter",
        });
    }
};

pub const admin: sdk.Caller = .{
    .user = .{
        .id = "u_admin",
        .roles = &.{"admin"},
    },
};
const editor: sdk.Caller = .{
    .user = .{
        .id = "u_editor",
        .roles = &.{"editor"},
    },
};
const nobody: sdk.Caller = .{
    .user = .{
        .id = "u_nobody",
        .roles = &.{},
    },
};
const greet = "greeter.greet";

test "installed, a plugin's operations run in the sandbox through the one dispatch" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const sandboxed = try scenario.install();

    try std.testing.expectEqualStrings("greeter", sandboxed.name);
    try std.testing.expectEqual(@as(usize, 6), sandboxed.operations.len);
    try std.testing.expectEqual(1, try scenario.total(admin, greet, "{\"note\":\"hi\"}"));
    try std.testing.expectEqual(2, try scenario.total(admin, greet, "{\"note\":\"again\"}"));
    try std.testing.expectEqual(2, try scenario.total(admin, "greeter.count", "{}"));

    // Its own role reaches its operations; no role, no call; nobody signed in, nothing.
    try std.testing.expectEqual(3, try scenario.total(editor, greet, "{\"note\":\"ed\"}"));
    try std.testing.expectError(error.Denied, scenario.call(nobody, greet, "{\"note\":\"no\"}"));
    try std.testing.expectError(error.Denied, scenario.call(.anonymous, "greeter.count", "{}"));

    // The plugin's own validation answers through the sandbox as any operation's would.
    try std.testing.expectError(error.Invalid, scenario.call(admin, greet, "{\"note\":\"\"}"));
    try std.testing.expectError(error.Invalid, scenario.call(admin, "greeter.greet", "{"));
    try std.testing.expectError(error.NotFound, scenario.call(admin, "greeter.nope", "{}"));

    // What the plugin itself does not find reaches the caller as not found, never as the
    // sandbox being unavailable.
    const nobody_note = "{\"note\":\"nobody\"}";

    try std.testing.expectError(error.NotFound, scenario.call(admin, greet, nobody_note));

    // The records it keeps are records like any other, of the type it declared.
    var system = scenario.ctx(.system);
    const records = @import("../../operations/record.zig");
    const listed = try registry.SDK.dispatch(&system, records.List, .{
        .type = "greeter.salutation",
    });

    try std.testing.expectEqual(@as(usize, 3), listed.records.len);
}

test "an installed plugin's hook on every transition of its type refuses one in the write" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();
    _ = try scenario.call(admin, greet, "{\"note\":\"keep\"}");
    _ = try scenario.call(admin, greet, "{\"note\":\"let go\"}");

    var people = scenario.ctx(admin);
    const records = @import("../../operations/record.zig");
    const listed = try registry.SDK.dispatch(&people, records.List, .{
        .type = "greeter.salutation",
        .order = .title_asc,
    });

    try std.testing.expectEqual(@as(usize, 2), listed.records.len);
    try std.testing.expectEqualStrings("keep", listed.records[0].title);

    const kept = registry.SDK.dispatch(&people, records.Transition, .{
        .id = listed.records[0].id,
        .transition = "trash",
    });

    try std.testing.expectError(error.Denied, kept);

    const let_go = try registry.SDK.dispatch(&people, records.Transition, .{
        .id = listed.records[1].id,
        .transition = "trash",
    });

    try std.testing.expectEqualStrings("trashed", let_go.status);

    const still = try registry.SDK.dispatch(&people, records.Get, .{
        .id = listed.records[0].id,
    });

    try std.testing.expect(!std.mem.eql(u8, still.record.status, "trashed"));

    // A hook on one transition alone: archiving is refused, by that hook only.
    const archived = registry.SDK.dispatch(&people, records.Transition, .{
        .id = listed.records[0].id,
        .transition = "archive",
    });

    try std.testing.expectError(error.Denied, archived);
}

test "an installed plugin's status joins another's flow; its records leave when it goes" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();
    try scenario.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "postcard.wasm",
        .data = @embedFile("sandboxed_plugin_postcard"),
    });

    const postcard = try std.mem.concat(std.testing.allocator, u8, &.{
        scenario.path[0 .. scenario.path.len - "greeter.wasm".len],
        "postcard.wasm",
    });
    defer std.testing.allocator.free(postcard);

    _ = try scenario.add(postcard);

    var enabling = scenario.ctx(.system);
    const enabled = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{"postcard"},
    });
    const asked = enabled.plugins[0].requests;
    const key = "status:postcard.posted";

    try std.testing.expectEqualStrings(key, asked[asked.len - 1].key);
    try std.testing.expectEqual(.granted, asked[asked.len - 1].state);

    _ = try scenario.call(admin, greet, "{\"note\":\"from afar\"}");

    const records = @import("../../operations/record.zig");
    var people = scenario.ctx(admin);
    const listed = try registry.SDK.dispatch(&people, records.List, .{
        .type = "greeter.salutation",
    });
    const id = listed.records[0].id;
    const posted = try registry.SDK.dispatch(&people, records.Transition, .{
        .id = id,
        .transition = "post",
    });

    try std.testing.expectEqualStrings("postcard.posted", posted.status);

    // Switched off: the salutation leaves by postcard's own way out, then the status goes.
    var revoking = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&revoking, plugin_operations.Revoke, .{
        .name = "postcard",
        .key = key,
    });

    people = scenario.ctx(admin);
    const delivered = try registry.SDK.dispatch(&people, records.Get, .{
        .id = id,
    });

    try std.testing.expectEqualStrings("published", delivered.record.status);

    const refused = registry.SDK.dispatch(&people, records.Transition, .{
        .id = id,
        .transition = "post",
    });

    try std.testing.expectError(error.Invalid, refused);

    // Back on, a second salutation posted, then postcard removed: it leaves the same way.
    var granting = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&granting, plugin_operations.GrantRequest, .{
        .name = "postcard",
        .key = key,
    });
    _ = try scenario.call(admin, greet, "{\"note\":\"again\"}");

    people = scenario.ctx(admin);
    const again = try registry.SDK.dispatch(&people, records.List, .{
        .type = "greeter.salutation",
        .filters = &.{"status:is:draft"},
    });
    const second = again.records[0].id;

    _ = try registry.SDK.dispatch(&people, records.Transition, .{
        .id = second,
        .transition = "post",
    });

    var removing = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&removing, plugin_operations.Remove, .{
        .name = "postcard",
    });

    people = scenario.ctx(admin);
    const out = try registry.SDK.dispatch(&people, records.Get, .{
        .id = second,
    });

    try std.testing.expectEqualStrings("published", out.record.status);
}

test "what an installed plugin logs goes with the call's entry and on its own log" {
    const activity = @import("../../operations/activity.zig");
    const errors = @import("../../operations/errors.zig");
    const plugin_log = @import("../../operations/plugin/log.zig");

    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();
    _ = try scenario.total(admin, greet, "{\"note\":\"hi\"}");
    const nobody_note = "{\"note\":\"nobody\"}";

    try std.testing.expectError(error.NotFound, scenario.call(admin, greet, nobody_note));

    var system = scenario.ctx(.system);
    const done = try registry.SDK.dispatch(&system, activity.List, .{
        .operation = greet,
    });

    try std.testing.expectEqual(@as(usize, 1), done.entries[0].lines.len);
    try std.testing.expectEqualStrings("Greeted with hi", done.entries[0].lines[0].line);
    try std.testing.expectEqualStrings("greeter", done.entries[0].lines[0].plugin);

    // The failed call rolled back; its line survives with its error entry.
    const failed = try registry.SDK.dispatch(&system, errors.List, .{
        .operation = greet,
    });

    try std.testing.expectEqualStrings("NotFound", failed.entries[0].@"error");
    try std.testing.expectEqualStrings("Nobody to greet", failed.entries[0].lines[0].line);
    try std.testing.expectEqualStrings("err", failed.entries[0].lines[0].level);

    const own = try registry.SDK.dispatch(&system, plugin_log.Log, .{
        .name = "greeter",
    });

    try std.testing.expectEqual(@as(usize, 2), own.lines.len);
    try std.testing.expectEqualStrings("Nobody to greet", own.lines[0].line);
    try std.testing.expectEqualStrings(greet, own.lines[1].call);
}

test "an installed plugin's on hook on an operation hears its answer from the queue" {
    const plugin_log = @import("../../operations/plugin/log.zig");

    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();
    _ = try scenario.total(admin, greet, "{\"note\":\"hi\"}");

    // Not inside the call: only the operation's own line, its hook's run waiting with the
    // answer.
    var system = scenario.ctx(.system);
    const before = try registry.SDK.dispatch(&system, plugin_log.Log, .{
        .name = "greeter",
    });

    try std.testing.expectEqual(@as(usize, 1), before.lines.len);

    var waiting = try system.db.prepare("SELECT input FROM job_queue WHERE name = ?1");
    defer waiting.finalize();
    try waiting.bind_text(1, "on:" ++ greet);
    try std.testing.expect(try waiting.step());

    const Waiting = struct {
        input: []const u8,
    };
    const row = try waiting.read(Waiting, scenario.harness.fixed.allocator());

    try std.testing.expectEqualStrings("{\"total\":1}", row.input);

    var worker = scenario.ctx(.system);
    _ = try registry.SDK.jobs.drain(&worker, 8);

    var reading = scenario.ctx(.system);
    const after = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "greeter",
    });

    try std.testing.expectEqual(@as(usize, 2), after.lines.len);
    try std.testing.expectEqualStrings("1 greetings in all", after.lines[0].line);
    try std.testing.expectEqualStrings("event:" ++ greet, after.lines[0].call);
}

test "a revoked permission answers denied on the next call, granted again it works" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();

    const people = try scenario.call(admin, "greeter.people", "{}");

    try std.testing.expect(std.mem.indexOf(u8, people, "hello, ") != null);

    var system = scenario.ctx(.system);
    const revoked = try registry.SDK.dispatch(&system, plugin_operations.Revoke, .{
        .name = "greeter",
        .key = "users.names",
    });

    const pending = plugin_operations.Request.State.pending;

    try std.testing.expectEqual(pending, revoked.requests[0].state);
    try std.testing.expectError(error.Denied, scenario.call(admin, "greeter.people", "{}"));

    var again = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&again, plugin_operations.GrantRequest, .{
        .name = "greeter",
        .key = "users.names",
    });
    _ = try scenario.call(admin, "greeter.people", "{}");

    // Acting for an account, the plugin gets the narrower of its grant and their roles.
    try std.testing.expectError(error.Denied, scenario.call(nobody, "greeter.people", "{}"));
}

test "a grant's flags: without .publish a plugin's write waits, with it it goes live" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try scenario.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "prices.wasm",
        .data = prices_bytes,
    });

    var system = scenario.ctx(.system);

    _ = try registry.SDK.dispatch(&system, @import("../../operations/content_type.zig").Create, .{
        .definition = "{\"handle\":\"note\",\"name\":\"Note\",\"public\":true," ++
            "\"fields\":[{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\"}]}",
    });

    const path = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        scenario.path,
        "greeter.wasm",
        "prices.wasm",
    );
    defer std.testing.allocator.free(path);

    const added = try scenario.add(path);
    var enabling = scenario.ctx(.system);
    const enabled = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{added.name},
        .grants = &.{.{
            .key = "records.write",
            .on = true,
            .publish = false,
        }},
    });

    try std.testing.expectEqual(model.permission.Tier.medium, enabled.plugins[0].requests[0].tier);
    try std.testing.expect(!enabled.plugins[0].requests[0].flags[0].on);

    const Posted = struct {
        status: []const u8,
        pending: bool,
        publish: bool,
    };
    const arena = scenario.harness.fixed.allocator();
    const waiting = try std.json.parseFromSliceLeaky(Posted, arena, try scenario.call(
        admin,
        "prices.post",
        "{\"title\":\"Apples\"}",
    ), .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expect(waiting.pending and !waiting.publish);
    try std.testing.expectEqualStrings("draft", waiting.status);

    var switching = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&switching, plugin_operations.SetGrant, .{
        .name = "prices",
        .key = "records.write",
        .publish = true,
    });

    const live = try std.json.parseFromSliceLeaky(Posted, arena, try scenario.call(
        admin,
        "prices.post",
        "{\"title\":\"Pears\"}",
    ), .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expect(!live.pending and live.publish);
    try std.testing.expectEqualStrings("published", live.status);

    var off = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&off, plugin_operations.SetGrant, .{
        .name = "prices",
        .key = "records.write",
        .on = false,
    });

    try std.testing.expectError(
        error.Denied,
        scenario.call(admin, "prices.post", "{\"title\":\"Plums\"}"),
    );
}

test "installing twice conflicts; removing unloads, keeps records, takes editors' grants" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();
    _ = try scenario.call(admin, "greeter.greet", "{\"note\":\"kept\"}");
    try std.testing.expectError(error.Conflict, scenario.install());

    var system = scenario.ctx(.system);
    const editors = [_][]const u8{"editor"};

    try std.testing.expect(sdk.stored_roles.allows(&system, &editors, greet));

    const listed = try registry.SDK.dispatch(&system, plugin_operations.List, .{});

    const built_in = registry.native_plugins.all.len;
    const greeter = listed.plugins[built_in];

    try std.testing.expectEqual(built_in + 1, listed.plugins.len);
    try std.testing.expectEqual(.sandboxed, greeter.mode);
    try std.testing.expectEqual(@as(u32, 0), greeter.pending);

    var removing = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&removing, plugin_operations.Remove, .{
        .name = "greeter",
    });

    try std.testing.expectError(error.NotFound, scenario.call(admin, greet, "{\"note\":\"x\"}"));
    try std.testing.expect(!sdk.stored_roles.allows(&system, &editors, greet));

    var reading = scenario.ctx(.system);
    const records = @import("../../operations/record.zig");
    const kept = try registry.SDK.dispatch(&reading, records.List, .{
        .type = "greeter.salutation",
    });

    try std.testing.expectEqual(@as(usize, 1), kept.records.len);
}

test "an update waits until applied; the version it replaced is kept to roll back to" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();
    try scenario.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "greeter-next.wasm",
        .data = @embedFile("sandboxed_plugin_greeter_next"),
    });

    const next = try std.mem.concat(std.testing.allocator, u8, &.{
        scenario.path[0 .. scenario.path.len - "greeter.wasm".len],
        "greeter-next.wasm",
    });
    defer std.testing.allocator.free(next);

    const added = try scenario.add(next);

    try std.testing.expect(added.update);
    try std.testing.expectEqual(1, try scenario.total(admin, greet, "{\"note\":\"still old\"}"));

    const updated = try scenario.by_name(plugin_operations.Update);

    try std.testing.expectEqualStrings("0.2.0", updated.version);
    try std.testing.expectEqualStrings("0.1.0", updated.previous.?);
    try std.testing.expect(updated.update == null);
    try std.testing.expectError(error.NotFound, scenario.call(admin, greet, "{}"));
    try std.testing.expectEqual(1, try scenario.total(admin, "greeter.count", "{}"));

    const rolled_back = try scenario.by_name(plugin_operations.Rollback);

    try std.testing.expectEqualStrings("0.1.0", rolled_back.version);
    try std.testing.expectEqualStrings("0.2.0", rolled_back.previous.?);
    try std.testing.expectEqual(2, try scenario.total(admin, greet, "{\"note\":\"back\"}"));
}

test "disabled, a plugin runs nothing and keeps its grants; enabled again, it runs" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();

    var stopping = scenario.ctx(.system);
    const partly = registry.SDK.dispatch(&stopping, plugin_operations.Disable, .{
        .names = &.{ "greeter", "missing" },
    });

    // All or none: the unknown second name leaves greeter running.
    try std.testing.expectError(error.NotFound, partly);
    try std.testing.expectEqual(0, try scenario.total(admin, "greeter.count", "{}"));

    stopping = scenario.ctx(.system);
    const stopped = try registry.SDK.dispatch(&stopping, plugin_operations.Disable, .{
        .names = &.{"greeter"},
    });

    try std.testing.expect(!stopped.plugins[0].enabled);
    try std.testing.expectError(error.NotFound, scenario.call(admin, "greeter.count", "{}"));

    var starting = scenario.ctx(.system);
    const started = try registry.SDK.dispatch(&starting, plugin_operations.Enable, .{
        .names = &.{"greeter"},
    });

    try std.testing.expect(started.plugins[0].enabled);
    try std.testing.expectEqual(0, try scenario.total(admin, "greeter.count", "{}"));
}

test "only administrators manage plugins; only the local operator adds from a path" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    var ed = scenario.ctx(editor);

    const listed = registry.SDK.dispatch(&ed, plugin_operations.List, .{});

    try std.testing.expectError(error.Denied, listed);

    var anonymous = scenario.ctx(.anonymous);
    const refused = registry.SDK.dispatch(&anonymous, plugin_operations.Add, .{
        .file = scenario.path,
    });

    try std.testing.expectError(error.Denied, refused);

    var administrator = scenario.ctx(admin);
    const not_operator = registry.SDK.dispatch(&administrator, plugin_operations.Add, .{
        .file = scenario.path,
    });

    try std.testing.expectError(error.Denied, not_operator);
}

test "every core operation is in the catalog, granted to all, own-records, or never" {
    const permission = model.permission;
    const admin_only = [_][]const u8{ "plugin", "custom_fields" };

    inline for (registry.SDK.operations) |Operation| {
        const name = Operation.name;
        const namespace = comptime sdk.operation.namespace(name);
        var listed = permission.contains(&permission.always, name) or
            permission.contains(&permission.never, name) or
            permission.contains(&permission.own_records, name);

        for (permission.core) |entry| {
            listed = listed or permission.contains(entry.operations, name);
        }

        for (admin_only) |reserved| {
            listed = listed or std.mem.eql(u8, namespace, reserved);
        }

        const plugin_owned = comptime !is_core(namespace);

        if (!listed and !plugin_owned) {
            std.debug.print("{s} is in no permission table\n", .{name});
        }

        try std.testing.expect(listed or plugin_owned);
    }
}

fn is_core(namespace: []const u8) bool {
    std.debug.assert(namespace.len > 0);

    const core = [_][]const u8{
        "heartbeat", "project", "custom_fields", "user",     "sign_on", "identity", "status",
        "role",      "record",  "content_type",  "taxonomy", "term",    "snapshot", "view",
        "plugin",
    };

    for (core) |name| {
        if (std.mem.eql(u8, name, namespace)) {
            return true;
        }
    }

    return false;
}

test "the admin reviews, installs, grants and removes a plugin through plain forms" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const admin_adapter = @import("../../adapters/admin.zig");
    var flow: admin_adapter.Flow = .{
        .inner = undefined,
    };

    flow.inner.init(.{
        .connection = &scenario.harness.fixture.connection,
        .auth = &scenario.harness.auth,
        .io = std.testing.io,
        .sandboxed_plugins = scenario.host.sandboxed_plugins(),
    }, arena_state.allocator());

    const credentials = "email=admin%40example.com&password=correct+horse+battery";
    const signed = try flow.call("POST", "/admin/login", credentials);

    try std.testing.expectEqual(@as(u16, 303), signed.status.code());
    _ = try scenario.add(scenario.path);

    const listed = try flow.call("GET", "/admin/settings/plugins", "");
    const page_path = "/admin/settings/plugins/greeter";

    try std.testing.expect(std.mem.indexOf(u8, listed.body, page_path ++ "/enable") != null);

    const review = try flow.call("GET", page_path ++ "/enable", "");

    try std.testing.expect(std.mem.indexOf(u8, review.body, "Allow &amp; Enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, review.body, "users.names") != null);

    const arena = flow.inner.arena;
    const csrf = flow.csrf_of(review.body);
    const enable_body = try std.fmt.allocPrint(arena, "csrf={s}", .{csrf});
    const enabled = try flow.call("POST", page_path ++ "/enable", enable_body);

    try std.testing.expectEqualStrings(page_path, enabled.header("Location").?);
    try std.testing.expectEqual(0, try scenario.total(admin, "greeter.count", "{}"));

    // Active, the list offers to stop it, not to enable it.
    const after = try flow.call("GET", "/admin/settings/plugins", "");

    try std.testing.expect(std.mem.indexOf(u8, after.body, page_path ++ "/enable") == null);
    try std.testing.expect(std.mem.indexOf(u8, after.body, page_path ++ "/disable") != null);

    // Its switch left off and saved: the key is denied, the next call answers so.
    const switched_off = try std.fmt.allocPrint(arena, "csrf={s}&keys=users.names", .{csrf});

    _ = try flow.call("POST", page_path ++ "/grants", switched_off);
    try std.testing.expectError(error.Denied, scenario.call(admin, "greeter.people", "{}"));

    const page = try flow.call("GET", page_path, "");

    try std.testing.expect(std.mem.indexOf(u8, page.body, "users.names") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "Low risk") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, ">Denied<") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "role=\"switch\"") != null);

    const switched_on = try std.fmt.allocPrint(
        arena,
        "csrf={s}&keys=users.names&on=users.names",
        .{csrf},
    );

    _ = try flow.call("POST", page_path ++ "/grants", switched_on);
    _ = try scenario.call(admin, "greeter.people", "{}");

    const remove_body = try std.fmt.allocPrint(arena, "csrf={s}", .{csrf});
    const removed = try flow.call("POST", page_path ++ "/remove", remove_body);

    try std.testing.expectEqualStrings("/admin/settings/plugins", removed.header("Location").?);
    try std.testing.expectError(error.NotFound, scenario.call(admin, "greeter.count", "{}"));
}

test "an upload arrives in pieces, in order, and is added with the last" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const encoder = std.base64.standard.Encoder;
    const split = 3000;
    const head = try std.testing.allocator.alloc(u8, encoder.calcSize(split));
    defer std.testing.allocator.free(head);
    const rest = greeter_bytes[split..];
    const tail = try std.testing.allocator.alloc(u8, encoder.calcSize(rest.len));
    defer std.testing.allocator.free(tail);

    _ = encoder.encode(head, greeter_bytes[0..split]);
    _ = encoder.encode(tail, rest);

    var system = scenario.ctx(.system);
    const first = try registry.SDK.dispatch(&system, plugin_operations.Upload, .{
        .file = "greeter.wasm",
        .data = head,
        .last = false,
    });

    try std.testing.expectEqual(@as(u64, split), first.received);
    try std.testing.expect(first.added == null);

    var skipping = scenario.ctx(.system);
    const skipped = registry.SDK.dispatch(&skipping, plugin_operations.Upload, .{
        .file = "greeter.wasm",
        .offset = split + 1,
        .data = tail,
    });

    try std.testing.expectError(error.Conflict, skipped);

    var finishing = scenario.ctx(.system);
    const done = try registry.SDK.dispatch(&finishing, plugin_operations.Upload, .{
        .file = "greeter.wasm",
        .offset = split,
        .data = tail,
    });

    try std.testing.expectEqualStrings("greeter", done.added.?.name);
    try std.testing.expect(!done.added.?.update);

    var sneaky = scenario.ctx(.system);
    const outside = registry.SDK.dispatch(&sneaky, plugin_operations.Upload, .{
        .file = "../escape.wasm",
        .data = head,
    });

    try std.testing.expectError(error.Invalid, outside);

    // A module that is no plugin is refused, and its upload is gone with it.
    var junk = scenario.ctx(.system);
    const refused = registry.SDK.dispatch(&junk, plugin_operations.Upload, .{
        .file = "empty.wasm",
        .data = "AGFzbQEAAAA=",
    });

    try std.testing.expectError(error.Invalid, refused);
}

test "a plugin that inserts at the front of a list keeps every entry" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try scenario.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "farewell.wasm",
        .data = @embedFile("sandboxed_plugin_farewell"),
    });

    const farewell = try std.mem.concat(std.testing.allocator, u8, &.{
        scenario.path[0 .. scenario.path.len - "greeter.wasm".len],
        "farewell.wasm",
    });
    defer std.testing.allocator.free(farewell);

    const added = try scenario.add(farewell);
    var enabling = scenario.ctx(.system);

    std.debug.assert(!added.update);
    _ = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{added.name},
    });

    // The rest move up with an overlapping copy: without `bulk_memory` the plugin build got
    // it wrong, and "carol, alice, alice" came back.
    const answer = try scenario.call(admin, "farewell.last", "{}");

    try std.testing.expect(std.mem.indexOf(u8, answer, "carol, alice, bob") != null);
}

/// Answers one request on `server` with a plain 200, whatever was asked.
fn answer_once(io: std.Io, server: *std.Io.net.Server) void {
    std.debug.assert(courier_bytes.len > 0);

    const stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    for (0..64) |_| {
        const line = reader.interface.takeDelimiterExclusive('\n') catch return;

        reader.interface.toss(1);

        if (line.len <= 1) {
            break;
        }
    }

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";

    writer.interface.writeAll(ok) catch return;
    writer.interface.flush() catch return;
}

/// `courier.send` to `url`, its job run as the worker runs it here (development), and the
/// newest two lines of its log: the job's own line, then the request's.
fn sent_out(scenario: *Scenario, url: []const u8) ![2][]const u8 {
    const plugin_log = @import("../../operations/plugin/log.zig");
    const arena = scenario.harness.fixed.allocator();
    const input = try std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{
        url,
    });

    std.debug.assert(url.len > 0);
    _ = try scenario.call(admin, "courier.send", input);

    var worker = scenario.ctx(.system);

    worker.outside.production = false;
    try std.testing.expectEqual(@as(u32, 1), try registry.SDK.jobs.drain(&worker, 8));

    var reading = scenario.ctx(.system);
    const log = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "courier",
    });

    try std.testing.expectEqualStrings("job:courier.deliver", log.lines[0].call);

    return .{ log.lines[0].line, log.lines[1].line };
}

test "outside calls go only to the grant's domains; a person adds and removes them" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try scenario.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "courier.wasm",
        .data = courier_bytes,
    });

    const gpa = std.testing.allocator;
    const path = try std.mem.replaceOwned(u8, gpa, scenario.path, "greeter", "courier");
    defer std.testing.allocator.free(path);

    const added = try scenario.add(path);
    var enabling = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{added.name},
        .grants = &.{.{
            .key = "http.fetch",
            .on = true,
        }},
    });

    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const url = try std.fmt.allocPrint(
        scenario.harness.fixed.allocator(),
        "http://localhost:{d}/ping?token=s3cret",
        .{server.socket.address.getPort()},
    );

    // `ctx.grant` answers the domains as granted: as asked, then as a person left them.
    try std.testing.expectEqualStrings(
        "{\"domains\":[\"api.example.com\"]}",
        try scenario.call(admin, "courier.reach", "{}"),
    );

    // Asked for api.example.com only: this machine is not on the grant.
    const unlisted = try sent_out(&scenario, url);

    try std.testing.expect(std.mem.startsWith(u8, unlisted[0], "Not delivered"));
    try std.testing.expect(std.mem.indexOf(u8, unlisted[1], "refused") != null);

    var adding = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&adding, plugin_operations.SetGrant, .{
        .name = "courier",
        .key = "http.fetch",
        .domains = &.{ "api.example.com", "localhost" },
    });

    try std.testing.expectEqualStrings(
        "{\"domains\":[\"api.example.com\",\"localhost\"]}",
        try scenario.call(admin, "courier.reach", "{}"),
    );

    const answering = try std.Thread.spawn(.{}, answer_once, .{ io, &server });
    const reached = try sent_out(&scenario, url);

    answering.join();
    try std.testing.expectEqualStrings("Delivered: 200", reached[0]);
    try std.testing.expect(std.mem.startsWith(u8, reached[1], "GET localhost/ping 200 ("));
    try std.testing.expect(std.mem.indexOf(u8, reached[1], "s3cret") == null);

    var removing = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&removing, plugin_operations.SetGrant, .{
        .name = "courier",
        .key = "http.fetch",
        .domains = &.{"api.example.com"},
    });

    const removed = try sent_out(&scenario, url);

    try std.testing.expect(std.mem.indexOf(u8, removed[1], "refused") != null);
}

const supplier_bytes = @embedFile("sandboxed_plugin_supplier");
const restock_bytes = @embedFile("sandboxed_plugin_restock");

/// Answers one request on `server`: 200 when it carries `Authorization: Bearer sk-shared`,
/// else 401.
fn answer_key(io: std.Io, server: *std.Io.net.Server) void {
    std.debug.assert(supplier_bytes.len > 0);

    const stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var keyed = false;

    for (0..64) |_| {
        const line = reader.interface.takeDelimiterExclusive('\n') catch return;

        reader.interface.toss(1);
        keyed = keyed or std.mem.startsWith(u8, line, "Authorization: Bearer sk-shared\r");

        if (line.len <= 1) {
            break;
        }
    }

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
    const refused = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

    writer.interface.writeAll(if (keyed) ok else refused) catch return;
    writer.interface.flush() catch return;
}

/// Answers one request: 200 when its path carries the key, `/botsk-shared/`, else 401.
fn answer_path(io: std.Io, server: *std.Io.net.Server) void {
    std.debug.assert(supplier_bytes.len > 0);

    const stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const first = reader.interface.takeDelimiterExclusive('\n') catch return;
    const keyed = std.mem.startsWith(u8, first, "GET /botsk-shared/prices ");

    for (0..64) |_| {
        reader.interface.toss(1);

        const line = reader.interface.takeDelimiterExclusive('\n') catch return;

        if (line.len <= 1) {
            break;
        }
    }

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
    const refused = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

    writer.interface.writeAll(if (keyed) ok else refused) catch return;
    writer.interface.flush() catch return;
}

/// `<plugin>.ask` with `input`, its job run as the worker runs it here, and the newest two
/// lines of its log: the job's own line, then the request's.
fn asked_out(scenario: *Scenario, plugin: []const u8, input: []const u8) ![2][]const u8 {
    const plugin_log = @import("../../operations/plugin/log.zig");
    const arena = scenario.harness.fixed.allocator();

    std.debug.assert(plugin.len > 0);
    _ = try scenario.call(admin, try std.fmt.allocPrint(arena, "{s}.ask", .{plugin}), input);

    var worker = scenario.ctx(.system);

    worker.outside.production = false;
    try std.testing.expectEqual(@as(u32, 1), try registry.SDK.jobs.drain(&worker, 8));

    var reading = scenario.ctx(.system);
    const log = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = plugin,
    });

    return .{ log.lines[0].line, log.lines[1].line };
}

/// Adds the test module `name` from its bytes and enables it, its `http.fetch` reaching
/// this machine.
fn enable_fetching(scenario: *Scenario, name: []const u8, bytes: []const u8) !void {
    const arena = scenario.harness.fixed.allocator();
    const file = try std.fmt.allocPrint(arena, "{s}.wasm", .{name});

    std.debug.assert(bytes.len > 0);
    try scenario.temporary.dir.writeFile(std.testing.io, .{
        .sub_path = file,
        .data = bytes,
    });

    const path = try std.mem.replaceOwned(u8, arena, scenario.path, "greeter.wasm", file);
    const added = try scenario.add(path);
    var enabling = scenario.ctx(.system);

    _ = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{added.name},
        .grants = &.{.{
            .key = "http.fetch",
            .on = true,
            .domains = &.{"localhost"},
        }},
    });
}

test "secrets: declared, not granted; refused unset or undeclared; one value, shared" {
    const Environment = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    // The project's key from the environment: the test database has no folder to keep it in.
    const key_set = Environment.setenv("PUBLR_SECRET_KEY", "11" ** 32, 1);

    try std.testing.expectEqual(@as(c_int, 0), key_set);
    defer _ = Environment.unsetenv("PUBLR_SECRET_KEY");

    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try enable_fetching(&scenario, "supplier", supplier_bytes);
    try enable_fetching(&scenario, "restock", restock_bytes);

    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const arena = scenario.harness.fixed.allocator();
    const port = server.socket.address.getPort();
    const input = try std.fmt.allocPrint(arena, "{{\"url\":\"http://localhost:{d}/prices\"}}", .{
        port,
    });

    // Enabled without a value: the request is refused in words, nothing leaves.
    const unset = try asked_out(&scenario, "supplier", input);

    try std.testing.expect(std.mem.startsWith(u8, unset[0], "Not sent"));
    try std.testing.expect(std.mem.endsWith(u8, unset[1], "refused: Supplier API key isn't set"));

    var system = scenario.ctx(.system);
    const missing = try registry.SDK.dispatch(&system, plugin_operations.Get, .{
        .name = "supplier",
    });

    try std.testing.expectEqual(@as(usize, 1), missing.secrets.len);
    try std.testing.expectEqualStrings("Supplier API key", missing.secrets[0].label);
    try std.testing.expect(!missing.secrets[0].set);

    // Set once, write-only: the answer names it and its users, never the value.
    const set = try scenario.call(
        admin,
        "secret.set",
        "{\"name\":\"SUPPLIER_API_KEY\",\"value\":\"sk-shared\"}",
    );

    try std.testing.expect(std.mem.indexOf(u8, set, "sk-shared") == null);
    try std.testing.expect(std.mem.indexOf(u8, set, "restock") != null);

    var reading = scenario.ctx(.system);
    const shared = try registry.SDK.dispatch(&reading, plugin_operations.Get, .{
        .name = "restock",
    });

    try std.testing.expect(shared.secrets[0].set);
    try std.testing.expectEqualStrings("supplier", shared.secrets[0].shared_with[0]);

    // One value, both plugins: each one's job reaches the server with it.
    for ([_][]const u8{ "supplier", "restock" }) |plugin| {
        const answering = try std.Thread.spawn(.{}, answer_key, .{ io, &server });
        const sent = try asked_out(&scenario, plugin, input);

        answering.join();
        try std.testing.expectEqualStrings("Answered: 200", sent[0]);
        try std.testing.expect(std.mem.indexOf(u8, sent[1], "sk-shared") == null);
    }

    // In the path too, as a bot token goes: filled as it leaves, the marker in the log.
    const in_path = try std.fmt.allocPrint(
        arena,
        "{{\"url\":\"http://localhost:{d}/bot{{secret:SUPPLIER_API_KEY}}/prices\"," ++
            "\"authorization\":\"\"}}",
        .{port},
    );
    const answering_path = try std.Thread.spawn(.{}, answer_path, .{ io, &server });
    const pathed = try asked_out(&scenario, "supplier", in_path);

    answering_path.join();
    try std.testing.expectEqualStrings("Answered: 200", pathed[0]);
    try std.testing.expect(std.mem.indexOf(u8, pathed[1], "sk-shared") == null);
    const marker = "/bot{secret:SUPPLIER_API_KEY}/";

    try std.testing.expect(std.mem.indexOf(u8, pathed[1], marker) != null);

    // A name it did not declare, made at run time (a literal would fail its build).
    const undeclared = try std.fmt.allocPrint(
        arena,
        "{{\"url\":\"http://localhost:{d}/prices\"," ++
            "\"authorization\":\"Bearer {{secret:OPENAI_API_KEY}}\"}}",
        .{port},
    );
    const refused = try asked_out(&scenario, "supplier", undeclared);

    try std.testing.expect(std.mem.indexOf(u8, refused[1], "does not declare") != null);
}
