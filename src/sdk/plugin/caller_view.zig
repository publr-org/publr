//! `ctx.caller()` made from a caller as core knows it, and where a call came from.
const std = @import("std");
const Caller = @import("../caller.zig").Caller;

const public = @import("../../publr/caller.zig");

pub const From = public.From;
pub const View = public.View;
pub const publr_name = public.publr_name;

/// What a plugin's code reads of `raw`, a caller as core knows it.
pub fn view_of(raw: Caller, seen: Seen) View {
    const person = switch (raw) {
        .user, .token => true,
        .anonymous, .system, .plugin => false,
    };

    std.debug.assert(!person or raw.user_id() != null);
    std.debug.assert(!(seen.granted_here and seen.from == .app));

    return .{
        .from = seen.from,
        .visitor = seen.visitor,
        .referer = seen.referer,
        .person = person,
        .device = raw == .token,
        .account_id = raw.user_id(),
        .held_roles = raw.roles(),
        .granted_here = seen.granted_here,
    };
}

/// What the call tells besides who: where it came from, the visitor, the referer.
pub const Seen = struct {
    from: From,
    visitor: []const u8 = "",
    referer: []const u8 = "",
    granted_here: bool = false,
};

/// Where a call came from, from what the core knows of it. `over_api`: the request came to
/// REST. `job` is the queued job running (`<plugin>.<name>`), empty outside one: Publr
/// calling for it is that plugin calling.
pub fn from_of(caller: Caller, through_app: bool, over_api: bool, job: []const u8) From {
    std.debug.assert(@backingInt(caller) <= @backingInt(Caller.plugin));
    std.debug.assert(job.len == 0 or std.mem.indexOfScalar(u8, job, '.') != null);

    if (through_app and caller != .plugin and caller != .system) {
        return .app;
    }

    const from: From = switch (caller) {
        .anonymous => .app,
        .user => .admin,
        .token => if (over_api) .api else .command_line,
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

    const view = view_of(ada, .{
        .from = .admin,
        .granted_here = true,
    });

    try std.testing.expect(view.signed_in() and view.is("ada") and view.has_role("admin"));
    try std.testing.expect(view.granted());
}
