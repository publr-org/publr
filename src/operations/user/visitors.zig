//! Accounts of a user type on the site, by the visitors themselves: signing up and asking for
//! a new password, each answered with a set-password link sent by email to a page of the app
//! they are on (the type's `password_page`), redeemed with `user.set_password`. Neither ever
//! says whether an account exists. Staff never use them: their links open the admin.
//!
//! A plugin managing its own type's accounts asks for `users.own`: `user.create`,
//! `user.update` and `user.delete` reach only accounts of the types it registers, never staff
//! or another plugin's.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/user/visitors.zig");
const store = @import("../../store.zig");
const user_types = @import("../../sdk/user_types.zig");
const messaging = @import("../../sdk/messaging.zig");
const registry = @import("../../server/registry.zig");
const user_operations = @import("../user.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ SignUp, RequestReset };

pub const Sent = public.Sent;

pub const SignUp = struct {
    pub const shape = public.SignUp;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.user_type.len == 0 or ctx.app.len == 0 or ctx.app_address.len == 0) {
            return error.Invalid;
        }

        try throttle(ctx, "sign-up", in.email);

        const declared = try user_types.find(ctx, in.user_type) orelse return error.Invalid;

        if (!declared.sign_up or !try user_types.opens(ctx, declared.name, ctx.app)) {
            return error.Invalid;
        }

        // A type gives visitor roles only: one giving a staff role makes no account.
        if (try user_types.staff_role_given(ctx, declared) != null) {
            return error.Invalid;
        }

        if (try user_operations.find_user(ctx, in.email)) |found| {
            if (held(found.user.user_types, declared.name)) {
                try send_link(ctx, declared, found.user.id, found.user.email, .reset);
            }

            return .{
                .sent = true,
            };
        }

        const made = try user_operations.create_pending_user(
            ctx,
            in.email,
            in.display_name,
            declared.roles,
        );
        const account = try store.users.find_by_id(ctx.db, ctx.arena, made) orelse {
            return error.NotFound;
        };

        _ = try store.user_types.add(ctx.db, made, declared.name);
        ctx.emit(user_operations.UserCreated, .{
            .user = made,
        });
        try send_link(ctx, declared, made, account.user.email, .welcome);

        return .{
            .sent = true,
        };
    }
};

pub const RequestReset = struct {
    pub const shape = public.RequestReset;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (ctx.app.len == 0 or ctx.app_address.len == 0) {
            return error.Invalid;
        }

        try throttle(ctx, "reset", in.email);

        const found = try user_operations.find_user(ctx, in.email) orelse return .{
            .sent = true,
        };
        const declared = try type_opening(ctx, found.user.user_types) orelse return .{
            .sent = true,
        };

        try send_link(ctx, declared, found.user.id, found.user.email, .reset);

        return .{
            .sent = true,
        };
    }
};

/// The first type the account holds that opens the app the visitor is on.
fn type_opening(ctx: *Ctx, held_types: []const []const u8) Error!?user_types.Declared {
    std.debug.assert(ctx.app.len > 0);
    std.debug.assert(held_types.len <= 64);

    for (held_types) |name| {
        if (!try user_types.opens(ctx, name, ctx.app)) {
            continue;
        }

        if (try user_types.find(ctx, name)) |declared| {
            return declared;
        }
    }

    return null;
}

pub fn held(held_types: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(held_types.len <= 64);

    for (held_types) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

/// Sign-in's throttle, counting every request: a few from one address, or for one email,
/// then each waits longer (a minute, five, fifteen, sixty), so nobody floods an inbox or
/// the messaging provider. Counted whether or not an account exists, so the wait tells
/// nothing either.
fn throttle(ctx: *Ctx, what: []const u8, email: []const u8) Error!void {
    std.debug.assert(what.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const address = if (ctx.address.len > 0) ctx.address else ctx.visitor;
    const subjects = [_][]const u8{
        std.mem.concat(ctx.arena, u8, &.{ what, "\naddress\n", address }) catch {
            return error.OutOfMemory;
        },
        std.mem.concat(ctx.arena, u8, &.{ what, "\nemail\n", email }) catch {
            return error.OutOfMemory;
        },
    };

    for (subjects) |subject| {
        const key = ctx.auth.throttle.key_for(subject);

        if (ctx.auth.throttle.wait_ms(key, ctx.now_ms) > 0) {
            return error.Throttled;
        }
    }

    for (subjects) |subject| {
        _ = ctx.auth.throttle.record_failure(ctx.auth.throttle.key_for(subject), ctx.now_ms);
    }
}

const Why = enum { welcome, reset };

const Words = struct {
    subject: []const u8,
    /// The email's text, `{link}` where the link goes.
    text: []const u8,
};

const link_note = "\n\n{link}\n\nThe link works once, within an hour. If you did not ask " ++
    "for it, ignore this email.\n";

fn words_of(why: Why) Words {
    return switch (why) {
        .welcome => .{
            .subject = "Finish making your account",
            .text = "Open this link to choose your password:" ++ link_note,
        },
        .reset => .{
            .subject = "Set a new password",
            .text = "Open this link to set a new password:" ++ link_note,
        },
    };
}

/// The language the email is in: the page's the visitor asked from, else the account's own
/// choice, else the site's.
fn locale_of(ctx: *Ctx, user_id: []const u8) Error![]const u8 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(ctx.address_code.len <= 64);

    if (ctx.address_code.len > 0) {
        return ctx.address_code;
    }

    return @import("language.zig").person_speaks(ctx, user_id);
}

/// A set-password link to the type's page on the app, sent by email through whichever
/// messaging provider covers it.
fn send_link(
    ctx: *Ctx,
    declared: user_types.Declared,
    user_id: []const u8,
    email: []const u8,
    why: Why,
) Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(ctx.app_address.len > 0);

    const page = std.mem.concat(ctx.arena, u8, &.{
        std.mem.trimEnd(u8, ctx.app_address, "/"),
        declared.password_page,
    }) catch return error.OutOfMemory;
    const link = try user_operations.issue_link_at(ctx, user_id, page);
    const words = words_of(why);
    const locale = try locale_of(ctx, user_id);
    const values = [_]sdk.context.Message.Value{.{
        .name = "link",
        .value = link.path,
    }};
    const subject = ctx.say(locale, .{
        .id = words.subject,
    }) catch return error.OutOfMemory;
    const text = ctx.say(locale, .{
        .id = words.text,
        .values = &values,
    }) catch return error.OutOfMemory;

    ctx.emit(messaging.Email, .{
        .to = email,
        .subject = subject,
        .text = text,
    });
}

/// Whether the caller is a plugin holding `users.own` and not `users.write`: it reaches only
/// accounts of the types it registers.
pub fn own_only(ctx: *Ctx) bool {
    std.debug.assert(ctx.now_ms >= 0);

    const access = switch (ctx.caller) {
        .plugin => |caller| caller.access,
        else => if (ctx.plugin.len > 0) registry.SDK.compiled_access(ctx.plugin) else null,
    } orelse return false;

    return access.held_of("users.write") == null and access.held_of("users.own") != null;
}

/// Whether the caller is a plugin reading accounts through `users.own` alone (neither
/// `users.read` nor `users.write`).
fn reads_own_only(ctx: *Ctx) bool {
    std.debug.assert(ctx.now_ms >= 0);

    const access = switch (ctx.caller) {
        .plugin => |caller| caller.access,
        else => if (ctx.plugin.len > 0) registry.SDK.compiled_access(ctx.plugin) else null,
    } orelse return false;
    const reads_all = access.held_of("users.read") != null or
        access.held_of("users.write") != null;

    return !reads_all and access.held_of("users.own") != null;
}

/// Refuses a plugin reading accounts through `users.own` alone a list of a type it does not
/// register: staff's, or another plugin's.
pub fn refuse_unread_type(ctx: *Ctx, user_type: []const u8) Error!void {
    std.debug.assert(user_type.len <= 64);

    if (!reads_own_only(ctx)) {
        return;
    }

    return types_of_its_own(ctx, user_type);
}

/// Refuses a plugin reading accounts through `users.own` alone an account holding none of
/// the types it registers.
pub fn refuse_unread_account(ctx: *Ctx, user: store.users.User) Error!void {
    std.debug.assert(user.id.len > 0);

    if (!reads_own_only(ctx)) {
        return;
    }

    for (user.user_types) |name| {
        if (try its_own(ctx, name)) {
            return;
        }
    }

    return error.Denied;
}

/// Refuses a plugin holding only `users.own` a new account of a type it does not register.
pub fn refuse_other_type(ctx: *Ctx, user_type: []const u8) Error!void {
    std.debug.assert(user_type.len <= 64);

    if (!own_only(ctx)) {
        return;
    }

    return types_of_its_own(ctx, user_type);
}

/// Refuses a plugin holding only `users.own` changing, removing or issuing a link for an
/// account that is not wholly its own: staff (an administrator who is also a customer), or
/// one holding another plugin's type. On those it only adds or takes its own type.
pub fn refuse_other_account(ctx: *Ctx, user: store.users.User) Error!void {
    std.debug.assert(user.id.len > 0);

    if (!own_only(ctx)) {
        return;
    }

    if (try user_types.staff(ctx, user.user_types, user.roles)) {
        return error.Denied;
    }

    for (user.user_types) |name| {
        try types_of_its_own(ctx, name);
    }
}

/// Refuses a plugin holding only `users.own` giving a role none of its types gives: it
/// never makes staff.
pub fn refuse_roles_not_its_own(ctx: *Ctx, roles: []const []const u8) Error!void {
    std.debug.assert(roles.len <= 64);

    if (!own_only(ctx)) {
        return;
    }

    const running = switch (ctx.caller) {
        .plugin => |caller| caller.name,
        else => ctx.plugin,
    };

    std.debug.assert(running.len > 0);

    next_role: for (roles) |name| {
        for (try user_types.all(ctx)) |declared| {
            if (std.mem.eql(u8, declared.plugin, running) and held(declared.roles, name)) {
                continue :next_role;
            }
        }

        return error.Denied;
    }
}

/// Refused unless `user_type` is one the calling plugin registers.
pub fn types_of_its_own(ctx: *Ctx, user_type: []const u8) Error!void {
    std.debug.assert(user_type.len <= 64);

    if (!try its_own(ctx, user_type)) {
        return error.Denied;
    }
}

/// Whether `user_type` is one the calling plugin registers.
fn its_own(ctx: *Ctx, user_type: []const u8) Error!bool {
    std.debug.assert(user_type.len <= 64);

    if (user_type.len == 0) {
        return false;
    }

    const declared = try user_types.find(ctx, user_type) orelse return false;
    const running = switch (ctx.caller) {
        .plugin => |caller| caller.name,
        else => ctx.plugin,
    };

    std.debug.assert(declared.plugin.len > 0);

    return std.mem.eql(u8, declared.plugin, running);
}
