//! Giving an account a type of user, or taking one: an account holds any number of them,
//! staff accounts included (an administrator who is also a customer of the shop). A type
//! brings the roles it gives (`.roles`) and takes them when it goes, unless another type the
//! account holds gives them too. The admin is reached by roles alone, so neither ever opens
//! or closes it for staff.
//!
//! A plugin holding `users.own` gives and takes only its own types, on any account: it never
//! touches another role, a password or a sign-in.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/user/types.zig");
const store = @import("../../store.zig");
const user_types = @import("../../sdk/user_types.zig");
const members = @import("members.zig");
const user_operations = @import("../user.zig");
const role = @import("../../model/role.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ AddType, RemoveType };

pub const TypeIn = public.TypeIn;

pub const TypeOut = public.TypeOut;

pub const AddType = struct {
    pub const shape = public.AddType;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: TypeIn, _: *const Grant) Error!TypeOut {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.caller != .anonymous);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const declared = try declared_of(ctx, in.user_type);

        // A type gives member roles only: one giving a staff role gives nothing.
        if (try user_types.staff_role_given(ctx, declared) != null) {
            return error.Denied;
        }

        if (!try store.user_types.add(ctx.db, found.user.id, declared.name)) {
            return answer(ctx, found.user.id);
        }

        var roles: std.ArrayList([]const u8) = .empty;

        try roles.appendSlice(ctx.arena, found.user.roles);

        for (declared.roles) |given| {
            if (!members.held(roles.items, given)) {
                try roles.append(ctx.arena, given);
            }
        }

        try set_roles(ctx, found.user, roles.items);

        return answer(ctx, found.user.id);
    }
};

pub const RemoveType = struct {
    pub const shape = public.RemoveType;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: TypeIn, _: *const Grant) Error!TypeOut {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.caller != .anonymous);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const declared = try declared_of(ctx, in.user_type);

        if (!try store.user_types.remove(ctx.db, found.user.id, declared.name)) {
            return answer(ctx, found.user.id);
        }

        const kept_types = try store.user_types.of(ctx.db, ctx.arena, found.user.id);
        var roles: std.ArrayList([]const u8) = .empty;

        for (found.user.roles) |held_role| {
            const given = members.held(declared.roles, held_role);

            if (!given or try given_by_any(ctx, kept_types, held_role)) {
                try roles.append(ctx.arena, held_role);
            }
        }

        try set_roles(ctx, found.user, roles.items);

        return answer(ctx, found.user.id);
    }
};

/// The type registered under `name`, when the caller may give or take it.
fn declared_of(ctx: *Ctx, name: []const u8) Error!user_types.Declared {
    std.debug.assert(name.len <= 1 << 16);
    std.debug.assert(ctx.now_ms >= 0);

    if (name.len == 0) {
        return error.Invalid;
    }

    const declared = try user_types.find(ctx, name) orelse return error.Invalid;

    if (members.own_only(ctx)) {
        try members.types_of_its_own(ctx, declared.name);
    }

    return declared;
}

fn given_by_any(ctx: *Ctx, held_types: []const []const u8, name: []const u8) Error!bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(held_types.len <= store.user_types.held_max);

    for (held_types) |type_name| {
        const declared = try user_types.find(ctx, type_name) orelse continue;

        if (members.held(declared.roles, name)) {
            return true;
        }
    }

    return false;
}

/// The account's roles replaced, its name kept; the last administrator keeps `admin`, which
/// neither operation ever takes.
fn set_roles(ctx: *Ctx, user: store.users.User, roles: []const []const u8) Error!void {
    std.debug.assert(user.id.len > 0);
    std.debug.assert(roles.len <= role.user_roles_max * 2);

    if (roles.len > role.user_roles_max) {
        return error.Invalid;
    }

    try user_operations.staff.refuse_from_plugin(ctx, user.roles, roles);

    const changed = try store.users.update(
        ctx.db,
        user.id,
        user.display_name,
        roles,
        ctx.now_ms,
    );

    std.debug.assert(changed);
}

fn answer(ctx: *Ctx, user_id: []const u8) Error!TypeOut {
    std.debug.assert(user_id.len > 0);

    const account = try store.users.find_by_id(ctx.db, ctx.arena, user_id) orelse {
        return error.NotFound;
    };

    std.debug.assert(account.user.id.len > 0);

    return .{
        .user_id = account.user.id,
        .user_types = account.user.user_types,
        .roles = account.user.roles,
    };
}
