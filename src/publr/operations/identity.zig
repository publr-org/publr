//! Signing in as who a provider says you are. The provider plugins turn a callback into an
//! identity; the routes hand it here as the system, and this is the one place that decides
//! which account it is: the linked one, the one with that verified email, a new one when the
//! site allows it, or nobody.
const operation = @import("../operation.zig");

const manage = @import("identity/manage.zig");
const providers = @import("identity/providers.zig");
pub const Link = manage.Link;
pub const List = manage.List;
pub const Unlink = manage.Unlink;
pub const Summary = manage.Summary;
pub const Providers = providers.Providers;
pub const Offered = providers.Offered;

/// What a provider reports, as the operations take it.
pub const Input = struct {
    provider: []const u8,
    id: []const u8,
    email: ?[]const u8 = null,
    verified: bool = false,
    name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
    /// Behind an identity-aware proxy, the roles a new account gets when nobody holds the
    /// identity: what an administrator chose for new organization members (none at all, or
    /// staff too). Null: no account is made this way. The system alone passes it.
    new_account_roles: ?[]const []const u8 = null,
};

pub const example_in: Input = .{
    .provider = "github",
    .id = "583231",
    .email = "ada@example.com",
    .verified = true,
    .name = "Ada Lovelace",
    .avatar = "https://avatars.githubusercontent.com/u/583231",
};

pub const in_docs: operation.Docs(Input) = .{
    .provider = "The provider's name, as its plugin declares it: `github`, `google`",
    .id = "The provider's stable id for the person; never their email or login name",
    .email = "The email the provider reports, if any",
    .verified = "Whether the provider vouches for that email",
    .name = "A display name, if the provider gives one",
    .avatar = "An avatar URL, if the provider gives one",
    .new_account_roles = "Behind an identity-aware proxy, the roles a new account gets " ++
        "when nobody holds the identity; the system alone passes it",
};

pub const namespace: operation.Namespace = .{
    .name = "identity",
    .label = "Sign-in accounts",
    .area = .people,
    .summary = "Signing in with a provider: GitHub, Google, whichever plugins are compiled in",
    .details =
    \\A provider plugin proves who someone is; the core keeps which account that identity
    \\belongs to (`identity list`, `identity unlink`) and signs them in
    \\(`identity sign_in`, called by `/auth/<provider>/callback`). By default only accounts
    \\that exist can sign in this way; `identity configure` opens sign-up with a role.
    ,
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
    pub const kind: operation.Kind = .write;
    pub const In = Input;
    pub const Out = struct {
        token: []const u8,
        user_id: []const u8,
        roles: []const []const u8,
        expires_at: i64,
        created: bool,
        /// The identity was just linked to the account with its email.
        linked: bool = false,
    };
    pub const example: In = example_in;
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .roles = &.{"editor"},
        .expires_at = 1792232000000,
        .created = false,
        .linked = false,
    };
    pub const field_docs = in_docs;
    pub const output_docs: operation.Docs(Out) = .{
        .token = "The session token, `id.secret`; treat it like a password",
        .user_id = "The signed-in account",
        .roles = "The roles it holds",
        .expires_at = "When the session expires if unused, Unix milliseconds",
        .created = "True when the account was created by this sign-in",
        .linked = "True when this sign-in linked the identity to the account with its email",
    };
};

pub const Configure = struct {
    pub const name = "identity.configure";
    pub const description = "Open or close sign-up through providers, and with which role";
    pub const details =
        \\Administrators only. `open_sign_up` names the role a new account gets when a
        \\provider identity nobody holds signs in with a verified email: a member role,
        \\never one reaching the admin (refused as denied). Empty closes sign-up again: only
        \\accounts that exist sign in, which is the default.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        open_sign_up: []const u8 = "",
    };
    pub const Out = struct {
        open_sign_up: []const u8,
    };
    pub const example: In = .{
        .open_sign_up = "customer",
    };
    pub const example_out: Out = .{
        .open_sign_up = "customer",
    };
    pub const field_docs: operation.Docs(In) = .{
        .open_sign_up = "The role new accounts get, or empty to sign in existing accounts only",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .open_sign_up = "The role in force, empty when sign-up is closed",
    };
};

pub const Status = struct {
    pub const name = "identity.status";
    pub const description = "Whether provider sign-up is open, and with which role";
    pub const details = "Administrators only. Nothing is written.";
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        open_sign_up: []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .open_sign_up = "",
    };
    pub const field_docs: operation.Docs(In) = .{};
    pub const output_docs: operation.Docs(Out) = .{
        .open_sign_up = "The role new accounts get, empty when only existing accounts sign in",
    };
};
