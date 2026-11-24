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
const store = @import("../../store.zig");
const user_types = @import("../../sdk/user_types.zig");
const visitors = @import("visitors.zig");
const user_operations = @import("../user.zig");
const role = @import("../../model/role.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ AddType, RemoveType };

pub const TypeIn = struct {
    user: []const u8,
    user_type: []const u8,
};

pub const TypeOut = struct {
    user_id: []const u8,
    user_types: []const []const u8,
    roles: []const []const u8,
};

const example_in: TypeIn = .{
    .user = "ada@example.com",
    .user_type = "customer",
};

const in_docs: sdk.operation.Docs(TypeIn) = .{
    .user = "The account's id or email",
    .user_type = "A type of user a plugin registers (`customer`, `user_type list`)",
};

const out_docs: sdk.operation.Docs(TypeOut) = .{
    .user_id = "The account's id",
    .user_types = "The types the account holds now",
    .roles = "The roles the account holds now",
};

pub const AddType = struct {
    pub const name = "user.add_type";
    pub const description = "Give an account a type of user (an administrator becomes a customer)";
    pub const details =
        \\Administrators, and plugins: `users.write`, or `users.own` for the types the plugin
        \\registers, on any account. The account gets the type and the roles the type gives
        \\(`.roles`); its other roles, its password and its sign-ins stay. It may then sign
        \\in to the apps the type opens. Giving a type it holds changes nothing. Fails as
        \\invalid for a type no plugin registers.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = TypeIn;
    pub const Out = TypeOut;
    pub const example = example_in;
    pub const example_out: TypeOut = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .user_types = &.{"customer"},
        .roles = &.{ "admin", "customer" },
    };
    pub const field_docs = in_docs;
    pub const output_docs = out_docs;

    pub fn run(ctx: *Ctx, in: TypeIn, _: *const Grant) Error!TypeOut {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.caller != .anonymous);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const declared = try declared_of(ctx, in.user_type);

        // A type gives visitor roles only: one giving a staff role gives nothing.
        if (try user_types.staff_role_given(ctx, declared) != null) {
            return error.Denied;
        }

        if (!try store.user_types.add(ctx.db, found.user.id, declared.name)) {
            return answer(ctx, found.user.id);
        }

        var roles: std.ArrayList([]const u8) = .empty;

        try roles.appendSlice(ctx.arena, found.user.roles);

        for (declared.roles) |given| {
            if (!visitors.held(roles.items, given)) {
                try roles.append(ctx.arena, given);
            }
        }

        try set_roles(ctx, found.user, roles.items);

        return answer(ctx, found.user.id);
    }
};

pub const RemoveType = struct {
    pub const name = "user.remove_type";
    pub const description = "Take a type of user from an account";
    pub const details =
        \\Administrators, and plugins: `users.write`, or `users.own` for the types the plugin
        \\registers, on any account. The account loses the type and the roles it gave, but
        \\keeps any of them another type it holds gives, and every other role, its password
        \\and its sign-ins. An account left with no type and no role keeps signing in to
        \\nothing until it is given one. Taking a type it does not hold changes nothing.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = TypeIn;
    pub const Out = TypeOut;
    pub const example = example_in;
    pub const example_out: TypeOut = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .user_types = &.{},
        .roles = &.{"admin"},
    };
    pub const field_docs = in_docs;
    pub const output_docs = out_docs;

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
            const given = visitors.held(declared.roles, held_role);

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

    if (visitors.own_only(ctx)) {
        try visitors.types_of_its_own(ctx, declared.name);
    }

    return declared;
}

fn given_by_any(ctx: *Ctx, held_types: []const []const u8, name: []const u8) Error!bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(held_types.len <= store.user_types.held_max);

    for (held_types) |type_name| {
        const declared = try user_types.find(ctx, type_name) orelse continue;

        if (visitors.held(declared.roles, name)) {
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
