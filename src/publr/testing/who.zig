//! Who makes a call on a test site (`publr.testing.Who`), and the caller core runs it as.
const std = @import("std");
const sdk = @import("../../sdk.zig");

/// Who makes a call.
pub const Who = union(enum) {
    /// Publr itself, between requests.
    system,
    /// The site's administrator, `u_admin`.
    admin,
    /// A visitor with no account, by the stable id their browser carries (empty: none).
    visitor: []const u8,
    /// A signed-in account.
    user: User,
    /// A built-in plugin's own code, calling as itself.
    plugin: Plugin,
    /// A device (the CLI, an agent, an app signed in to the account) acting for a person:
    /// their roles, narrowed by the device's scope.
    device: Device,
};

pub const Device = struct {
    /// The device's id, as its token names it.
    id: []const u8 = "d_test",
    /// The person it acts for.
    user: User,
    /// What the person approved it for.
    scope: @import("../model/device.zig").Scope = .read,
    /// What the person approved it as.
    name: []const u8 = "",
};

pub const User = struct {
    id: []const u8,
    roles: []const []const u8 = &.{},
    /// The visitor id their browser carries, on a site's pages.
    visitor: []const u8 = "",
};

pub const Plugin = struct {
    name: []const u8,
    /// The visitor its call came from, on a site's pages.
    visitor: []const u8 = "",
    /// The person its call came from; a visitor with no account when null.
    user: ?User = null,
};

/// The caller core runs a call made by `who` as.
pub fn caller_of(who: Who) sdk.Caller {
    const user: ?User = switch (who) {
        .user => |user| user,
        .plugin => |plugin| plugin.user,
        .device => |device| device.user,
        .system, .admin, .visitor => null,
    };

    std.debug.assert(user == null or user.?.id.len > 0);

    return switch (who) {
        .system => .system,
        .admin => .{
            .user = .{
                .id = "u_admin",
            },
        },
        .visitor => .anonymous,
        .user, .plugin => if (user) |person| .{
            .user = .{
                .id = person.id,
                .roles = person.roles,
            },
        } else .anonymous,
        .device => |device| .{
            .token = .{
                .id = device.id,
                .user_id = device.user.id,
                .roles = device.user.roles,
                .scope = device.scope,
                .name = device.name,
            },
        },
    };
}
