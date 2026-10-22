const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const role = @import("../../model/role.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Row = store.roles.Row;
const Root = store.trash_copy.Root;

/// A role as the role operations answer it.
pub const Listed = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8 = "",
    /// `core`, the plugin that declared it first, or empty for one the site made.
    owner: []const u8 = "",
    grants: []const []const u8,
    /// What code declares for it, core and every plugin together; empty for the site's own.
    declared: []const []const u8 = &.{},
    /// How many accounts hold it.
    holders: u32 = 0,
    /// Its grants are not what code declares for it (`role reset` puts them back).
    changed: bool = false,
    /// `admin`: everything, never changed or removed.
    locked: bool = false,
};

pub const locked: sdk.operation.Failure = .{
    .name = "Locked",
    .status = 409,
    .message = "Administrator holds everything and never changes",
};

pub const only_role: sdk.operation.Failure = .{
    .name = "OnlyRole",
    .status = 409,
    .message = "It is some account's only role: give them another first",
};

pub const example: Listed = .{
    .name = "editor",
    .label = "Editor",
    .description = "The content: records, terms and their history.",
    .owner = role.owner_core,
    .grants = &.{ "record.*", "!record.purge" },
    .declared = &.{ "record.*", "!record.purge" },
    .holders = 3,
};

pub fn find(ctx: *Ctx, name: []const u8) Error!Row {
    std.debug.assert(name.len <= 4096);
    std.debug.assert(ctx.now_ms >= 0);

    if (!role.valid_name(name)) {
        return error.NotFound;
    }

    return try store.roles.get(ctx.db, ctx.arena, name) orelse error.NotFound;
}

/// The role `name`, when the site may change it: any but `admin`.
pub fn changeable(ctx: *Ctx, name: []const u8) Error!Row {
    std.debug.assert(name.len <= 4096);
    std.debug.assert(role.admin.len > 0);

    const found = try find(ctx, name);

    if (std.mem.eql(u8, found.name, role.admin)) {
        return ctx.fail(locked);
    }

    return found;
}

pub fn listed(ctx: *Ctx, row: Row) Error!Listed {
    std.debug.assert(row.name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const grants = try store.role_grants.of(ctx.db, ctx.arena, row.name);
    const declared = try store.role_declarations.patterns_for(ctx.db, ctx.arena, row.name);

    return .{
        .name = row.name,
        .label = row.label,
        .description = row.description,
        .owner = row.owner,
        .grants = grants,
        .declared = declared,
        .holders = try store.user_roles.holders(ctx.db, row.name),
        .changed = row.owner.len > 0 and !same_set(grants, declared),
        .locked = std.mem.eql(u8, row.name, role.admin),
    };
}

/// A label, a description and grants a role may have; invalid otherwise.
pub fn check(row: Row, grants: []const []const u8) Error!void {
    std.debug.assert(row.name.len > 0);
    std.debug.assert(role.grants_max > 0);

    const label = std.mem.trim(u8, row.label, " ");

    if (label.len == 0 or row.label.len > role.label_len_max) {
        return error.Invalid;
    }

    if (row.description.len > role.description_len_max or grants.len > role.grants_max) {
        return error.Invalid;
    }

    for (grants) |grant| {
        if (!role.valid_grant(grant)) {
            return error.Invalid;
        }
    }
}

/// What the trash keeps of a role: its row, which brings its grants, and its holders.
pub fn roots_of(ctx: *Ctx, name: []const u8) Error![]const Root {
    std.debug.assert(role.valid_name(name));
    std.debug.assert(ctx.now_ms >= 0);

    const one = [_][]const u8{name};
    const keys = std.json.Stringify.valueAlloc(ctx.arena, &one, .{}) catch {
        return error.OutOfMemory;
    };
    const roots = ctx.arena.alloc(Root, 2) catch return error.OutOfMemory;

    roots[0] = .{
        .table = "roles",
        .column = "name",
        .keys = keys,
    };
    roots[1] = .{
        .table = "user_roles",
        .column = "role",
        .keys = keys,
    };

    return roots;
}

/// Deletes the role and takes it from its holders; what code declared stays, so it is
/// never made again.
pub fn drop(ctx: *Ctx, name: []const u8) Error!void {
    std.debug.assert(role.valid_name(name));
    std.debug.assert(ctx.db.transaction_depth >= 1);

    try store.user_roles.forget_role(ctx.db, name);
    try store.roles.delete(ctx.db, name);
}

fn same_set(left: []const []const u8, right: []const []const u8) bool {
    std.debug.assert(left.len <= role.grants_max);
    std.debug.assert(right.len <= role.grants_max * 4);

    if (left.len != right.len) {
        return false;
    }

    for (left) |one| {
        const found = for (right) |other| {
            if (std.mem.eql(u8, one, other)) {
                break true;
            }
        } else false;

        if (!found) {
            return false;
        }
    }

    return true;
}
