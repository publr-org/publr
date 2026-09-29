//! The sandbox end to end, on the fixture plugins (`fixtures/sandboxed-plugins/`, built for
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

const Scenario = struct {
    harness: sdk.testing.Harness,
    temporary: std.testing.TmpDir,
    host: Host,
    path: []const u8,

    fn init(scenario: *Scenario) !void {
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

    fn deinit(scenario: *Scenario) void {
        std.debug.assert(scenario.path.len > 0);

        scenario.host.deinit();
        std.testing.allocator.free(scenario.path);
        scenario.temporary.cleanup();
        scenario.harness.deinit();
    }

    fn ctx(scenario: *Scenario, who: sdk.Caller) sdk.Ctx {
        var made = scenario.harness.ctx(who);

        std.debug.assert(made.sandboxed_plugins == null);

        made.sandboxed_plugins = scenario.host.sandboxed_plugins();
        made.now_ms = 1_700_000_000_000;

        return made;
    }

    fn call(
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
        const Total = struct { total: i64 };
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

        return registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
            .name = added.name,
        });
    }

    fn add(scenario: *Scenario, path: []const u8) !plugin_operations.Added {
        var system = scenario.ctx(.system);

        std.debug.assert(path.len > 0);

        return registry.SDK.dispatch(&system, plugin_operations.Add, .{ .file = path });
    }

    fn by_name(scenario: *Scenario, comptime Operation: type) !plugin_operations.Detail {
        var system = scenario.ctx(.system);

        return registry.SDK.dispatch(&system, Operation, .{ .name = "greeter" });
    }
};

const admin: sdk.Caller = .{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } };
const editor: sdk.Caller = .{ .user = .{ .id = "u_editor", .roles = &.{"editor"} } };
const nobody: sdk.Caller = .{ .user = .{ .id = "u_nobody", .roles = &.{} } };
const greet = "greeter.greet";

test "installed, a plugin's operations run in the sandbox through the one dispatch" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const sandboxed = try scenario.install();

    try std.testing.expectEqualStrings("greeter", sandboxed.name);
    try std.testing.expectEqual(@as(usize, 3), sandboxed.operations.len);
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
    const listed = try registry.SDK.dispatch(&system, records.List, .{ .type = "salutation" });

    try std.testing.expectEqual(@as(usize, 3), listed.records.len);
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

test "installing twice conflicts; removing unloads its operations and keeps its records" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.install();
    _ = try scenario.call(admin, "greeter.greet", "{\"note\":\"kept\"}");
    try std.testing.expectError(error.Conflict, scenario.install());

    var system = scenario.ctx(.system);
    const listed = try registry.SDK.dispatch(&system, plugin_operations.List, .{});

    const built_in = registry.native_plugins.all.len;
    const greeter = listed.plugins[built_in];

    try std.testing.expectEqual(built_in + 1, listed.plugins.len);
    try std.testing.expectEqual(.sandboxed, greeter.mode);
    try std.testing.expectEqual(@as(u32, 0), greeter.pending);

    var removing = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&removing, plugin_operations.Remove, .{ .name = "greeter" });

    try std.testing.expectError(error.NotFound, scenario.call(admin, greet, "{\"note\":\"x\"}"));

    var reading = scenario.ctx(.system);
    const records = @import("../../operations/record.zig");
    const kept = try registry.SDK.dispatch(&reading, records.List, .{ .type = "salutation" });

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

    const stopped = try scenario.by_name(plugin_operations.Disable);

    try std.testing.expect(!stopped.enabled);
    try std.testing.expectError(error.NotFound, scenario.call(admin, "greeter.count", "{}"));

    const started = try scenario.by_name(plugin_operations.Enable);

    try std.testing.expect(started.enabled);
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
    var flow: admin_adapter.Flow = .{ .inner = undefined };

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

    const decide_body = try std.fmt.allocPrint(
        arena,
        "csrf={s}&key=users.names&change=revoke",
        .{csrf},
    );

    _ = try flow.call("POST", page_path ++ "/decide", decide_body);
    try std.testing.expectError(error.Denied, scenario.call(admin, "greeter.people", "{}"));

    const page = try flow.call("GET", page_path, "");

    try std.testing.expect(std.mem.indexOf(u8, page.body, "greeter.people") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, ">Grant<") != null);

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
    _ = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{ .name = added.name });

    // The rest move up with an overlapping copy: without `bulk_memory` the plugin build got
    // it wrong, and "carol, alice, alice" came back.
    const answer = try scenario.call(admin, "farewell.last", "{}");

    try std.testing.expect(std.mem.indexOf(u8, answer, "carol, alice, bob") != null);
}
