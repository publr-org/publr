const std = @import("std");
const registry = @import("../registry.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const user_types = @import("../../sdk/user_types.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;

const order_type =
    \\{"handle":"order","name":"Order","title_field":"title","fields":[
    \\ {"name":"title","label":"Title","kind":"string"},
    \\ {"name":"sent_by","label":"Sent by","kind":"provider",
    \\  "options":{"provider":{"contract":"messaging"}}}]}
;

/// `record.create`'s input for an order sent by `provider`.
fn order_with(comptime provider: []const u8) []const u8 {
    return "{\"type\":\"order\",\"document\":" ++
        "{\"title\":\"A\",\"sent_by\":\"" ++ provider ++ "\"}}";
}

test "a provider field names a registered provider, and keeps one removed since" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const postcard = @embedFile("sandboxed_plugin_postcard");

    _ = try scenarios_remotes.put(&scenario, "postcard.wasm", postcard);
    try scenarios_remotes.enable(&scenario, "postcard");

    const definition = "{\"definition\":" ++ order_type ++ "}";

    _ = try scenario.call(admin, "content_type.create", definition);

    const unknown = scenario.call(admin, "record.create", order_with("pigeon"));

    try std.testing.expectError(error.Invalid, unknown);

    const created = try scenario.call(admin, "record.create", order_with("postcard"));
    const Created = struct {
        id: []const u8,
    };
    const arena = scenario.harness.fixed.allocator();
    const parsed = try std.json.parseFromSliceLeaky(Created, arena, created, .{
        .ignore_unknown_fields = true,
    });

    // Postcard removed: the order still names it and saves as it is, but takes no new name.
    var removing = scenario.ctx(.system);

    _ = try registry.SDK.dispatch(&removing, @import("../../operations/plugin.zig").Remove, .{
        .name = "postcard",
    });

    const kept = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"document\":{{\"title\":\"B\"}}}}",
        .{parsed.id},
    );

    _ = try scenario.call(admin, "record.save", kept);

    const changed = try std.fmt.allocPrint(
        arena,
        "{{\"id\":\"{s}\",\"document\":{{\"sent_by\":\"pigeon\"}}}}",
        .{parsed.id},
    );

    try std.testing.expectError(error.Invalid, scenario.call(admin, "record.save", changed));

    const read = try scenario.call(
        admin,
        "record.get",
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\"}}", .{parsed.id}),
    );

    try std.testing.expect(std.mem.indexOf(u8, read, "postcard") != null);
}

test "a plugin's user type: accounts of it, listed apart, signed in only to its apps" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const sampler = @embedFile("sandboxed_plugin_sampler");

    _ = try scenarios_remotes.put(&scenario, "sampler.wasm", sampler);
    try scenarios_remotes.enable(&scenario, "sampler");

    const listed = try scenario.call(admin, "user_type.list", "{}");

    try std.testing.expect(std.mem.indexOf(u8, listed, "\"name\":\"sample_member\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"apps\":[\"www\"]") != null);

    _ = try scenario.call(admin, "user.create",
        \\{"email":"member@example.com","display_name":"Member","roles":["editor"],
        \\ "password":"correct horse battery","user_type":"sample_member"}
    );

    // Only a type a plugin registers.
    const unknown = scenario.call(admin, "user.create",
        \\{"email":"who@example.com","display_name":"Who","roles":["editor"],
        \\ "password":"correct horse battery","user_type":"nobody"}
    );

    try std.testing.expectError(error.Invalid, unknown);

    // Settings › Users lists staff: an editor of the type is staff as well.
    const staff = try scenario.call(admin, "user.list", "{}");
    const members = try scenario.call(admin, "user.list", "{\"user_type\":\"sample_member\"}");

    try std.testing.expect(std.mem.indexOf(u8, staff, "member@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, members, "member@example.com") != null);
    const listed_type = "\"user_types\":[\"sample_member\"]";

    try std.testing.expect(std.mem.indexOf(u8, members, listed_type) != null);

    var reading = scenario.ctx(.system);

    try std.testing.expect(try user_types.opens(&reading, "sample_member", "www"));
    try std.testing.expect(!try user_types.opens(&reading, "sample_member", "shop"));
    try std.testing.expect(try user_types.opens(&reading, "", "shop"));
    try std.testing.expect(!try user_types.opens(&reading, "gone", "www"));

    _ = try scenario.call(admin, "user_type.set",
        \\{"user_type":"sample_member","apps":["shop"]}
    );

    reading = scenario.ctx(.system);

    try std.testing.expect(!try user_types.opens(&reading, "sample_member", "www"));
    try std.testing.expect(try user_types.opens(&reading, "sample_member", "shop"));

    const missing = scenario.call(admin, "user_type.set", "{\"user_type\":\"nobody\"}");

    try std.testing.expectError(error.NotFound, missing);
}

test "an account holds several types, staff included; users.own gives and takes only its own" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const till = @embedFile("sandboxed_plugin_till");

    _ = try scenarios_remotes.put(&scenario, "till.wasm", till);
    try scenarios_remotes.enable(&scenario, "till");
    const sampler = @embedFile("sandboxed_plugin_sampler");

    _ = try scenarios_remotes.put(&scenario, "sampler.wasm", sampler);
    try scenarios_remotes.enable(&scenario, "sampler");

    _ = try scenario.call(admin, "user.create",
        \\{"email":"boss@example.com","display_name":"Boss","roles":["admin"],
        \\ "password":"correct horse battery"}
    );
    _ = try scenario.call(admin, "till.add", "{\"email\":\"ada@example.com\"}");

    // The till makes the administrator one of its regulars: `admin` stays, the type's role
    // comes with it.
    const joined = try scenario.call(admin, "till.join", "{\"email\":\"boss@example.com\"}");

    try std.testing.expect(std.mem.indexOf(u8, joined, "till_regular") != null);

    // An administrator may give a second type; the till may not give another plugin's.
    const both = try scenario.call(admin, "user.add_type",
        \\{"user":"boss@example.com","user_type":"sample_member"}
    );

    const two_types = "\"sample_member\",\"till_regular\"";

    try std.testing.expect(std.mem.indexOf(u8, both, two_types) != null);
    try std.testing.expect(std.mem.indexOf(u8, both, "\"admin\",\"till_regular\"") != null);

    // On staff the till never renames, changes roles or removes: it only gives or takes.
    try std.testing.expectError(error.Denied, scenario.call(
        admin,
        "till.join",
        "{\"email\":\"boss@example.com\",\"rename\":true}",
    ));

    // Staff and the type's list both hold the administrator; its regular only the type's.
    const staff = try scenario.call(admin, "user.list", "{}");
    const regulars = try scenario.call(admin, "user.list", "{\"user_type\":\"till_regular\"}");

    try std.testing.expect(std.mem.indexOf(u8, staff, "boss@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, staff, "ada@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, regulars, "boss@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, regulars, "ada@example.com") != null);

    // Apps: staff reach every app their roles reach; a regular only the till's.
    var reading = scenario.ctx(.system);
    const boss_types = [_][]const u8{ "sample_member", "till_regular" };
    const boss_roles = [_][]const u8{ "admin", "till_regular" };
    const ada_types = [_][]const u8{"till_regular"};
    const ada_roles = [_][]const u8{"till_regular"};

    try std.testing.expect(try user_types.opens_any(&reading, &boss_types, &boss_roles, "shop"));
    try std.testing.expect(try user_types.opens_any(&reading, &ada_types, &ada_roles, "www"));
    try std.testing.expect(!try user_types.opens_any(&reading, &ada_types, &ada_roles, "shop"));

    // Taking the type takes its role but never `admin`.
    const left = try scenario.call(
        admin,
        "till.join",
        "{\"email\":\"boss@example.com\",\"leave\":true}",
    );

    try std.testing.expect(std.mem.indexOf(u8, left, "till_regular") == null);

    const account = try scenario.call(admin, "user.get", "{\"user\":\"boss@example.com\"}");

    try std.testing.expect(std.mem.indexOf(u8, account, "\"roles\":[\"admin\"]") != null);
}
