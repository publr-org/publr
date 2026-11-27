const std = @import("std");
const account = @import("../model/account.zig");
const role = @import("../model/role.zig");
const device = @import("../model/device.zig");

pub const id_len_max: u32 = account.id_len_max;

pub const Caller = union(enum) {
    anonymous,
    user: User,
    token: Token,
    system,
    plugin: Plugin,

    /// A signed-in account and the names of the roles it holds.
    pub const User = struct {
        id: []const u8,
        roles: []const []const u8 = &.{role.admin},
    };
    /// A device acting for an account: the account's roles, narrowed by the device's scope.
    pub const Token = struct {
        id: []const u8,
        user_id: []const u8,
        roles: []const []const u8 = &.{},
        scope: device.Scope = .read,
        /// What the person approved it as.
        name: []const u8 = "",
    };
    pub const Plugin = struct {
        name: []const u8,
        on_behalf_of: ?[]const u8 = null,
        /// What its granted permissions allow; none reaches only its own types.
        access: ?*const @import("plugin_access.zig").Access = null,
        /// The roles of the account an installed plugin acts for: each call gets the narrower
        /// of the plugin's grant and theirs.
        roles: ?[]const []const u8 = null,
        /// A built-in plugin acting for the account (`ctx.as_person`): the person's own call,
        /// the plugin's code making it for them. Never an installed plugin relaying a call.
        for_person: bool = false,
    };

    /// The account of the person making the call themselves: signed in, or a built-in
    /// plugin acting for them (`ctx.as_person`). Null for a device, which never lets in
    /// another, for an installed plugin relaying a call, and for anyone else.
    pub fn person(caller: Caller) ?[]const u8 {
        const id: ?[]const u8 = switch (caller) {
            .user => |user| user.id,
            .plugin => |plugin| if (plugin.for_person) plugin.on_behalf_of else null,
            .anonymous, .token, .system => null,
        };

        std.debug.assert(id == null or id.?.len > 0);
        std.debug.assert(id == null or caller == .user or caller.plugin.on_behalf_of != null);

        return id;
    }

    /// Whether the person making the call themselves (`person`) holds the role `name`: a
    /// built-in plugin acting for them stands in their place for what their roles decide.
    pub fn person_holds(caller: Caller, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        const held: []const []const u8 = switch (caller) {
            .user => |user| user.roles,
            .plugin => |plugin| if (plugin.for_person) plugin.roles orelse &.{} else &.{},
            .anonymous, .token, .system => &.{},
        };

        std.debug.assert(held.len <= role.user_roles_max);

        for (held) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                return true;
            }
        }

        return false;
    }

    pub fn is_authenticated(caller: Caller) bool {
        const authenticated = switch (caller) {
            .anonymous => false,
            .user, .token, .system, .plugin => true,
        };

        std.debug.assert(authenticated or caller == .anonymous);
        std.debug.assert(!authenticated or caller != .anonymous);

        return authenticated;
    }

    pub fn user_id(caller: Caller) ?[]const u8 {
        const id: ?[]const u8 = switch (caller) {
            .user => |user| user.id,
            .token => |token| token.user_id,
            .plugin => |plugin| plugin.on_behalf_of,
            .anonymous, .system => null,
        };

        if (id) |value| {
            std.debug.assert(value.len > 0);
        }

        if (id) |value| {
            std.debug.assert(value.len <= id_len_max);
        }

        return id;
    }

    /// The roles a signed-in account holds, or the account a device acts for; null for any
    /// other caller.
    pub fn roles(caller: Caller) ?[]const []const u8 {
        const found: ?[]const []const u8 = switch (caller) {
            .user => |user| user.roles,
            .token => |token| token.roles,
            .anonymous, .system, .plugin => null,
        };

        std.debug.assert(found == null or caller == .user or caller == .token);
        std.debug.assert(found == null or found.?.len <= role.user_roles_max);

        return found;
    }

    /// Whether the caller is a signed-in account holding the role `name`.
    pub fn holds(caller: Caller, name: []const u8) bool {
        std.debug.assert(name.len > 0);
        std.debug.assert(name.len <= role.name_len_max);

        const held = caller.roles() orelse return false;

        for (held) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                return true;
            }
        }

        return false;
    }

    /// The device's scope when a device makes the call; null for anyone else.
    pub fn scope(caller: Caller) ?device.Scope {
        const found: ?device.Scope = switch (caller) {
            .token => |token| token.scope,
            .anonymous, .user, .system, .plugin => null,
        };

        std.debug.assert(found == null or caller == .token);
        std.debug.assert(found != null or caller != .token);

        return found;
    }

    pub fn label(caller: Caller) []const u8 {
        const text: []const u8 = switch (caller) {
            .anonymous => "anonymous",
            .user => |user| user.id,
            .token => |token| token.user_id,
            .system => "system",
            .plugin => |plugin| plugin.name,
        };

        std.debug.assert(text.len > 0);
        std.debug.assert(text.len <= id_len_max);

        return text;
    }
};

test "authentication and user id per caller kind" {
    const anon: Caller = .anonymous;
    const user: Caller = .{
        .user = .{
            .id = "u_1",
        },
    };
    const token: Caller = .{
        .token = .{
            .id = "t_1",
            .user_id = "u_2",
        },
    };
    const system: Caller = .system;

    try std.testing.expect(!anon.is_authenticated());
    try std.testing.expect(user.is_authenticated());
    try std.testing.expect(system.is_authenticated());
    try std.testing.expectEqual(@as(?[]const u8, null), anon.user_id());
    try std.testing.expectEqualStrings("u_1", user.user_id().?);
    try std.testing.expectEqualStrings("u_2", token.user_id().?);
    try std.testing.expectEqualStrings("system", system.label());
    try std.testing.expectEqualStrings("admin", user.roles().?[0]);
    try std.testing.expect(user.holds("admin"));
    try std.testing.expect(!user.holds("editor"));
    try std.testing.expectEqual(@as(usize, 0), token.roles().?.len);
    try std.testing.expect(!token.holds("admin"));
    try std.testing.expectEqual(device.Scope.read, token.scope().?);
    try std.testing.expect(user.scope() == null);
}

test "the person making the call: signed in, or a built-in plugin acting for them" {
    const user: Caller = .{
        .user = .{
            .id = "u_1",
        },
    };
    const token: Caller = .{
        .token = .{
            .id = "t_1",
            .user_id = "u_2",
        },
    };
    const acting: Caller = .{
        .plugin = .{
            .name = "cloud",
            .on_behalf_of = "u_3",
            .for_person = true,
        },
    };
    const relaying: Caller = .{
        .plugin = .{
            .name = "shop",
            .on_behalf_of = "u_4",
        },
    };

    try std.testing.expectEqualStrings("u_1", user.person().?);
    try std.testing.expectEqualStrings("u_3", acting.person().?);
    try std.testing.expect(token.person() == null);
    try std.testing.expect(relaying.person() == null);
    try std.testing.expect(user.person_holds("admin"));
    try std.testing.expect(!token.person_holds("admin"));
    try std.testing.expect(!acting.person_holds("admin"));
    try std.testing.expect(@as(Caller, .system).person() == null);
    try std.testing.expect(@as(Caller, .anonymous).person() == null);
}
