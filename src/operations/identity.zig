//! Signing in as who a provider says you are. The provider plugins turn a callback into an
//! `Identity`; the routes hand it here as the system, and this is the one place that decides
//! which account it is: the linked one, the one with that verified email, a new one when the
//! site allows it, or nobody.

const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const model = @import("../model/identity.zig");
const role = @import("../model/role.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const open_sign_up_key = "identity.open_sign_up";

pub const namespace: sdk.operation.Namespace = .{
    .name = "identity",
    .summary = "Signing in with a provider: GitHub, Google, whichever plugins are compiled in",
    .details =
    \\A provider plugin proves who someone is; the core keeps which account that identity
    \\belongs to (`identity list`, `identity unlink`) and signs them in
    \\(`identity sign_in`, called by `/auth/<provider>/callback`). By default only accounts
    \\that exist can sign in this way; `identity configure` opens sign-up with a role.
    ,
};

/// What a provider reports, as the operations take it.
pub const Input = struct {
    provider: []const u8,
    id: []const u8,
    email: ?[]const u8 = null,
    verified: bool = false,
    name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};

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

pub const example_in: Input = .{
    .provider = "github",
    .id = "583231",
    .email = "ada@example.com",
    .verified = true,
    .name = "Ada Lovelace",
    .avatar = "https://avatars.githubusercontent.com/u/583231",
};

pub const in_docs: sdk.operation.Docs(Input) = .{
    .provider = "The provider's name, as its plugin declares it: `github`, `google`",
    .id = "The provider's stable id for the person; never their email or login name",
    .email = "The email the provider reports, if any",
    .verified = "Whether the provider vouches for that email",
    .name = "A display name, if the provider gives one",
    .avatar = "An avatar URL, if the provider gives one",
};

pub const SignIn = struct {
    pub const name = "identity.sign_in";
    pub const description = "Sign in as the account a provider's identity belongs to";
    pub const details =
        \\Administrators, and the system: `/auth/<provider>/callback` calls it once the
        \\provider plugin has verified who someone is; nobody claims an identity by hand,
        \\and an administrator could sign in as anyone anyway. The account is found
        \\by provider and id first. Failing that, an account with the same email is linked
        \\when the provider vouches for the email. Failing that, `wrong email or password`,
        \\unless sign-up is open (`identity configure`): then an account with that role is
        \\created, still only from a verified email. Returns a session token, as
        \\`user sign_in` does.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = Input;
    pub const Out = struct {
        token: []const u8,
        user_id: []const u8,
        roles: []const []const u8,
        expires_at: i64,
        created: bool,
    };
    pub const example: In = example_in;
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .roles = &.{"editor"},
        .expires_at = 1792232000000,
        .created = false,
    };
    pub const field_docs = in_docs;
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "The session token, `id.secret`; treat it like a password",
        .user_id = "The signed-in account",
        .roles = "The roles it holds",
        .expires_at = "When the session expires if unused, Unix milliseconds",
        .created = "True when the account was created by this sign-in",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        const identity = try identity_of(in);
        const resolved = try resolve(ctx, identity);
        const found = try store.users.find_by_id(ctx.db, ctx.arena, resolved.user_id) orelse {
            return error.BadCredentials;
        };

        std.debug.assert(found.user.active);

        _ = try store.sessions.cleanup(ctx.db, ctx.now_ms);
        const user_id = found.user.id;
        const created = try store.sessions.create(ctx.db, ctx.io, ctx.arena, user_id, ctx.now_ms);

        ctx.notice("auth.identity_signed_in", found.user.id);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = found.user.id,
            .roles = found.user.roles,
            .expires_at = created.session.expires_at,
            .created = resolved.created,
        };
    }
};

const Resolved = struct { user_id: []const u8, created: bool };

/// Whose identity this is, linking or creating on the way; `BadCredentials` when nobody's.
fn resolve(ctx: *Ctx, identity: model.Identity) Error!Resolved {
    std.debug.assert(ctx.caller != .anonymous);
    std.debug.assert(model.valid(identity));

    if (try store.identities.find(ctx.db, ctx.arena, identity.provider, identity.id)) |row| {
        const email = identity.email;

        try store.identities.touch(ctx.db, identity.provider, identity.id, email, ctx.now_ms);

        return .{ .user_id = row.user_id, .created = false };
    }

    const email = verified_email(ctx, identity) orelse {
        ctx.notice("auth.identity_refused", identity.provider);

        return error.BadCredentials;
    };

    if (try store.users.find_by_email(ctx.db, ctx.arena, email)) |existing| {
        try link(ctx, existing.user.id, identity);
        ctx.notice("auth.identity_linked", existing.user.id);

        return .{ .user_id = existing.user.id, .created = false };
    }

    const open_role = try store.settings.get(ctx.db, ctx.arena, open_sign_up_key) orelse {
        ctx.notice("auth.identity_refused", identity.provider);

        return error.BadCredentials;
    };

    if (registry.Roles.get(open_role) == null) {
        return error.Invalid;
    }

    const user_id = try store.users.insert(ctx.db, ctx.io, ctx.arena, .{
        .email = email,
        .display_name = display_name(identity, email),
        .password_hash = null,
        .roles = &.{open_role},
        .now_ms = ctx.now_ms,
    });

    try link(ctx, user_id, identity);
    ctx.notice("auth.user_created", user_id);

    return .{ .user_id = user_id, .created = true };
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
    pub const name = "identity.configure";
    pub const description = "Open or close sign-up through providers, and with which role";
    pub const details =
        \\Administrators only. `open_sign_up` names the role a new account gets when a
        \\provider identity nobody holds signs in with a verified email: any declared role
        \\but `admin`. Empty closes sign-up again: only accounts that exist sign in, which
        \\is the default.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { open_sign_up: []const u8 = "" };
    pub const Out = struct { open_sign_up: []const u8 };
    pub const example: In = .{ .open_sign_up = "editor" };
    pub const example_out: Out = .{ .open_sign_up = "editor" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .open_sign_up = "The role new accounts get, or empty to sign in existing accounts only",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .open_sign_up = "The role in force, empty when sign-up is closed",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        if (in.open_sign_up.len == 0) {
            try store.settings.delete(ctx.db, open_sign_up_key);

            return .{ .open_sign_up = "" };
        }

        const declared = registry.Roles.get(in.open_sign_up) != null;

        if (!declared or std.mem.eql(u8, in.open_sign_up, role.admin)) {
            return error.Invalid;
        }

        try store.settings.set(ctx.db, open_sign_up_key, in.open_sign_up, ctx.now_ms);

        return .{ .open_sign_up = in.open_sign_up };
    }
};

pub const Status = struct {
    pub const name = "identity.status";
    pub const description = "Whether provider sign-up is open, and with which role";
    pub const details = "Administrators only. Nothing is written.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { open_sign_up: []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .open_sign_up = "" };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .open_sign_up = "The role new accounts get, empty when only existing accounts sign in",
    };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(open_sign_up_key.len > 0);

        const open_role = try store.settings.get(ctx.db, ctx.arena, open_sign_up_key) orelse "";

        return .{ .open_sign_up = open_role };
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

    var editor = harness.ctx(.{ .user = .{ .id = ada.user_id, .roles = &.{"editor"} } });
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

    const admin: Configure.In = .{ .open_sign_up = "admin" };
    const unknown: Configure.In = .{ .open_sign_up = "nobody" };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Configure, admin));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Configure, unknown));

    _ = try SDK.dispatch(&system, Configure, Configure.example);
    const opened = try SDK.dispatch(&system, Status, .{});
    try std.testing.expectEqualStrings("editor", opened.open_sign_up);

    var unverified = example_in;
    unverified.verified = false;
    const refused = SDK.dispatch(&system, SignIn, unverified);
    try std.testing.expectError(error.BadCredentials, refused);

    var nameless = example_in;
    nameless.email = null;
    try std.testing.expectError(error.BadCredentials, SDK.dispatch(&system, SignIn, nameless));

    const created = try SDK.dispatch(&system, SignIn, example_in);
    try std.testing.expect(created.created);
    try std.testing.expectEqualStrings("editor", created.roles[0]);

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
