const std = @import("std");

pub const name_len_max: u32 = 32;
pub const label_len_max: u32 = 64;
pub const description_len_max: u32 = 200;
pub const roles_max: u32 = 64;
pub const grants_max: u32 = 128;
/// How many roles one account holds.
pub const user_roles_max: u32 = 16;
pub const grant_len_max: u32 = 72;

/// What an account holding the role may call. A grant is an operation's name
/// (`record.save`), a namespace and everything under it (`record.*`,
/// `app.newsletter.*`), or `*`; a grant starting with `!` takes names back from this role.
/// Nothing is granted that no grant names.
pub const Role = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8 = "",
    grants: []const []const u8,
};

pub const admin = "admin";
pub const editor = "editor";
/// Not an operation but what a role needs to read and write settings singletons (records
/// of a `settings` type), which every record operation otherwise reaches. Administrators
/// hold it through `*`.
pub const settings_grant = "settings.edit";

const editor_grants = [_][]const u8{
    "record.*",              "!record.purge",
    "term.*",                "!term.purge",
    "snapshot.*",            "view.*",
    "status.*",              "heartbeat.*",
    "content_type.get",      "content_type.list",
    "content_type.validate", "taxonomy.get",
    "taxonomy.list",         "taxonomy.validate",
    "user.options",          "project.status",
    "project.impact",        "identity.list",
    "identity.unlink",
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

/// Whether `pattern` (a grant without its `!`) names `operation_name`.
pub fn matches(pattern: []const u8, operation_name: []const u8) bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(operation_name.len > 0);

    if (std.mem.eql(u8, pattern, "*")) {
        return true;
    }

    if (std.mem.endsWith(u8, pattern, ".*")) {
        const namespace = pattern[0 .. pattern.len - 1];

        return std.mem.startsWith(u8, operation_name, namespace);
    }

    return std.mem.eql(u8, pattern, operation_name);
}

/// Whether one role's grants let it call `operation_name`: a grant names it and no `!`
/// grant takes it back.
pub fn permits(role: *const Role, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(role.grants.len <= grants_max);

    var granted = false;

    for (role.grants) |grant| {
        if (grant[0] == '!') {
            if (matches(grant[1..], operation_name)) {
                return false;
            }
        } else if (matches(grant, operation_name)) {
            granted = true;
        }
    }

    return granted;
}

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

/// The core roles with the ones the plugins declare: a new name is a new role; a name
/// already there adds its grants to that role (a plugin giving editors its own operations).
pub fn merge(comptime base: []const Role, comptime added: []const Role) []const Role {
    comptime {
        std.debug.assert(base.len > 0);
        std.debug.assert(added.len <= roles_max);

        var roles: []const Role = base;

        for (added) |role| {
            var extended = false;
            var next: []const Role = &.{};

            for (roles) |existing| {
                if (std.mem.eql(u8, existing.name, role.name)) {
                    next = next ++ &[_]Role{.{
                        .name = existing.name,
                        .label = existing.label,
                        .description = existing.description,
                        .grants = existing.grants ++ role.grants,
                    }};
                    extended = true;
                } else {
                    next = next ++ &[_]Role{existing};
                }
            }

            roles = if (extended) next else roles ++ &[_]Role{role};
        }

        return roles;
    }
}

/// The problem with a set of roles, or null when every one is well formed and unique.
pub fn problem(roles: []const Role) ?[]const u8 {
    std.debug.assert(roles_max > 0);

    if (roles.len > roles_max) {
        return "more roles than a project holds";
    }

    for (roles, 0..) |role, index| {
        if (!valid_name(role.name)) {
            return "a role's name is [a-z][a-z0-9_]*, 1 to 32 characters";
        }

        if (role.label.len == 0 or role.label.len > label_len_max) {
            return "a role's label is 1 to 64 characters";
        }

        if (role.description.len > description_len_max or role.grants.len > grants_max) {
            return "a role's description is up to 200 characters and its grants up to 128";
        }

        for (role.grants) |grant| {
            if (!valid_grant(grant)) {
                return "a grant is `*`, an operation, or a namespace ending in `.*`";
            }
        }

        for (roles[index + 1 ..]) |other| {
            if (std.mem.eql(u8, role.name, other.name)) {
                return "two roles share a name";
            }
        }
    }

    return null;
}

pub fn Registry(comptime roles: []const Role) type {
    comptime {
        if (problem(roles)) |message| {
            @compileError("roles: " ++ message);
        }
    }

    return struct {
        pub const all = roles;

        pub fn get(name: []const u8) ?*const Role {
            comptime std.debug.assert(roles.len > 0);

            return find(all, name);
        }

        /// Whether any of `names` lets its holder call `operation_name`.
        pub fn allows(names: []const []const u8, operation_name: []const u8) bool {
            comptime std.debug.assert(roles.len > 0);

            return permit(all, names, operation_name);
        }
    };
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
    const Roles = Registry(&core);
    const editors = [_][]const u8{editor};
    const admins = [_][]const u8{admin};

    try std.testing.expect(Roles.allows(&editors, "record.save"));
    try std.testing.expect(Roles.allows(&editors, "content_type.list"));
    try std.testing.expect(!Roles.allows(&editors, "content_type.update"));
    try std.testing.expect(!Roles.allows(&editors, "record.purge"));
    try std.testing.expect(!Roles.allows(&editors, "user.list"));
    try std.testing.expect(Roles.allows(&editors, "user.options"));
    try std.testing.expect(Roles.allows(&admins, "user.list"));
    try std.testing.expect(!Roles.allows(&.{"ghost"}, "record.get"));
    try std.testing.expect(!Roles.allows(&.{}, "record.get"));
}

test "a plugin's role is new, or adds its grants to one of the same name" {
    const added = [_]Role{
        .{ .name = "subscriber", .label = "Subscriber", .grants = &.{"app.newsletter.*"} },
        .{ .name = editor, .label = "Editor", .grants = &.{"newsletter.*"} },
    };
    const Roles = Registry(comptime merge(&core, &added));

    try std.testing.expectEqual(@as(usize, 3), Roles.all.len);
    try std.testing.expect(Roles.allows(&.{editor}, "newsletter.list"));
    try std.testing.expect(Roles.allows(&.{editor}, "record.save"));
    try std.testing.expect(Roles.allows(&.{"subscriber"}, "app.newsletter.subscribe"));
    try std.testing.expect(!Roles.allows(&.{"subscriber"}, "newsletter.list"));
    try std.testing.expect(!Roles.allows(&.{"subscriber"}, "record.get"));
    try std.testing.expectEqualStrings("Editor", Roles.get(editor).?.label);
}

test "problems: a bad name, a bad grant, a duplicate" {
    try std.testing.expect(problem(&core) == null);

    const bad_name = [_]Role{.{ .name = "X", .label = "X", .grants = &.{} }};
    const bad_grant = [_]Role{.{ .name = "x", .label = "X", .grants = &.{"x."} }};
    const twice = [_]Role{
        .{ .name = "x", .label = "X", .grants = &.{} },
        .{ .name = "x", .label = "X", .grants = &.{} },
    };

    try std.testing.expect(problem(&bad_name) != null);
    try std.testing.expect(problem(&bad_grant) != null);
    try std.testing.expect(problem(&twice) != null);
}
