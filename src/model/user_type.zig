//! A type of user a plugin registers (customers, members, students): people with accounts on
//! the site, on the one identity system, who are never staff. Pure rules on a declaration and
//! on the apps a type may sign in to; the accounts are `user.*`'s.
const std = @import("std");
const role = @import("role.zig");

pub const name_len_max: u32 = 32;
pub const label_len_max: u32 = 64;
pub const types_max: u32 = 32;
pub const apps_max: u32 = 32;
pub const app_len_max: u32 = 64;

pub const Declared = @import("../publr/model/user_type.zig").Declared;

/// What an administrator chose for a type, kept under `setting_prefix ++ name`.
pub const Setting = struct {
    apps: []const []const u8 = &.{},
};

pub const setting_prefix = "user_type.";

/// The names no type may take: staff is no type, and roles speak for themselves.
const reserved = [_][]const u8{ "staff", role.admin, role.editor };

pub fn valid_name(name: []const u8) bool {
    comptime std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    if (!std.ascii.isLower(name[0])) {
        return false;
    }

    for (name) |char| {
        const allowed = std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '_';

        if (!allowed) {
            return false;
        }
    }

    for (reserved) |taken| {
        if (std.mem.eql(u8, taken, name)) {
            return false;
        }
    }

    return true;
}

/// Why a list of declarations cannot stand, or null.
pub fn problem(declared: []const Declared) ?[]const u8 {
    std.debug.assert(name_len_max > 0);

    if (declared.len > types_max) {
        return "at most 32 user types";
    }

    for (declared, 0..) |one, index| {
        if (!valid_name(one.name)) {
            return "a user type's name is [a-z][a-z0-9_]*, 1 to 32 characters, " ++
                "not staff, admin or editor";
        }

        if (one.label.len == 0 or one.label.len > label_len_max) {
            return "a user type's label is 1 to 64 characters";
        }

        if (apps_problem(one.apps)) |found| {
            return found;
        }

        if (one.sign_up and one.roles.len == 0) {
            return "a user type visitors sign up to names the roles their accounts hold";
        }

        if (roles_problem(one.roles)) |found| {
            return found;
        }

        if (!page_path(one.password_page)) {
            return "a user type's password page is a path on its app: `/account/password`";
        }

        for (declared[index + 1 ..]) |other| {
            if (std.mem.eql(u8, one.name, other.name)) {
                return "two user types share a name";
            }
        }
    }

    return null;
}

/// Core's staff roles: no type gives one. Whether any other role is staff its grants say,
/// checked where they are known (`sdk/user_types.zig`).
const staff_roles = [_][]const u8{ role.admin, role.editor, role.contributor };

/// Why the roles a type gives cannot stand, or null: visitor roles only, each a role's name.
fn roles_problem(roles: []const []const u8) ?[]const u8 {
    std.debug.assert(roles.len <= 1 << 16);

    if (roles.len > role.user_roles_max) {
        return "a user type gives at most 16 roles";
    }

    for (roles) |name| {
        if (!role.valid_name(name)) {
            return "a user type's role is a role's name: [a-z][a-z0-9_]*";
        }

        for (staff_roles) |staff| {
            if (std.mem.eql(u8, staff, name)) {
                return "a user type gives visitor roles only, never admin, editor or " ++
                    "contributor: its people never reach the admin";
            }
        }
    }

    return null;
}

/// A path on the app: one leading slash, no other host, no query.
fn page_path(path: []const u8) bool {
    std.debug.assert(path.len <= 1 << 16);

    if (path.len == 0 or path.len > 128 or path[0] != '/') {
        return false;
    }

    if (path.len > 1 and (path[1] == '/' or path[1] == '\\')) {
        return false;
    }

    for (path) |char| {
        if (char <= ' ' or char == '?' or char == '#') {
            return false;
        }
    }

    return true;
}

/// Why a list of app names cannot be a type's apps, or null.
pub fn apps_problem(apps: []const []const u8) ?[]const u8 {
    std.debug.assert(app_len_max > 0);

    if (apps.len > apps_max) {
        return "a user type names at most 32 apps";
    }

    for (apps) |app| {
        if (app.len == 0 or app.len > app_len_max) {
            return "an app's name is 1 to 64 characters";
        }
    }

    return null;
}

/// Whether `apps` lets its people sign in to `app`.
pub fn opens(apps: []const []const u8, app: []const u8) bool {
    std.debug.assert(apps.len <= apps_max);

    if (app.len == 0) {
        return false;
    }

    for (apps) |each| {
        if (std.mem.eql(u8, each, app)) {
            return true;
        }
    }

    return false;
}

test "a user type is named, labelled, and opens only the apps it names" {
    const customer: Declared = .{
        .name = "customer",
        .label = "Customer",
        .apps = &.{"shop"},
    };

    try std.testing.expect(problem(&.{customer}) == null);
    try std.testing.expect(opens(customer.apps, "shop"));
    try std.testing.expect(!opens(customer.apps, "www"));
    try std.testing.expect(!opens(customer.apps, ""));

    var staff = customer;

    staff.name = "staff";
    try std.testing.expect(problem(&.{staff}) != null);

    var bad = customer;

    bad.name = "Customer";
    try std.testing.expect(problem(&.{bad}) != null);

    var unlabelled = customer;

    unlabelled.label = "";
    try std.testing.expect(problem(&.{unlabelled}) != null);
    try std.testing.expect(problem(&.{ customer, customer }) != null);
    try std.testing.expect(apps_problem(&.{""}) != null);

    var open = customer;

    open.sign_up = true;
    try std.testing.expect(problem(&.{open}) != null);
    open.roles = &.{"customer"};
    try std.testing.expect(problem(&.{open}) == null);
    open.password_page = "//elsewhere";
    try std.testing.expect(problem(&.{open}) != null);
}

test "a user type gives visitor roles only: never admin, editor or contributor" {
    const staff_names = [_][]const u8{ role.admin, role.editor, role.contributor };

    for (staff_names) |name| {
        const given: Declared = .{
            .name = "member",
            .label = "Member",
            .sign_up = true,
            .roles = &.{ "member", name },
        };

        try std.testing.expect(problem(&.{given}) != null);
    }

    const visitor: Declared = .{
        .name = "member",
        .label = "Member",
        .sign_up = true,
        .roles = &.{"member"},
    };
    var odd = visitor;

    odd.roles = &.{"Member"};
    try std.testing.expect(problem(&.{visitor}) == null);
    try std.testing.expect(problem(&.{odd}) != null);
}
