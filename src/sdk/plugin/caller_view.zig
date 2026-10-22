//! Who is calling, as a plugin's code reads it: `ctx.caller()`. Where the call came from,
//! whether someone is signed in, their roles, whether an administrator granted them this
//! operation, and the visitor's stable id, signed in or not.
const std = @import("std");
const Caller = @import("../caller.zig").Caller;

pub const From = union(enum) {
    /// The admin, signed in.
    admin,
    /// The CLI or an agent, with a device token.
    command_line,
    /// REST (`/api/<plugin>.<verb>`): a device token or a machine key.
    api,
    /// A site's pages, through an app's address.
    app,
    /// A plugin's code, by the plugin's name: its queued work too. Publr's own work between
    /// requests is `publr`.
    plugin: []const u8,
};

/// The name Publr's own work between requests calls by.
pub const publr_name = "publr";

pub const View = struct {
    from: From,
    /// The visitor's stable id when the call came through an app, signed in or not.
    visitor: []const u8 = "",
    /// The page that sent the request when it is another site's; empty for the site's own
    /// pages and a call no request made. It tells, never grants.
    referer: []const u8 = "",
    raw: Caller,
    /// Administrators, and roles an administrator granted this operation; false through an
    /// app's address.
    granted_here: bool = false,

    pub fn signed_in(view: View) bool {
        const yes = switch (view.raw) {
            .user, .token => true,
            else => false,
        };

        std.debug.assert(!yes or view.raw.user_id() != null);

        return yes;
    }

    pub fn has_role(view: View, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        const held = view.raw.roles() orelse return false;

        for (held) |role_name| {
            if (std.mem.eql(u8, role_name, name)) {
                return true;
            }
        }

        return false;
    }

    pub fn granted(view: View) bool {
        std.debug.assert(!(view.granted_here and view.from == .app));

        return view.granted_here;
    }

    /// Whether the caller is the person with this id: for "is it theirs?" checks.
    pub fn is(view: View, id: []const u8) bool {
        std.debug.assert(id.len > 0);

        const own = view.raw.user_id() orelse return false;

        return std.mem.eql(u8, own, id);
    }
};

/// Where a call came from, from what the core knows of it. `over_api`: the request came to
/// REST. `job` is the queued job running (`<plugin>.<name>`), empty outside one: Publr
/// calling for it is that plugin calling.
pub fn from_of(caller: Caller, through_app: bool, over_api: bool, job: []const u8) From {
    std.debug.assert(@intFromEnum(caller) <= @intFromEnum(Caller.plugin));
    std.debug.assert(job.len == 0 or std.mem.indexOfScalar(u8, job, '.') != null);

    if (through_app and caller != .plugin and caller != .system) {
        return .app;
    }

    const from: From = switch (caller) {
        .anonymous => .app,
        .user => .admin,
        .token => if (over_api) .api else .command_line,
        .machine => .api,
        .plugin => |plugin| .{
            .plugin = plugin.name,
        },
        .system => .{
            .plugin = if (std.mem.indexOfScalar(u8, job, '.')) |dot| job[0..dot] else publr_name,
        },
    };

    std.debug.assert(from != .app or caller == .anonymous or through_app);

    return from;
}

/// `From` as the sandbox's wire carries it: the kind, and the plugin's name beside it.
pub const Kind = std.meta.Tag(From);

pub fn kind_of(from: From) Kind {
    return std.meta.activeTag(from);
}

pub fn plugin_of(from: From) []const u8 {
    return switch (from) {
        .plugin => |name| name,
        .admin, .command_line, .api, .app => "",
    };
}

/// The `From` a wire's kind and plugin name stand for.
pub fn joined(kind: Kind, plugin: []const u8) From {
    std.debug.assert(plugin.len == 0 or kind == .plugin);

    return switch (kind) {
        .admin => .admin,
        .command_line => .command_line,
        .api => .api,
        .app => .app,
        .plugin => .{
            .plugin = if (plugin.len > 0) plugin else publr_name,
        },
    };
}

test "where a call came from" {
    const ada: Caller = .{
        .user = .{
            .id = "ada",
        },
    };

    try std.testing.expect(from_of(ada, false, false, "") == .admin);
    try std.testing.expect(from_of(ada, true, false, "") == .app);
    try std.testing.expectEqualStrings("publr", from_of(.system, true, false, "").plugin);
    try std.testing.expectEqualStrings("shop", from_of(.system, false, false, "shop.sync").plugin);

    const checkout: Caller = .{
        .plugin = .{
            .name = "checkout",
            .capabilities = &.{},
        },
    };

    try std.testing.expectEqualStrings("checkout", from_of(checkout, true, false, "").plugin);

    const device: Caller = .{
        .token = .{
            .id = "d_1",
            .user_id = "ada",
            .scope = .write,
        },
    };

    try std.testing.expect(from_of(device, false, false, "") == .command_line);
    try std.testing.expect(from_of(device, false, true, "") == .api);
    try std.testing.expectEqualStrings("cart", joined(.plugin, "cart").plugin);
    try std.testing.expect(joined(kind_of(.api), plugin_of(.api)) == .api);

    const view: View = .{
        .from = .admin,
        .raw = ada,
        .granted_here = true,
    };

    try std.testing.expect(view.signed_in() and view.is("ada") and view.has_role("admin"));
    try std.testing.expect(view.granted());
}
