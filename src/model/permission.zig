const std = @import("std");

pub const key_len_max: u32 = 64;
pub const sentence_len_max: u32 = 120;
pub const operations_max: u32 = 32;

/// How much a permission can do: low and medium are granted when a plugin is installed,
/// high waits for an administrator.
pub const Tier = enum { low, medium, high };

/// What an administrator sees and grants: a key, a sentence, a tier, and the operations it
/// stands for. `content` marks the permissions whose operations are held to the plugin's
/// content access; `host` the ones that are a host function rather than operations.
pub const Permission = struct {
    key: []const u8,
    sentence: []const u8,
    tier: Tier,
    operations: []const []const u8 = &.{},
    content: bool = false,
    host: bool = false,
};

/// Granted to every plugin without asking: harmless, and needed to run at all.
pub const always = [_][]const u8{
    "heartbeat.check",    "project.status", "status.list",
    "internal.create",    "internal.get",   "internal.save",
    "internal.find_one",  "internal.find",  "internal.delete",
    "project.currencies",
};

/// The record operations a plugin reaches on its own content types without asking.
pub const own_records = [_][]const u8{
    "record.get",      "record.list",    "record.create",     "record.save",
    "record.delete",   "record.publish", "record.transition", "record.discard_changes",
    "record.purge",    "snapshot.list",  "snapshot.get",      "snapshot.take",
    "record.validate", "record.set_app",
};

pub const core = [_]Permission{
    .{
        .key = "content.read",
        .sentence = "Read the public content on your site",
        .tier = .low,
        .content = true,
        .operations = &.{
            "record.get",
            "record.list",
            "record.referrers",
            "project.impact",
        },
    },
    .{
        .key = "taxonomy.read",
        .sentence = "Read terms, tags, and folders",
        .tier = .low,
        .content = true,
        .operations = &.{
            "taxonomy.get",
            "taxonomy.list",
            "term.get",
            "term.list",
            "term.tree",
        },
    },
    .{
        .key = "schema.read",
        .sentence = "Read content type definitions",
        .tier = .low,
        .operations = &.{
            "content_type.get",
            "content_type.list",
            "custom_fields.list",
            "custom_fields.get",
            "content_type.validate",
            "record.validate",
            "taxonomy.validate",
            "term.validate",
            "custom_fields.validate",
            "user.validate",
        },
    },
    .{
        .key = "version.read",
        .sentence = "Read version history",
        .tier = .low,
        .content = true,
        .operations = &.{
            "snapshot.list",
            "snapshot.get",
        },
    },
    .{
        .key = "site.config",
        .sentence = "Read site name, description, and URL",
        .tier = .low,
    },
    .{
        .key = "users.names",
        .sentence = "See the names of people on your site",
        .tier = .low,
        .operations = &.{
            "user.options",
        },
    },
    .{
        .key = "content.drafts",
        .sentence = "Read drafts and unpublished changes",
        .tier = .medium,
        .content = true,
    },
    .{
        .key = "content.write",
        .sentence = "Create, update, and delete content",
        .tier = .medium,
        .content = true,
        .operations = &.{
            "record.create",
            "record.save",
            "record.set_app",
            "record.delete",
            "record.discard_changes",
            "snapshot.take",
            "snapshot.restore",
        },
    },
    .{
        .key = "taxonomy.write",
        .sentence = "Create, update, and delete terms",
        .tier = .medium,
        .content = true,
        .operations = &.{
            "term.create",
            "term.save",
            "term.delete",
            "term.discard_changes",
        },
    },
    .{
        .key = "release.manage",
        .sentence = "Publish, unpublish, and schedule content",
        .tier = .medium,
        .content = true,
        .operations = &.{
            "record.publish",
            "record.transition",
            "term.publish",
            "term.transition",
        },
    },
    .{
        .key = "schema.write",
        .sentence = "Modify content type definitions",
        .tier = .medium,
        .operations = &.{
            "content_type.create",
            "content_type.update",
            "content_type.delete",
            "taxonomy.create",
            "taxonomy.update",
            "taxonomy.delete",
            "custom_fields.create",
            "custom_fields.update",
            "custom_fields.delete",
        },
    },
    .{
        .key = "settings.own",
        .sentence = "Read and write its own settings",
        .tier = .medium,
    },
    .{
        .key = "content.purge",
        .sentence = "Permanently delete content and its history",
        .tier = .high,
        .content = true,
        .operations = &.{
            "record.purge",
            "term.purge",
            "snapshot.prune",
        },
    },
    .{
        .key = "users.read",
        .sentence = "Access user accounts and email addresses",
        .tier = .high,
        .operations = &.{
            "user.list",
            "user.get",
        },
    },
    .{
        .key = "users.write",
        .sentence = "Create and modify user accounts",
        .tier = .high,
        .operations = &.{
            "user.create",
            "user.update",
            "user.delete",
        },
    },
    .{
        .key = "settings.global",
        .sentence = "Read and write global settings",
        .tier = .high,
        .operations = &.{
            "settings.edit",
        },
    },
    .{
        .key = "http.fetch",
        .sentence = "Fetch data from external URLs",
        .tier = .high,
        .host = true,
    },
};

/// The operations no permission names: sessions and passwords, who may sign people in,
/// setup, who holds what, one person's saved views, an app's records handed to another.
/// No grant reaches them.
pub const never = [_][]const u8{
    "user.sign_in",       "user.sign_out",      "user.set_password",      "user.password_link",
    "sign_on.configure",  "sign_on.status",     "sign_on.redeem",         "identity.sign_in",
    "identity.configure", "identity.status",    "identity.link",          "identity.unlink",
    "identity.list",      "identity.providers", "project.init",           "role.list",
    "view.list",          "view.get",           "view.create",            "view.update",
    "view.delete",        "project.move_app",   "project.set_currencies",
};

/// A secret a plugin names is its own permission, `secret.<NAME>`, always high.
pub const secret_prefix = "secret.";

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

/// How a key a plugin asks for is tiered: its catalog entry's, `high` for a secret, `medium`
/// for a call to a plugin it depends on, and null for a key nothing provides (the plugin
/// installs without it).
pub fn tier_of(catalog: []const Permission, key: []const u8) ?Tier {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_len_max);

    if (is_secret(key)) {
        return .high;
    }

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

pub fn is_secret(key: []const u8) bool {
    std.debug.assert(key.len > 0);
    std.debug.assert(secret_prefix.len == 7);

    const name = if (std.mem.startsWith(u8, key, secret_prefix)) key[secret_prefix.len..] else "";

    if (name.len == 0 or name.len > key_len_max) {
        return false;
    }

    for (name) |char| {
        const ok = (char >= 'A' and char <= 'Z') or (char >= '0' and char <= '9') or char == '_';

        if (!ok) {
            return false;
        }
    }

    return true;
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

test "tiers: catalog keys by their entry, secrets high, unknown keys unavailable" {
    try std.testing.expectEqual(Tier.low, tier_of(&core, "content.read").?);
    try std.testing.expectEqual(Tier.high, tier_of(&core, "http.fetch").?);
    try std.testing.expectEqual(Tier.high, tier_of(&core, "secret.STRIPE_KEY").?);
    try std.testing.expect(tier_of(&core, "secret.lower") == null);
    try std.testing.expect(tier_of(&core, "secret.") == null);
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
