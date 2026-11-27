//! Accounts, roles, passwords and signing in.
const std = @import("std");
const operation = @import("../operation.zig");
const Extended = @import("../extended.zig").Extended;
const Error = operation.Error;

pub const namespace: operation.Namespace = .{
    .name = "user",
    .label = "Users",
    .area = .people,
    .summary = "Accounts, roles, passwords and signing in",
    .details =
    \\Everything about who may use Publr. The first admin comes from `publr project init`;
    \\after that, create accounts with `user create` (with a password, a generated
    \\one, or a set-password link). An account holds the roles it is given, none unless
    \\asked, and may call what any of them grants. Core has `admin` (everything) and
    \\`editor` (content, not users, structure or settings); plugins add their own, such as
    \\the visitors of an app, whose grants reach only that app's operations
    \\(`app.<feature>.*`).
    \\
    \\`sign_in`, `sign_out` and `set_password` are open to anyone; the rest
    \\needs an admin (`--as <admin>` or `--as-admin`). Over HTTP the same operations
    \\back `POST /api/auth/sign-in`, `POST /api/auth/sign-out` and `POST /api/auth/set-password`.
    ,
};

/// The page an invited person opens to choose their password (`?token=`): the admin's
/// welcome. Scripts set it with `POST /api/auth/set-password` instead.
pub const invitation_path = "/admin/welcome";

pub const fields = @import("user/fields.zig");
pub const language = @import("user/language.zig");
pub const visitors = @import("user/visitors.zig");
pub const columns = @import("user/columns.zig");
pub const types = @import("user/types.zig");
const manage = @import("user/manage.zig");
pub const Update = manage.Update;
pub const Delete = manage.Delete;
pub const Get = fields.Get;
pub const Validate = fields.Validate;
pub const AddType = types.AddType;
pub const RemoveType = types.RemoveType;

pub const Summary = struct {
    id: []const u8,
    email: []const u8,
    display_name: []const u8,
    /// The roles the account holds, by name.
    roles: []const []const u8,
    created_at: i64,
    active: bool,
    /// The types of user plugins register (`customer`) the account holds; none for staff alone.
    user_types: []const []const u8 = &.{},
};

pub const Link = struct {
    path: []const u8,
    expires_at: i64,
};

pub const Create = struct {
    pub const name = "user.create";
    /// Never written to the logs.
    pub const secret = .{"password"};
    pub const description = "Create a user; omit the password to get one generated, " ++
        "or ask for a set-password link instead";
    pub const details =
        \\Admins only (`--as <admin>` or `--as-admin`). Three ways to hand over access:
        \\
        \\  1. `--password <secret>`: you choose it (or set `PUBLR_PASSWORD`).
        \\  2. no password: a strong one is generated and returned once in the output.
        \\  3. `--password_link true`: the account is created inactive and you get a
        \\     one-hour, single-use link (`/admin/welcome?token=...`) to send to the
        \\     person; prefix it with your site URL. Until they use it the account
        \\     cannot sign in. `user password_link` issues a new one at any time.
        \\
        \\`--roles` names the roles the account holds, one or more (`admin,editor`);
        \\`publr role list` lists the ones this project has. Fails as invalid for a role
        \\no compiled-in code declares. No role is ever given unasked: without `--roles`
        \\the account holds none and can do nothing until an administrator gives it one,
        \\or, with `--user_type`, it holds exactly the roles the type declares.
        \\
        \\`--user_type` makes it an account of a type a plugin registers (`customer`,
        \\see `user_type list`). An account holding types and no role but theirs signs in
        \\only to the apps its types open and is listed with its types, never under
        \\Settings › Users; one holding another role (an administrator who is also a
        \\customer) is staff as well. The admin is reached by roles alone.
        \\`user add_type` gives an account more types.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        email: []const u8,
        display_name: []const u8,
        roles: ?[]const []const u8 = null,
        password: ?[]const u8 = null,
        password_link: bool = false,
        user_type: []const u8 = "",
    };
    pub const Out = struct {
        user_id: []const u8,
        roles: []const []const u8,
        password: ?[]const u8,
        link: ?Link,
    };
    pub const example: In = .{
        .email = "writer@example.com",
        .display_name = "Writer",
        .roles = &.{"editor"},
        .password_link = true,
    };
    pub const example_out: Out = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .roles = &.{"editor"},
        .password = null,
        .link = .{
            .path = "/admin/welcome?token=6f3a...",
            .expires_at = 1789650000000,
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .email = "Sign-in email; must be unique, stored lowercased and trimmed",
        .display_name = "Name shown in the admin",
        .roles = "The roles the account holds, comma-separated: `admin`, `editor` or one a " ++
            "plugin declares; none when omitted, or only the type's roles with user_type",
        .password = "8 to 256 characters; generated when omitted; not allowed with password_link",
        .password_link = "Create the account inactive and return a set-password link instead",
        .user_type = "A type of user a plugin registers (`customer`) the account holds; " ++
            "none when empty",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user_id = "The new account's id",
        .roles = "The roles given",
        .password = "The generated password, only when none was passed; shown exactly once",
        .link = "The set-password link (path + expiry, one hour), only with password_link",
    };
};

pub const PasswordLink = struct {
    pub const name = "user.password_link";
    pub const description = "Issue a fresh one-hour set-password link for a user (id or email)";
    pub const details =
        \\Admins only. Use it to activate an invited account whose link expired, or to
        \\let anyone reset a forgotten password: send them the link, prefixed with your
        \\site URL. Only the newest link works; the previous one stops immediately.
        \\Redeeming it sets the password and signs out every session of that account.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
    };
    pub const Out = struct {
        user_id: []const u8,
        link: Link,
    };
    pub const example: In = .{
        .user = "invited@example.com",
    };
    pub const example_out: Out = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .link = .{
            .path = "/admin/welcome?token=c41d...",
            .expires_at = 1789650000000,
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The user's id or email",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user_id = "The user's id",
        .link = "Path with the one-time token, and when it expires (one hour)",
    };
};

pub const SetPassword = struct {
    pub const name = "user.set_password";
    pub const open = true;
    /// Never written to the logs.
    pub const secret = .{ "token", "password" };
    pub const description = "Redeem a set-password link: sets the password, activates the " ++
        "account, signs out every session and device";
    pub const details =
        \\Anyone holding a valid token may call it (no `--as` needed); this is what
        \\`POST /api/auth/set-password` does for a browser. The token is the `token=` part
        \\of a link from `users create --password_link true` or `user password_link`.
        \\It works once, within an hour of being issued; a wrong, used or expired token
        \\answers `not found`. Existing sessions of the account are signed out and its
        \\devices (the CLI, agent tools) stop working: each signs in again.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        token: []const u8,
        password: []const u8,
    };
    pub const Out = struct {
        user_id: []const u8,
        /// The account's email, so the page can sign in with the new password at once.
        email: []const u8,
    };
    pub const example: In = .{
        .token = "0000000000000000000000000000000000000000000000000000000000000000",
        .password = "correct horse battery",
    };
    pub const example_out: Out = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .email = "hanna@example.com",
    };
    pub const field_docs: operation.Docs(In) = .{
        .token = "The 64-character token from the link",
        .password = "The new password, 8 to 256 characters (or `PUBLR_PASSWORD`)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user_id = "The account that was activated",
        .email = "Its email",
    };
};

pub const Options = struct {
    pub const name = "user.options";
    pub const description = "User ids and display names for reference pickers";
    pub const details = "Signed-in editors and administrators can select users without reading " ++
        "their email addresses or account credentials.";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        query: []const u8 = "",
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Option = struct {
        id: []const u8,
        label: []const u8,
    };
    pub const Out = struct {
        users: []const Option,
        total: u32 = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .query = "Only the users whose name holds this; every one when empty",
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .users = "Each user's id and display name",
        .total = "How many users the query matches in all",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .users = &.{
            .{
                .id = "3f9c1e0a5b7d2c4e6f8a9b0c",
                .label = "Ada",
            },
            .{
                .id = "9b1e7c3d5a2f4e6b8d0c1a3f",
                .label = "Editor",
            },
            .{
                .id = "7d1e7c3d5a2f4e6b8d0c1a3f",
                .label = "Invited",
            },
        },
    };
};

pub const List = struct {
    pub const name = "user.list";
    pub const description = "List users (id, email, display name, roles, active)";
    pub const details =
        \\Admins only. `active` is false for accounts created with a set-password link
        \\that has not been redeemed yet; such accounts cannot sign in.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        query: []const u8 = "",
        limit: u32 = 50,
        offset: u32 = 0,
        sort: []const u8 = "",
        user_type: []const u8 = "",
    };
    pub const Out = struct {
        users: []const Summary,
        total: u32 = 0,
        extended: Extended = .{},

        /// A field of the hooking plugin's own on an account:
        /// `out.extend(user, "loyalty.points", 120)`.
        pub fn extend(
            out: *const Out,
            user: Summary,
            field: []const u8,
            value: anytype,
        ) Error!void {
            std.debug.assert(user.id.len > 0);

            return out.extended.put(user.id, field, value);
        }
    };
    pub const field_docs: operation.Docs(In) = .{
        .query = "Only the accounts whose name or email holds this; every one when empty",
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the next page's start",
        .sort = "A field stored on the accounts (`loyalty.points`), `-loyalty.points` " ++
            "descending; oldest first when empty",
        .user_type = "Accounts holding this type of user (`customer`); staff when empty: " ++
            "accounts holding no type, or a role no type gives",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .users = &.{
            .{
                .id = "3f9c1e0a5b7d2c4e6f8a9b0c",
                .email = "ada@example.com",
                .display_name = "Ada",
                .roles = &.{"admin"},
                .created_at = 1789640000000,
                .active = true,
            },
            .{
                .id = "9b1e7c3d5a2f4e6b8d0c1a3f",
                .email = "editor@example.com",
                .display_name = "Editor",
                .roles = &.{"editor"},
                .created_at = 1789646400000,
                .active = false,
            },
        },
    };
    pub const output_docs: operation.Docs(Out) = .{
        .users = "A page of accounts, oldest first; `created_at` is Unix milliseconds",
        .total = "How many accounts the query matches in all",
        .extended = "Fields plugins add to each account, by its id: " ++
            "`{\"<id>\": {\"loyalty.points\": 120}}`",
    };
};
