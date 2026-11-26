const std = @import("std");
const public = @import("../publr/model/role.zig");

pub const name_len_max = public.name_len_max;
pub const label_len_max = public.label_len_max;
pub const description_len_max = public.description_len_max;
pub const roles_max = public.roles_max;
pub const grants_max = public.grants_max;
pub const user_roles_max = public.user_roles_max;
pub const grant_len_max = public.grant_len_max;
pub const Role = public.Role;
pub const Declared = public.Declared;
pub const owner_core = public.owner_core;
pub const admin = public.admin;
pub const editor = public.editor;
pub const contributor = public.contributor;
pub const settings_grant = public.settings_grant;

const editor_grants = [_][]const u8{
    "record.*",              "!record.purge",
    "term.*",                "!term.purge",
    "media.*",               "snapshot.*",
    "view.*",                "status.*",
    "rail.*",                "heartbeat.*",
    "content_type.get",      "content_type.list",
    "content_type.validate", "taxonomy.get",
    "taxonomy.list",         "taxonomy.validate",
    "user.options",          "project.status",
    "project.impact",        "identity.list",
    "identity.unlink",       "design.moodboard",
    "design.save_moodboard", "ai.ask",
    "ai.reply",              "ai.transcribe",
};

/// An editor's grants without putting anything live: their transitions into and out of live
/// statuses, and their published changes, wait for someone who may.
const contributor_grants = editor_grants ++ [_][]const u8{
    "!record.publish",
    "!record.transition_many",
    "!term.publish",
    "!term.transition_many",
};

pub const core = [_]Role{
    .{
        .name = admin,
        .label = "Administrator",
        .description = "Everything: content, structure, users and settings.",
        .grants = &.{"*"},
    },
    .{
        .name = editor,
        .label = "Editor",
        .description = "The content: records, terms and their history; not structure, " ++
            "users or settings.",
        .grants = &editor_grants,
    },
    .{
        .name = contributor,
        .label = "Contributor",
        .description = "Writes and edits content; publishing waits for an editor.",
        .grants = &contributor_grants,
    },
};

/// A role's name: `[a-z][a-z0-9_]*`, 1 to 32 characters.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    if (name[0] < 'a' or name[0] > 'z') {
        return false;
    }

    for (name) |char| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';

        if (!lower and !digit and char != '_') {
            return false;
        }
    }

    return true;
}

/// `*`, or a name of `[a-z_.]` that may end in `.*`, either after an optional `!`.
pub fn valid_grant(grant: []const u8) bool {
    std.debug.assert(grant_len_max > 2);

    const pattern = if (grant.len > 0 and grant[0] == '!') grant[1..] else grant;

    if (pattern.len == 0 or pattern.len > grant_len_max) {
        return false;
    }

    if (std.mem.eql(u8, pattern, "*")) {
        return true;
    }

    const namespace = std.mem.endsWith(u8, pattern, ".*");
    const name = if (namespace) pattern[0 .. pattern.len - 2] else pattern;

    if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') {
        return false;
    }

    for (name) |char| {
        const allowed = (char >= 'a' and char <= 'z') or char == '_' or char == '.';

        if (!allowed) {
            return false;
        }
    }

    return std.mem.indexOf(u8, name, "..") == null;
}

pub const matches = public.matches;
pub const permits = public.permits;

/// Whether any of the roles `held` names lets its holder call `operation_name`. A name no
/// role in `roles` carries (a plugin compiled out since) grants nothing.
pub fn permit(roles: []const Role, held: []const []const u8, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(held.len <= user_roles_max);

    for (held) |name| {
        const found = find(roles, name) orelse continue;

        if (permits(found, operation_name)) {
            return true;
        }
    }

    return false;
}

/// Whether grants make a role staff: one reaches past what visitors call. Staff and visitors
/// are two ladders, decided from the grants, never the name: a grant naming one operation
/// for untrusted callers or open to everyone (`visitors.is_visitor`), or an app's address
/// (`app.`, which no operation is named), is a visitor's; any other grant, a namespace or
/// `*` included, is staff's, as is a name no operation has now, which a plugin may bring.
pub fn staff_grants(grants: []const []const u8, visitors: anytype) bool {
    std.debug.assert(grants.len <= grants_max * 4);

    for (grants) |grant| {
        std.debug.assert(grant.len > 0);

        if (grant[0] == '!' or std.mem.startsWith(u8, grant, "app.")) {
            continue;
        }

        if (std.mem.indexOfScalar(u8, grant, '*') != null or !visitors.is_visitor(grant)) {
            return true;
        }
    }

    return false;
}

pub fn find(roles: []const Role, name: []const u8) ?*const Role {
    std.debug.assert(roles.len <= roles_max);
    std.debug.assert(name.len <= 64 << 10);

    for (roles) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) {
            return candidate;
        }
    }

    return null;
}

test "grants: exact names, namespaces at any depth, everything, and taken back" {
    try std.testing.expect(matches("*", "record.save"));
    try std.testing.expect(matches("record.*", "record.save"));
    try std.testing.expect(!matches("record.*", "records.save"));
    try std.testing.expect(matches("app.newsletter.*", "app.newsletter.subscribe"));
    try std.testing.expect(!matches("newsletter.*", "app.newsletter.subscribe"));
    try std.testing.expect(!matches("app.newsletter.*", "newsletter.list"));
    try std.testing.expect(matches("app.*", "app.newsletter.subscribe"));
    try std.testing.expect(matches("record.save", "record.save"));
    try std.testing.expect(!matches("record.save", "record.saved"));

    const writer: Role = .{
        .name = "writer",
        .label = "Writer",
        .grants = &.{ "record.*", "!record.purge" },
    };

    try std.testing.expect(permits(&writer, "record.save"));
    try std.testing.expect(!permits(&writer, "record.purge"));
    try std.testing.expect(!permits(&writer, "user.list"));
}

test "staff or visitor: decided by what the grants reach, never the role's name" {
    const Visitors = struct {
        fn is_visitor(_: @This(), name: []const u8) bool {
            const open = std.mem.eql(u8, name, "user.set_password");

            return open or std.mem.eql(u8, name, "shop.track");
        }
    };
    const visitors: Visitors = .{};

    try std.testing.expect(!staff_grants(&.{}, visitors));
    const visitor_grants = [_][]const u8{ "shop.track", "app.shop.*", "!record.save" };

    try std.testing.expect(!staff_grants(&visitor_grants, visitors));
    try std.testing.expect(staff_grants(&.{"*"}, visitors));
    try std.testing.expect(staff_grants(&.{ "*", "!user.*" }, visitors));
    try std.testing.expect(staff_grants(&.{"record.*"}, visitors));
    try std.testing.expect(staff_grants(&.{"shop.*"}, visitors));
    try std.testing.expect(staff_grants(&.{ "shop.track", "shop.refund" }, visitors));
    try std.testing.expect(staff_grants(&.{"newsletter.send"}, visitors));

    for (core) |each| {
        try std.testing.expect(staff_grants(each.grants, visitors));
    }
}

test "grants and names are well formed" {
    const good_grants = [_][]const u8{
        "*",
        "record.save",
        "record.*",
        "app.newsletter.*",
        "!record.purge",
    };

    for (good_grants) |good| {
        try std.testing.expect(valid_grant(good));
    }

    const bad_grants = [_][]const u8{
        "",      "!",            "Record.save", "record.",
        ".save", "record..save", "re cord",
    };

    for (bad_grants) |bad| {
        try std.testing.expect(!valid_grant(bad));
    }

    try std.testing.expect(valid_name("shop_manager"));
    try std.testing.expect(!valid_name("Shop"));
    try std.testing.expect(!valid_name(""));
}

test "the core roles: an editor writes content, not structure, users or settings" {
    const editors = [_][]const u8{editor};
    const admins = [_][]const u8{admin};

    try std.testing.expect(permit(&core, &editors, "record.save"));
    try std.testing.expect(permit(&core, &editors, "content_type.list"));
    try std.testing.expect(!permit(&core, &editors, "content_type.update"));
    try std.testing.expect(!permit(&core, &editors, "record.purge"));
    try std.testing.expect(!permit(&core, &editors, "user.list"));
    try std.testing.expect(permit(&core, &editors, "user.options"));
    try std.testing.expect(permit(&core, &admins, "user.list"));
    try std.testing.expect(!permit(&core, &.{"ghost"}, "record.get"));
    try std.testing.expect(!permit(&core, &.{}, "record.get"));

    for (core) |each| {
        try std.testing.expect(valid_name(each.name));

        for (each.grants) |grant| {
            try std.testing.expect(valid_grant(grant));
        }
    }
}
