//! Roles are rows. Code declares them (core's, a plugin's); applying a declaration makes the
//! role the first time its owner declares it, and later adds only the grants the owner's
//! previous declaration lacked, so what the site changed or removed stays as it is.
const std = @import("std");
const store = @import("../store.zig");
const role = @import("../model/role.zig");
const Ctx = @import("context.zig").Ctx;
const Error = @import("operation.zig").Error;

const Role = role.Role;

/// Applies what `owner` declares: each role made when the owner declares it for the first
/// time, else given the grants new since the owner's previous declaration.
pub fn apply(ctx: *const Ctx, owner: []const u8, declared: []const Role) Error!void {
    std.debug.assert(owner.len > 0);
    std.debug.assert(declared.len <= role.roles_max);

    for (declared) |wanted| {
        try apply_one(ctx, owner, wanted);
    }
}

fn apply_one(ctx: *const Ctx, owner: []const u8, wanted: Role) Error!void {
    std.debug.assert(role.valid_name(wanted.name));
    std.debug.assert(wanted.grants.len <= role.grants_max);

    const before = try store.role_declarations.declared(ctx.db, owner, wanted.name);
    const previous = try store.role_declarations.patterns_of(ctx.db, ctx.arena, owner, wanted.name);
    const stored = try store.roles.get(ctx.db, ctx.arena, wanted.name) != null;

    if (!stored and !before) {
        if (try store.roles.count(ctx.db) >= role.roles_max) {
            return error.Invalid;
        }

        try store.roles.insert(ctx.db, .{
            .name = wanted.name,
            .label = wanted.label,
            .description = wanted.description,
            .owner = owner,
        }, ctx.now_ms);
        try store.role_grants.set(ctx.db, wanted.name, wanted.grants);
    } else if (stored) {
        const added = try missing_from(ctx.arena, wanted.grants, previous);

        try store.role_grants.add(ctx.db, wanted.name, added);
    }

    try store.role_declarations.replace(ctx.db, owner, wanted.name, wanted.grants);
}

/// The grants in `wanted` that `previous` lacks.
fn missing_from(
    arena: std.mem.Allocator,
    wanted: []const []const u8,
    previous: []const []const u8,
) Error![]const []const u8 {
    std.debug.assert(wanted.len <= role.grants_max);
    std.debug.assert(previous.len <= role.grants_max * 4);

    var added: std.ArrayList([]const u8) = .empty;

    for (wanted) |pattern| {
        if (!contains(previous, pattern)) {
            added.append(arena, pattern) catch return error.OutOfMemory;
        }
    }

    return added.items;
}

/// `owner` goes: the grants it added to roles it does not own leave them, unless another
/// owner declares them too, and what it declared for those roles is forgotten. Its own
/// roles stay as they are, unless chosen to go with it.
pub fn withdraw(ctx: *const Ctx, owner: []const u8, declared: []const Role) Error!void {
    std.debug.assert(owner.len > 0);
    std.debug.assert(declared.len <= role.roles_max);

    for (declared) |wanted| {
        const row = try store.roles.get(ctx.db, ctx.arena, wanted.name) orelse continue;

        if (std.mem.eql(u8, row.owner, owner)) {
            continue;
        }

        const own = try store.role_declarations.patterns_of(ctx.db, ctx.arena, owner, row.name);

        try store.role_declarations.forget(ctx.db, owner, row.name);

        const others = try store.role_declarations.patterns_for(ctx.db, ctx.arena, row.name);
        const leaving = try missing_from(ctx.arena, own, others);

        try store.role_grants.remove(ctx.db, row.name, leaving);
    }
}

/// The stored roles among `names`, each with its grants; a name no row has is left out.
pub fn held(ctx: *const Ctx, names: []const []const u8) Error![]const Role {
    std.debug.assert(names.len <= role.user_roles_max);
    std.debug.assert(ctx.now_ms >= 0);

    var found: std.ArrayList(Role) = .empty;

    for (names) |name| {
        if (name.len == 0 or name.len > role.name_len_max) {
            continue;
        }

        const row = try store.roles.get(ctx.db, ctx.arena, name) orelse continue;

        found.append(ctx.arena, .{
            .name = row.name,
            .label = row.label,
            .description = row.description,
            .grants = try store.role_grants.of(ctx.db, ctx.arena, row.name),
        }) catch return error.OutOfMemory;
    }

    return found.items;
}

/// Whether a role called `name` is stored.
pub fn exists(ctx: *const Ctx, name: []const u8) Error!bool {
    std.debug.assert(role.name_len_max > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (name.len == 0 or name.len > role.name_len_max) {
        return false;
    }

    return try store.roles.get(ctx.db, ctx.arena, name) != null;
}

/// Whether any of the roles `names` lets its holder call `operation_name`, read from the
/// database; false when it cannot be read.
pub fn allows(ctx: *const Ctx, names: []const []const u8, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(names.len <= role.user_roles_max);

    const roles = held(ctx, names) catch return false;

    return role.permit(roles, names, operation_name);
}

fn contains(list: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);
    std.debug.assert(list.len <= role.grants_max * 4);

    for (list) |one| {
        if (std.mem.eql(u8, one, wanted)) {
            return true;
        }
    }

    return false;
}

test "applying: made once, new grants added, the site's removals and edits stay" {
    var harness: @import("../sdk.zig").testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const connection = ctx.db;
    const first = [_]Role{.{
        .name = "manager",
        .label = "Store manager",
        .grants = &.{ "shop.*", "order.list" },
    }};

    try apply(&ctx, "shop", &first);
    try std.testing.expect(allows(&ctx, &.{"manager"}, "shop.refund"));

    try store.role_grants.set(connection, "manager", &.{"order.list"});
    try store.roles.update(connection, .{
        .name = "manager",
        .label = "Shop lead",
    }, 5);

    const second = [_]Role{.{
        .name = "manager",
        .label = "Store manager",
        .grants = &.{ "shop.*", "order.list", "order.refund" },
    }};

    try apply(&ctx, "shop", &second);
    try std.testing.expect(!allows(&ctx, &.{"manager"}, "shop.refund"));
    try std.testing.expect(allows(&ctx, &.{"manager"}, "order.refund"));

    const kept = (try store.roles.get(connection, ctx.arena, "manager")).?;

    try std.testing.expectEqualStrings("Shop lead", kept.label);

    const extending = [_]Role{.{
        .name = "manager",
        .label = "Ignored",
        .grants = &.{"newsletter.*"},
    }};

    try apply(&ctx, "newsletter", &extending);
    try std.testing.expect(allows(&ctx, &.{"manager"}, "newsletter.send"));

    try withdraw(&ctx, "newsletter", &extending);
    try std.testing.expect(!allows(&ctx, &.{"manager"}, "newsletter.send"));
    try std.testing.expect(allows(&ctx, &.{"manager"}, "order.refund"));

    try store.roles.delete(connection, "manager");
    try apply(&ctx, "shop", &second);
    try std.testing.expect(!try exists(&ctx, "manager"));
    try std.testing.expect(!allows(&ctx, &.{"ghost"}, "shop.refund"));
}
