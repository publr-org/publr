const std = @import("std");

pub const key_len_max: u32 = 64;
pub const sentence_len_max: u32 = 120;
pub const operations_max: u32 = 32;

/// How much a permission can do: low and medium are granted when a plugin is installed,
/// high waits for an administrator.
pub const Tier = enum { low, medium, high };

/// What a key's request may name to narrow it: content types, taxonomies, or domains.
pub const Narrowing = enum { none, records, taxonomies, domains };

/// A yes/no option on a grant, each a switch in the admin.
pub const Flag = enum { drafts, private, internal, publish };

pub const flag_tiers = [_]Tier{ .medium, .high, .high, .medium };

/// What an administrator sees and grants: a key, a sentence, the tier it starts at, the
/// operations it stands for, what narrows it and the flags it takes.
pub const Permission = struct {
    key: []const u8,
    sentence: []const u8,
    tier: Tier,
    operations: []const []const u8 = &.{},
    narrowing: Narrowing = .none,
    flags: []const Flag = &.{},
    /// The tier when it names nothing: every type, not some.
    wide_tier: ?Tier = null,
    /// Its operations that need `.publish` on: they put things live or take them off.
    publishing: []const []const u8 = &.{},
    /// Its operations that need `.drafts` on: version history holds unpublished text.
    history: []const []const u8 = &.{},
    /// The events it lets a plugin emit beside its own, by prefix: `messaging.` for every
    /// message (`publr.messaging.Email`).
    events: []const []const u8 = &.{},
};

/// One permission as asked for or as granted: the key, the flags as booleans, the content
/// types or taxonomies it names (empty: every one), and for `http.fetch` the domains it may
/// reach (empty: none).
pub const Held = struct {
    key: []const u8,
    records: []const []const u8 = &.{},
    taxonomies: []const []const u8 = &.{},
    domains: []const []const u8 = &.{},
    drafts: bool = false,
    private: bool = false,
    internal: bool = false,
    publish: bool = false,

    pub fn flag(held: *const Held, which: Flag) bool {
        std.debug.assert(held.key.len > 0);

        return switch (which) {
            .drafts => held.drafts,
            .private => held.private,
            .internal => held.internal,
            .publish => held.publish,
        };
    }

    pub fn set(held: *Held, which: Flag, on: bool) void {
        std.debug.assert(held.key.len > 0);

        switch (which) {
            .drafts => held.drafts = on,
            .private => held.private = on,
            .internal => held.internal = on,
            .publish => held.publish = on,
        }
    }

    /// The types or taxonomies it names, by what its key narrows.
    pub fn names(held: *const Held) []const []const u8 {
        std.debug.assert(held.key.len > 0);

        return if (held.records.len > 0) held.records else held.taxonomies;
    }
};

/// The tier of `held` under `entry`: the key's, raised by every flag on and by naming
/// nothing where that reaches every type.
pub fn tier_of_held(entry: *const Permission, held: *const Held) Tier {
    std.debug.assert(entry.key.len > 0);
    std.debug.assert(std.mem.eql(u8, entry.key, held.key));

    var tier = entry.tier;

    if (entry.wide_tier) |wide| {
        if (held.names().len == 0 and @intFromEnum(wide) > @intFromEnum(tier)) {
            tier = wide;
        }
    }

    for (entry.flags) |which| {
        const raised = flag_tiers[@intFromEnum(which)];

        if (held.flag(which) and @intFromEnum(raised) > @intFromEnum(tier)) {
            tier = raised;
        }
    }

    return tier;
}

/// Granted to every plugin without asking: harmless, and needed to run at all.
pub const always = [_][]const u8{
    "heartbeat.check",    "project.status", "status.list",
    "internal.create",    "internal.get",   "internal.save",
    "internal.find_one",  "internal.find",  "internal.delete",
    "project.currencies", "mod.apply",
};

/// The record operations a plugin reaches on its own content types without asking.
pub const own_records = [_][]const u8{
    "record.get",
    "record.list",
    "record.create",
    "record.save",
    "record.delete",
    "record.publish",
    "record.transition",
    "record.discard_changes",
    "record.purge",
    "snapshot.list",
    "snapshot.get",
    "snapshot.take",
    "record.validate",
    "record.shown",
    "record.query",
    "record.reach",
    "record.transition_many",
    "record.decline_request",
};

/// Every key a plugin may ask for.
pub const core = @import("permission/core.zig").core;

/// The operations no permission names: sessions and passwords, who may sign people in,
/// setup, who holds what and what each role grants, one person's saved views, an app's
/// types handed to another, the project's secrets, a person's conversations with a model.
/// No grant reaches them.
pub const never = [_][]const u8{
    "user.sign_in",       "user.sign_out",      "user.set_password",          "user.password_link",
    "sign_on.configure",  "sign_on.status",     "sign_on.redeem",             "identity.sign_in",
    "identity.configure", "identity.status",    "identity.link",              "identity.unlink",
    "identity.list",      "identity.providers", "project.init",               "role.list",
    "view.list",          "view.get",           "view.create",                "view.update",
    "view.delete",        "project.move_app",   "project.set_currencies",     "activity.list",
    "errors.list",        "secret.list",        "secret.set",                 "secret.remove",
    "ai.ask",             "ai.conversation",    "ai.conversations",           "ai.stop",
    "ai.begin",           "ai.step",            "ai.finish",                  "ai.draft",
    "user.language",      "user.set_language",  "project.set_admin_language", "user.variant",
    "user.set_variant",   "ai.transcribe",      "view.default",               "view.save_default",
    "mod.list",           "view.reset_default", "role.get",                   "role.create",
    "role.update",        "role.reset",         "role.remove",
};

/// The permission `key` stands for among `catalog`, or null when nothing installed provides it.
pub fn find(catalog: []const Permission, key: []const u8) ?*const Permission {
    std.debug.assert(key.len > 0);
    std.debug.assert(catalog.len > 0);

    for (catalog) |*permission| {
        if (std.mem.eql(u8, permission.key, key)) {
            return permission;
        }
    }

    return null;
}

/// How a key a plugin asks for is tiered: its catalog entry's, `medium` for a call to a
/// plugin it depends on, and null for a key nothing provides (the plugin
/// installs without it).
pub fn tier_of(catalog: []const Permission, key: []const u8) ?Tier {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_len_max);

    if (called_operation(key) != null) {
        return .medium;
    }

    const permission = find(catalog, key) orelse return null;

    return permission.tier;
}

/// The operation a `call:<plugin>.<verb>` or `call:app.<plugin>.<verb>` key names: exactly
/// one operation, never a namespace. That it is a plugin's, one the caller depends on, is
/// checked where the plugin is known.
pub fn called_operation(key: []const u8) ?[]const u8 {
    const prefix = "call:";

    std.debug.assert(key_len_max > prefix.len);

    if (key.len > key_len_max or !std.mem.startsWith(u8, key, prefix)) {
        return null;
    }

    const name = key[prefix.len..];
    const tail = if (std.mem.startsWith(u8, name, "app.")) name["app.".len..] else name;
    const dot = std.mem.indexOfScalar(u8, tail, '.') orelse return null;

    if (dot == 0 or dot + 1 == tail.len) {
        return null;
    }

    for (tail, 0..) |char, index| {
        if (index == dot) {
            continue;
        }

        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '_') {
            return null;
        }
    }

    std.debug.assert(tail.len >= 3);

    return name;
}

/// The key a plugin needs to emit `event`, one not its own: null when no key lets it.
pub fn key_for_event(event: []const u8) ?[]const u8 {
    std.debug.assert(event.len > 0);

    for (core) |permission| {
        for (permission.events) |prefix| {
            if (std.mem.startsWith(u8, event, prefix)) {
                return permission.key;
            }
        }
    }

    return null;
}

pub fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(item.len > 0);
    std.debug.assert(list.len <= 1024);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

test "a message needs messaging.send; a plugin's own events need no key" {
    try std.testing.expectEqualStrings("messaging.send", key_for_event("messaging.email").?);
    try std.testing.expectEqualStrings("messaging.send", key_for_event("messaging.push").?);
    try std.testing.expect(key_for_event("orders.placed") == null);
}

test "every catalog key is unique, and no permission names an operation that is never granted" {
    for (core, 0..) |permission, index| {
        try std.testing.expect(permission.key.len <= key_len_max);
        try std.testing.expect(permission.sentence.len <= sentence_len_max);

        for (core[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, permission.key, other.key));
        }

        for (permission.operations) |name| {
            try std.testing.expect(!contains(&never, name));
        }
    }
}

test "tiers: catalog keys by their entry, unknown keys (a secret's among them) unavailable" {
    try std.testing.expectEqual(Tier.low, tier_of(&core, "records.read").?);
    try std.testing.expectEqual(Tier.high, tier_of(&core, "http.fetch").?);
    try std.testing.expect(tier_of(&core, "secret.STRIPE_KEY") == null);
    try std.testing.expect(find(&core, "secret.STRIPE_KEY") == null);
    try std.testing.expect(tier_of(&core, "newsletter.send") == null);
}

test "a call permission names exactly one plugin operation, at the medium tier" {
    const target = called_operation("call:app.provider.adjust").?;
    try std.testing.expectEqualStrings("app.provider.adjust", target);
    try std.testing.expectEqualStrings(
        "provider.adjust",
        called_operation("call:provider.adjust").?,
    );

    const invalid = [_][]const u8{
        "call:app.provider.*",   "call:app..adjust", "call:app.provider.",
        "call:app.provider.a.b", "call:provider",    "call:provider.*",
    };

    for (invalid) |key| {
        try std.testing.expect(called_operation(key) == null);
    }

    try std.testing.expectEqual(Tier.medium, tier_of(&core, "call:app.provider.adjust").?);
}

test "the tier follows what is asked: flags raise it, every type raises a write" {
    const read = find(&core, "records.read").?;
    const write = find(&core, "records.write").?;

    try std.testing.expectEqual(Tier.low, tier_of_held(read, &.{
        .key = "records.read",
    }));
    try std.testing.expectEqual(Tier.medium, tier_of_held(read, &.{
        .key = "records.read",
        .drafts = true,
    }));
    try std.testing.expectEqual(Tier.high, tier_of_held(read, &.{
        .key = "records.read",
        .records = &.{"post"},
        .internal = true,
    }));
    try std.testing.expectEqual(Tier.medium, tier_of_held(write, &.{
        .key = "records.write",
        .records = &.{"post"},
        .publish = true,
    }));
    try std.testing.expectEqual(Tier.high, tier_of_held(write, &.{
        .key = "records.write",
    }));
}
