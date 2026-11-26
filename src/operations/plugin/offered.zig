//! What core offers plugins besides its operations and host functions: the events it has
//! (emitted by core, or by plugins on core's behalf), and the mods it applies. One list of
//! each, read by `plugin surface`, the install and load check and the release's check.
//! Every operation is an event too, under its own name; those come from the operations.
const std = @import("std");
const sdk = @import("../../sdk.zig");

const auth_events = @import("../../sdk/auth_events.zig");
const messaging = @import("../../sdk/messaging.zig");
const role = @import("../role.zig");
const internal = @import("../internal.zig");

/// Core's events, each made with `event(...)`.
const events = [_]type{
    auth_events.SignedIn,                         auth_events.SignedUp,
    auth_events.SignedOut,                        auth_events.SignInThrottled,
    auth_events.SignInFailed,                     auth_events.SignInLocked,
    auth_events.SignOnReplayed,                   auth_events.SignOnFailed,
    auth_events.IdentityRefused,                  @import("../user.zig").UserCreated,
    @import("../../sdk/error_events.zig").Failed, messaging.Email,
    messaging.Bounced,                            messaging.Complained,
    messaging.Sms,                                messaging.Push,
    role.Created,                                 role.Updated,
    role.Removed,                                 role.GrantDropped,
    internal.Created,                             internal.Saved,
    internal.Deleted,
};

pub const event_names = names: {
    var names: [events.len][]const u8 = undefined;

    for (events, &names) |Event, *name| {
        name.* = Event.full_name;
    }

    break :names names;
};

/// A mod core applies, by name.
pub const Mod = struct {
    name: []const u8,
    deprecated: ?sdk.operation.Deprecated = null,
};

pub const mods = [_]Mod{
    .{
        .name = @import("../../sdk/media_base.zig").mod_name,
    },
    .{
        .name = @import("../../sdk/site_currencies.zig").mod_name,
    },
};

/// The mods core applies to every record type, by how their names end: `<type>.title`,
/// `<type>.markers`, `<type>.<field>.help`.
pub const mod_endings = [_][]const u8{ ".title", ".markers", ".help" };

/// The namespaces core's events and mods are in, beside its operations': a name in one of
/// them that core lacks is one it removed, or never had.
pub const namespaces = [_][]const u8{
    "auth", "errors", "internal", "messaging", "role", "media", "money",
};

/// An event or a mod on its way out, with what kind of item it is (`event`, `mod`).
pub const Deprecated = struct {
    kind: []const u8,
    name: []const u8,
    deprecated: sdk.operation.Deprecated,
};

/// Every deprecated event and mod.
pub const deprecated = listed: {
    var count: usize = 0;

    for (events) |Event| {
        if (Event.deprecated != null) {
            count += 1;
        }
    }

    for (mods) |mod| {
        if (mod.deprecated != null) {
            count += 1;
        }
    }

    var list: [count]Deprecated = undefined;
    var index: usize = 0;

    for (events) |Event| {
        const found = Event.deprecated orelse continue;

        list[index] = .{
            .kind = "event",
            .name = Event.full_name,
            .deprecated = found,
        };
        index += 1;
    }

    for (mods) |mod| {
        const found = mod.deprecated orelse continue;

        sdk.operation.check_deprecated(mod.name, found);
        list[index] = .{
            .kind = "mod",
            .name = mod.name,
            .deprecated = found,
        };
        index += 1;
    }

    const final = list;

    break :listed final;
};

comptime {
    for (events) |Event| {
        std.debug.assert(Event.full_name.len > 0);
    }
}

test "core's events are named in full, each once" {
    for (event_names, 0..) |name, index| {
        try std.testing.expect(std.mem.indexOfScalar(u8, name, '.') != null);

        for (event_names[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }
}
