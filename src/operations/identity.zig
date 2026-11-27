const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/identity.zig");
const publr_auth = @import("../sdk/auth_events.zig");
const store = @import("../store.zig");
const model = @import("../model/identity.zig");
const role = @import("../model/role.zig");
const registry = @import("../server/registry.zig");
const signing = @import("signed.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const open_sign_up_key = "identity.open_sign_up";

pub const namespace = public.namespace;

pub const Input = public.Input;

/// The identity as the model sees it; `Invalid` when the provider or id is malformed.
pub fn identity_of(in: Input) Error!model.Identity {
    std.debug.assert(model.provider_len_max > 0);
    std.debug.assert(model.id_len_max > 0);

    const identity: model.Identity = .{
        .provider = in.provider,
        .id = in.id,
        .email = in.email,
        .verified = in.verified,
        .name = in.name,
        .avatar = in.avatar,
    };

    if (!model.valid(identity)) {
        return error.Invalid;
    }

    return identity;
}

pub const example_in = public.example_in;
pub const in_docs = public.in_docs;

pub const SignIn = struct {
    pub const shape = public.SignIn;
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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        const identity = try identity_of(in);
        // Only the system speaks for the proxy's standing rule: nobody else makes an account
        // with roles by signing in.
        if (in.new_account_roles != null and ctx.caller != .system) {
            return error.Denied;
        }

        const resolved = try resolve(ctx, identity, in.new_account_roles);
        const found = try store.users.find_by_id(ctx.db, ctx.arena, resolved.user_id) orelse {
            return error.BadCredentials;
        };

        std.debug.assert(found.user.active);

        if (resolved.created) {
            try signing.signed_up(ctx, found.user, identity.provider);
        }

        try signing.before(ctx, found.user, identity.provider);
        _ = try store.sessions.cleanup(ctx.db, ctx.now_ms);
        const user_id = found.user.id;
        const created = try store.sessions.create(ctx.db, ctx.io, ctx.arena, user_id, ctx.now_ms);

        try signing.after(ctx, found.user, identity.provider);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = found.user.id,
            .roles = found.user.roles,
            .expires_at = created.session.expires_at,
            .created = resolved.created,
            .linked = resolved.linked,
        };
    }
};

const Resolved = struct {
    user_id: []const u8,
    created: bool,
    linked: bool = false,
};

/// Whose identity this is, linking or creating on the way; `BadCredentials` when nobody's.
fn resolve(
    ctx: *Ctx,
    identity: model.Identity,
    new_account_roles: ?[]const []const u8,
) Error!Resolved {
    std.debug.assert(ctx.caller != .anonymous);
    std.debug.assert(model.valid(identity));

    if (try store.identities.find(ctx.db, ctx.arena, identity.provider, identity.id)) |row| {
        const email = identity.email;

        try store.identities.touch(ctx.db, identity.provider, identity.id, email, ctx.now_ms);

        return .{
            .user_id = row.user_id,
            .created = false,
        };
    }

    const email = verified_email(ctx, identity) orelse {
        ctx.keep(publr_auth.IdentityRefused, .{
            .provider = identity.provider,
            .why = "unverified",
        });

        return error.BadCredentials;
    };

    if (try store.users.find_by_email(ctx.db, ctx.arena, email)) |existing| {
        try link(ctx, existing.user.id, identity);

        return .{
            .user_id = existing.user.id,
            .created = false,
            .linked = true,
        };
    }

    if (new_account_roles) |roles| {
        return new_member(ctx, identity, email, roles);
    }

    const open_role = try store.settings.get(ctx.db, ctx.arena, open_sign_up_key) orelse {
        ctx.keep(publr_auth.IdentityRefused, .{
            .provider = identity.provider,
            .why = "closed",
        });

        return error.BadCredentials;
    };

    if (!try sdk.stored_roles.exists(ctx, open_role)) {
        return error.Invalid;
    }

    // A role that reaches the admin now (its grants changed since) makes no account.
    if (try sdk.stored_roles.staff(ctx, open_role)) {
        return error.Denied;
    }

    const user_id = try store.users.insert(ctx.db, ctx.io, ctx.arena, .{
        .email = email,
        .display_name = display_name(identity, email),
        .password_hash = null,
        .roles = &.{open_role},
        .now_ms = ctx.now_ms,
    });

    try link(ctx, user_id, identity);
    ctx.emit(@import("user.zig").UserCreated, .{
        .user = user_id,
    });

    return .{
        .user_id = user_id,
        .created = true,
    };
}

/// A new account behind an identity-aware proxy, with the roles an administrator chose for
/// new members of the organisation, staff roles included. The one exception to "only staff
/// make staff": staff made the rule and the proxy vouches for the person. Never sign-up,
/// a user type, an app's actions or a signed link: those stay visitor-only.
fn new_member(
    ctx: *Ctx,
    identity: model.Identity,
    email: []const u8,
    roles: []const []const u8,
) Error!Resolved {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(identity.verified);

    if (roles.len > role.user_roles_max) {
        return error.Invalid;
    }

    for (roles) |name| {
        if (!try sdk.stored_roles.exists(ctx, name)) {
            return error.Invalid;
        }
    }

    const user_id = try store.users.insert(ctx.db, ctx.io, ctx.arena, .{
        .email = email,
        .display_name = display_name(identity, email),
        .password_hash = null,
        .roles = roles,
        .now_ms = ctx.now_ms,
    });

    try link(ctx, user_id, identity);
    ctx.emit(@import("user.zig").UserCreated, .{
        .user = user_id,
    });

    return .{
        .user_id = user_id,
        .created = true,
    };
}

/// The identity's email, normalised, when the provider vouches for it.
fn verified_email(ctx: *Ctx, identity: model.Identity) ?[]const u8 {
    std.debug.assert(model.valid(identity));

    const raw = identity.email orelse return null;

    if (!identity.verified) {
        return null;
    }

    std.debug.assert(raw.len <= model.email_len_max);

    return store.users.normalize_email(ctx.arena, raw) catch null;
}

/// The provider's name for the person when it is one; the email otherwise.
fn display_name(identity: model.Identity, email: []const u8) []const u8 {
    std.debug.assert(email.len > 0);
    std.debug.assert(email.len <= model.email_len_max);

    const candidate = identity.name orelse email;

    return store.users.validate_display_name(candidate) catch email;
}

pub fn link(ctx: *Ctx, user_id: []const u8, identity: model.Identity) Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(model.valid(identity));

    if (try store.identities.count_of_user(ctx.db, user_id) >= store.identities.per_user_max) {
        return error.Invalid;
    }

    try store.identities.insert(ctx.db, .{
        .provider = identity.provider,
        .provider_id = identity.id,
        .user_id = user_id,
        .email = identity.email,
        .now_ms = ctx.now_ms,
    });
}

pub const Configure = struct {
    pub const shape = public.Configure;
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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        if (in.open_sign_up.len == 0) {
            try store.settings.delete(ctx.db, open_sign_up_key);

            return .{
                .open_sign_up = "",
            };
        }

        const declared = try sdk.stored_roles.exists(ctx, in.open_sign_up);

        if (!declared or std.mem.eql(u8, in.open_sign_up, role.admin)) {
            return error.Invalid;
        }

        // Signing up makes a visitor, never staff: a role reaching the admin is refused.
        if (try sdk.stored_roles.staff(ctx, in.open_sign_up)) {
            return error.Denied;
        }

        try store.settings.set(ctx.db, open_sign_up_key, in.open_sign_up, ctx.now_ms);

        return .{
            .open_sign_up = in.open_sign_up,
        };
    }
};

pub const Status = struct {
    pub const shape = public.Status;
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

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(open_sign_up_key.len > 0);

        const open_role = try store.settings.get(ctx.db, ctx.arena, open_sign_up_key) orelse "";

        return .{
            .open_sign_up = open_role,
        };
    }
};

const manage = @import("identity/manage.zig");
pub const providers = @import("identity/providers.zig");

pub const Link = manage.Link;
pub const List = manage.List;
pub const Unlink = manage.Unlink;
pub const Providers = providers.Providers;

pub const operations = [_]type{ SignIn, Configure, Status, Link, List, Unlink, Providers };

test "an identity signs in its linked account, links by verified email, else is refused" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const SDK = registry.SDK;
    var system = harness.ctx(.system);
    var anon = harness.ctx(.anonymous);

    try SDK.bootstrap(&system);
    const ada = try SDK.dispatch(&system, @import("user.zig").Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .roles = &.{"editor"},
        .password = "correct horse battery",
    });

    var editor = harness.ctx(.{
        .user = .{
            .id = ada.user_id,
            .roles = &.{"editor"},
        },
    });
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, SignIn, example_in));
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, SignIn, example_in));

    var malformed = example_in;
    malformed.id = "";
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, SignIn, malformed));

    var unverified = example_in;
    unverified.verified = false;
    const refused = SDK.dispatch(&system, SignIn, unverified);
    try std.testing.expectError(error.BadCredentials, refused);

    var stranger = example_in;
    stranger.email = "eve@example.com";
    try std.testing.expectError(error.BadCredentials, SDK.dispatch(&system, SignIn, stranger));

    const linked = try SDK.dispatch(&system, SignIn, example_in);
    try std.testing.expectEqualStrings(ada.user_id, linked.user_id);
    try std.testing.expect(!linked.created);
    try std.testing.expectEqual(@as(usize, store.sessions.token_len), linked.token.len);

    // Known by id from now on, whatever the provider says about the email.
    var renamed = example_in;
    renamed.email = "ada@other.example";
    renamed.verified = false;
    const again = try SDK.dispatch(&system, SignIn, renamed);
    try std.testing.expectEqualStrings(ada.user_id, again.user_id);
}

test "open sign-up creates an account with the role, from a verified email only" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const SDK = registry.SDK;
    const sign_in = @import("sign_in.zig");
    var system = harness.ctx(.system);
    var anon = harness.ctx(.anonymous);

    try SDK.bootstrap(&system);

    const closed = try SDK.dispatch(&system, Status, .{});
    try std.testing.expectEqualStrings("", closed.open_sign_up);
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, Status, .{}));
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, Configure, Configure.example));

    const admin: Configure.In = .{
        .open_sign_up = "admin",
    };
    const unknown: Configure.In = .{
        .open_sign_up = "nobody",
    };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Configure, admin));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Configure, unknown));

    // A visitor's role only: one reaching the admin is refused.
    const staff_role: Configure.In = .{
        .open_sign_up = "editor",
    };
    try std.testing.expectError(error.Denied, SDK.dispatch(&system, Configure, staff_role));

    _ = try SDK.dispatch(&system, @import("role.zig").Create, .{
        .name = "customer",
        .label = "Customer",
        .grants = &.{"app.*"},
    });
    _ = try SDK.dispatch(&system, Configure, Configure.example);
    const opened = try SDK.dispatch(&system, Status, .{});
    try std.testing.expectEqualStrings("customer", opened.open_sign_up);

    var unverified = example_in;
    unverified.verified = false;
    const refused = SDK.dispatch(&system, SignIn, unverified);
    try std.testing.expectError(error.BadCredentials, refused);

    var nameless = example_in;
    nameless.email = null;
    try std.testing.expectError(error.BadCredentials, SDK.dispatch(&system, SignIn, nameless));

    const created = try SDK.dispatch(&system, SignIn, example_in);
    try std.testing.expect(created.created);
    try std.testing.expectEqualStrings("customer", created.roles[0]);

    const connection = &harness.fixture.connection;
    const arena = harness.fixed.allocator();
    const account = (try store.users.find_by_id(connection, arena, created.user_id)).?;
    try std.testing.expectEqualStrings("Ada Lovelace", account.user.display_name);
    try std.testing.expect(account.user.active);
    try std.testing.expect(account.password_hash == null);

    const by_password: sign_in.SignIn.In = .{
        .email = "ada@example.com",
        .password = "anything at all",
    };
    const no_password = SDK.dispatch(&anon, sign_in.SignIn, by_password);
    try std.testing.expectError(error.BadCredentials, no_password);

    const back = try SDK.dispatch(&system, SignIn, example_in);
    try std.testing.expect(!back.created);
    try std.testing.expectEqualStrings(created.user_id, back.user_id);

    _ = try SDK.dispatch(&system, Configure, .{});
    var newcomer = example_in;
    newcomer.id = "999";
    newcomer.email = "new@example.com";
    try std.testing.expectError(error.BadCredentials, SDK.dispatch(&system, SignIn, newcomer));
}
