//! Roles as plugins declare and read them: a name people can be given, its grants, and
//! whether a grant lets its holder call an operation.
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

/// A role a plugin declares: a name people can be given, and how it reads. What it may call
/// its operations say (`.authorize`), and administrators grant the rest in the roles editor.
pub const Declared = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8 = "",
};

/// Who declared core's roles, in `roles.owner`; a plugin's is its name, the site's empty.
pub const owner_core = "core";

pub const admin = "admin";
pub const editor = "editor";
pub const contributor = "contributor";
/// Not an operation but what a role needs to read and write settings singletons (records
/// of a `settings` type), which every record operation otherwise reaches. Administrators
/// hold it through `*`.
pub const settings_grant = "settings.edit";

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
