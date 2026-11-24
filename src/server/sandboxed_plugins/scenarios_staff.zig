//! Staff and visitors are two ladders: a type of user gives visitor roles only, so signing up,
//! a plugin holding `users.own` and the roles editor never make an account staff.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../registry.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const visitors = @import("../../operations/user/visitors.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const till = @embedFile("sandboxed_plugin_till");

/// The account `email` as it signs in: its id and roles.
fn signed_in(scenario: *Scenario, email: []const u8) !sdk.Ctx {
    std.debug.assert(email.len > 0);

    const reading = scenario.ctx(.system);
    const account = (try store.users.find_by_email(reading.db, reading.arena, email)).?;

    return scenario.ctx(.{
        .user = .{
            .id = account.user.id,
            .roles = account.user.roles,
        },
    });
}

/// Whether `email`'s account reaches the admin or any of the staff operations named.
fn staff(scenario: *Scenario, email: []const u8) !bool {
    std.debug.assert(email.len > 0);

    const as_them = try signed_in(scenario, email);
    const staff_operations = [_][]const u8{
        "user.list",
        "user.update",
        "role.update",
        "record.create",
        "record.save",
        "content_type.create",
        "plugin.enable",
        "till.add",
    };

    if (registry.SDK.reaches_admin(&as_them)) {
        return true;
    }

    for (staff_operations) |name| {
        if (registry.SDK.may_named(&as_them, name)) {
            return true;
        }
    }

    return false;
}

test "staff ladder: a visitor who signs up to a type never reaches the admin" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "till.wasm", till);
    try scenarios_remotes.enable(&scenario, "till");

    var visiting = scenario.ctx(.anonymous);

    visiting.app = "www";
    visiting.app_address = "https://example.com";
    _ = try registry.SDK.dispatch(&visiting, visitors.SignUp, .{
        .user_type = "till_regular",
        .email = "ada@example.com",
        .display_name = "Ada",
    });

    try std.testing.expect(!try staff(&scenario, "ada@example.com"));

    // No administrator stepped in: the account holds exactly the type's roles.
    const reading = scenario.ctx(.system);
    const account = (try store.users.find_by_email(reading.db, reading.arena, "ada@example.com")).?;

    try std.testing.expectEqual(@as(usize, 1), account.user.roles.len);
    try std.testing.expectEqualStrings("till_regular", account.user.roles[0]);
}

test "staff ladder: a plugin holding users.own makes nobody staff" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "till.wasm", till);
    try scenarios_remotes.enable(&scenario, "till");

    // Its own regular, with the type's role: a visitor.
    _ = try scenario.call(admin, "till.add", "{\"email\":\"ada@example.com\"}");
    try std.testing.expect(!try staff(&scenario, "ada@example.com"));

    // A regular holding a staff role, or the type given with one: refused.
    try std.testing.expectError(error.Denied, scenario.call(
        admin,
        "till.add",
        "{\"email\":\"bob@example.com\",\"roles\":[\"editor\"]}",
    ));
    try std.testing.expectError(error.Denied, scenario.call(
        admin,
        "till.add",
        "{\"email\":\"eve@example.com\",\"roles\":[\"till_regular\",\"admin\"]}",
    ));
    try std.testing.expectError(error.Denied, scenario.call(
        admin,
        "till.join",
        "{\"email\":\"ada@example.com\",\"rename\":true}",
    ));
    try std.testing.expect(!try staff(&scenario, "ada@example.com"));

    const reading = scenario.ctx(.system);

    try std.testing.expect(try store.users.find_by_email(
        reading.db,
        reading.arena,
        "bob@example.com",
    ) == null);
}

test "staff ladder: a plugin whose type gives a staff role is refused at enable" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    // The site made `till_regular` a staff role before the till came: its type may not give it.
    _ = try scenario.call(admin, "role.create",
        \\{"name":"till_regular","label":"Regular","grants":["record.*"]}
    );
    _ = try scenarios_remotes.put(&scenario, "till.wasm", till);

    var enabling = scenario.ctx(.system);
    const Enable = @import("../../operations/plugin.zig").Enable;
    const refused = registry.SDK.dispatch(&enabling, Enable, .{
        .names = &.{"till"},
    });

    try std.testing.expectError(error.Failed, refused);
    try std.testing.expectEqualStrings("StaffRoleGiven", enabling.failure.?.name);
    try std.testing.expect(std.mem.indexOf(u8, enabling.failure.?.message, "till_regular") != null);

    // Taken back to what visitors call, the till comes on.
    _ = try scenario.call(admin, "role.update",
        \\{"name":"till_regular","label":"Regular","grants":[]}
    );
    try scenarios_remotes.enable(&scenario, "till");
}

test "staff ladder: the roles editor never makes a role a type gives staff" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "till.wasm", till);
    try scenarios_remotes.enable(&scenario, "till");
    _ = try scenario.call(admin, "till.add", "{\"email\":\"ada@example.com\"}");

    const staff_grants = [_][]const u8{
        \\{"name":"till_regular","label":"Regular","grants":["*"]}
        ,
        \\{"name":"till_regular","label":"Regular","grants":["record.*","!record.purge"]}
        ,
        \\{"name":"till_regular","label":"Regular","grants":["user.update"]}
        ,
        \\{"name":"till_regular","label":"Regular","grants":["till.add"]}
        ,
        \\{"name":"till_regular","label":"Regular","grants":["till.*"]}
        ,
    };

    for (staff_grants) |input| {
        var editing = scenario.ctx(admin);
        const refused = registry.SDK.call_json(&editing, "role.update", input);

        try std.testing.expectError(error.Failed, refused);
        try std.testing.expectEqualStrings("GivenByType", editing.failure.?.name);
        try std.testing.expect(std.mem.indexOf(u8, editing.failure.?.message, "Regular") != null);
    }

    try std.testing.expect(!try staff(&scenario, "ada@example.com"));

    // What visitors call stays theirs to be given: an app's operation, or what apps call.
    _ = try scenario.call(admin, "role.update",
        \\{"name":"till_regular","label":"Regular","grants":["app.till.*","till.seen"]}
    );
    try std.testing.expect(!try staff(&scenario, "ada@example.com"));

    // A new role copying a staff one is the site's own: a type gives none of it.
    _ = try scenario.call(admin, "role.create",
        \\{"name":"till_lead","label":"Lead","copy":"editor"}
    );
}

const porch = @embedFile("sandboxed_plugin_porch");

/// A visitor signing up to `porch_guest` on `www`.
fn sign_up(scenario: *Scenario, email: []const u8) sdk.Error!visitors.Sent {
    std.debug.assert(email.len > 0);

    var visiting = scenario.ctx(.anonymous);

    visiting.app = "www";
    visiting.app_address = "https://example.com";

    return registry.SDK.dispatch(&visiting, visitors.SignUp, .{
        .user_type = "porch_guest",
        .email = email,
        .display_name = "Guest",
    });
}

test "staff ladder: a type naming a role staff now gives nothing, and the admin says why" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "porch.wasm", porch);
    try scenarios_remotes.enable(&scenario, "porch");

    // As a site built before the rule finds it: the type's role reaches a staff operation.
    const writing = scenario.ctx(.system);

    try store.role_grants.set(writing.db, "porch_guest", &.{"user.list"});

    try std.testing.expectError(error.Invalid, sign_up(&scenario, "ada@example.com"));
    try std.testing.expectError(error.Denied, scenario.call(admin, "user.add_type",
        \\{"user":"admin@example.com","user_type":"porch_guest"}
    ));

    const listed = try scenario.call(admin, "user_type.list", "{}");
    const plugin = try scenario.call(admin, "plugin.get", "{\"name\":\"porch\"}");

    try std.testing.expect(std.mem.indexOf(u8, listed, "\"refused_role\":\"porch_guest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "Its type Guest gives nothing") != null);

    // Its staff grant taken back, it gives again.
    try store.role_grants.set(writing.db, "porch_guest", &.{});
    _ = try sign_up(&scenario, "ada@example.com");
    try std.testing.expect(!try staff(&scenario, "ada@example.com"));
}

test "staff ladder: an update taking an operation from visitors drops its grant" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "porch.wasm", porch);
    try scenarios_remotes.enable(&scenario, "porch");
    _ = try scenario.call(admin, "role.update",
        \\{"name":"porch_guest","label":"Guest","grants":["porch.knock","porch.ring"]}
    );
    _ = try sign_up(&scenario, "ada@example.com");

    // 0.2.0 keeps knocking for staff: the type's role loses it, keeps ringing.
    const next = @embedFile("sandboxed_plugin_porch_next");

    _ = try scenarios_remotes.put(&scenario, "porch-next.wasm", next);

    var updating = scenario.ctx(.system);

    _ = try registry.SDK.dispatch(&updating, @import("../../operations/plugin.zig").Update, .{
        .name = "porch",
    });

    const role = try scenario.call(admin, "role.get", "{\"name\":\"porch_guest\"}");

    try std.testing.expect(std.mem.indexOf(u8, role, "\"grants\":[\"porch.ring\"]") != null);
    try std.testing.expect(!try staff(&scenario, "ada@example.com"));
    _ = try sign_up(&scenario, "bob@example.com");
}

test "staff ladder: an account made with a type holds its roles only, staff when named" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "till.wasm", till);
    try scenarios_remotes.enable(&scenario, "till");

    // No roles named: the type's roles and nothing else, never the default `editor`.
    const made = try scenario.call(admin, "user.create",
        \\{"email":"ada@example.com","display_name":"Ada",
        \\ "password":"correct horse battery","user_type":"till_regular"}
    );

    try std.testing.expect(std.mem.indexOf(u8, made, "\"roles\":[\"till_regular\"]") != null);
    try std.testing.expect(!try staff(&scenario, "ada@example.com"));

    // A staff role only when the administrator names it; the type's roles join it.
    const named = try scenario.call(admin, "user.create",
        \\{"email":"bob@example.com","display_name":"Bob","roles":["editor"],
        \\ "password":"correct horse battery","user_type":"till_regular"}
    );

    const both = "\"roles\":[\"editor\",\"till_regular\"]";

    try std.testing.expect(std.mem.indexOf(u8, named, both) != null);
    try std.testing.expect(try staff(&scenario, "bob@example.com"));

    // No roles and no type: no role at all. The account can call nothing and reaches no
    // admin until an administrator gives it one.
    const plain = try scenario.call(admin, "user.create",
        \\{"email":"cy@example.com","display_name":"Cy","password":"correct horse battery"}
    );

    try std.testing.expect(std.mem.indexOf(u8, plain, "\"roles\":[]") != null);
    try std.testing.expect(!try staff(&scenario, "cy@example.com"));

    const as_cy = try signed_in(&scenario, "cy@example.com");

    try std.testing.expectEqual(@as(usize, 0), as_cy.caller.user.roles.len);
    try std.testing.expect(!registry.SDK.may_named(&as_cy, "media.list"));
    try std.testing.expect(!registry.SDK.may_named(&as_cy, "record.create"));
}
