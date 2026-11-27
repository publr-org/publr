//! Who is calling, as a plugin's code reads it: `ctx.caller()`. Where the call came from,
//! whether someone is signed in, their account and roles, whether an administrator granted
//! them this operation, and the visitor's stable id, signed in or not.
const std = @import("std");
const Account = @import("account_ref.zig").Account;

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
    /// A person signed in (the admin, an app's pages) or a device acting for one.
    person: bool = false,
    /// The account the call is made for: the person's, or the one a plugin acts for.
    account_id: ?[]const u8 = null,
    /// The roles the person holds; null when no person makes the call.
    held_roles: ?[]const []const u8 = null,
    /// Administrators, and roles an administrator granted this operation; false through an
    /// app's address.
    granted_here: bool = false,

    pub fn signed_in(view: View) bool {
        std.debug.assert(!view.person or view.account_id != null);
        std.debug.assert(view.held_roles == null or view.person);

        return view.person;
    }

    /// The account the call is made for: the person signed in, a device's person, or the
    /// account an installed plugin acts for; null for nobody.
    pub fn user_id(view: View) ?[]const u8 {
        const id = view.account_id orelse return null;

        std.debug.assert(id.len > 0);

        return id;
    }

    /// The roles of the person signed in, or of the person a device acts for; null for any
    /// other caller.
    pub fn roles(view: View) ?[]const []const u8 {
        std.debug.assert(view.held_roles == null or view.person);

        return view.held_roles;
    }

    pub fn has_role(view: View, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        const held = view.held_roles orelse return false;

        for (held) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                return true;
            }
        }

        return false;
    }

    pub fn granted(view: View) bool {
        std.debug.assert(!(view.granted_here and view.from == .app));

        return view.granted_here;
    }

    /// The signed-in person's account (through the admin, an app's pages, or a device acting
    /// for them), to keep in a `publr.Account` field; null when nobody is signed in.
    pub fn account(view: View) ?Account {
        const id = view.user_id() orelse return null;

        std.debug.assert(id.len > 0);

        return .{
            .id = id,
        };
    }

    /// Whether the caller is the person with this id: for "is it theirs?" checks.
    pub fn is(view: View, id: []const u8) bool {
        std.debug.assert(id.len > 0);

        const own = view.user_id() orelse return false;

        return std.mem.eql(u8, own, id);
    }
};

test "what a caller's view tells" {
    const view: View = .{
        .from = .admin,
        .person = true,
        .account_id = "ada",
        .held_roles = &.{"admin"},
        .granted_here = true,
    };

    try std.testing.expect(view.signed_in() and view.is("ada") and view.has_role("admin"));
    try std.testing.expect(!view.has_role("editor") and view.granted());
    try std.testing.expectEqualStrings("ada", view.account().?.id);

    const plugin: View = .{
        .from = .{
            .plugin = "shop",
        },
        .account_id = "ada",
    };

    try std.testing.expect(!plugin.signed_in() and plugin.roles() == null);
    try std.testing.expectEqualStrings("ada", plugin.user_id().?);
}
