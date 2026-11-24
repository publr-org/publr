//! Who may make an account staff: only an account (or the site's own CLI) that may manage
//! users, never a plugin, whatever it holds (`users.write`, `users.own`), compiled in or
//! installed, and never through a type of user, which gives visitor roles only.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const user_operations = @import("../user.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// Refused when the roles an account goes to hold give it a staff role it did not hold and a
/// plugin's code asks: whoever it runs for, whatever it was granted. Signed links run as
/// their plugin, so none makes staff either.
pub fn refuse_from_plugin(
    ctx: *const Ctx,
    before: []const []const u8,
    after: []const []const u8,
) Error!void {
    std.debug.assert(before.len <= 64);
    std.debug.assert(after.len <= 64);

    const plugin = ctx.caller == .plugin or ctx.plugin.len > 0;

    if (!plugin) {
        return;
    }

    for (after) |name| {
        if (held(before, name)) {
            continue;
        }

        if (try sdk.stored_roles.staff(ctx, name)) {
            return error.Denied;
        }
    }
}

fn held(list: []const []const u8, name: []const u8) bool {
    std.debug.assert(list.len <= 64);

    for (list) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

const TestSDK = sdk.SDK(.{
    .operations = &user_operations.operations,
});

test "a plugin never gives a staff role, even holding users.write" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    try user_operations.seed_editor(&system);

    const access: sdk.plugin_access.Access = .{
        .held = &.{.{
            .key = "users.write",
        }},
        .own_types = &.{},
    };
    var plugin = harness.ctx(.{
        .plugin = .{
            .name = "writer",
            .access = &access,
        },
    });

    try std.testing.expectError(error.Denied, TestSDK.dispatch(&plugin, user_operations.Update, .{
        .user = "editor@example.com",
        .display_name = "Editor",
        .roles = &.{"admin"},
    }));
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&plugin, user_operations.Create, .{
        .email = "eve@example.com",
        .display_name = "Eve",
        .roles = &.{"editor"},
        .password = "correct horse battery",
    }));

    // A compiled-in plugin's code, running for an administrator: refused the same.
    var compiled = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });

    compiled.plugin = "writer";
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&compiled, user_operations.Create, .{
        .email = "mallory@example.com",
        .display_name = "Mallory",
        .roles = &.{"admin"},
        .password = "correct horse battery",
    }));

    // A signed link runs its plugin's operation as the system, the plugin named: refused.
    var linked = harness.ctx(.system);

    linked.plugin = "writer";
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&linked, user_operations.Update, .{
        .user = "editor@example.com",
        .display_name = "Editor",
        .roles = &.{"admin"},
    }));

    // The administrator's own call makes staff; taking a staff role away is anyone's who may.
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });

    _ = try TestSDK.dispatch(&admin, user_operations.Create, .{
        .email = "grace@example.com",
        .display_name = "Grace",
        .roles = &.{"editor"},
        .password = "correct horse battery",
    });
}
