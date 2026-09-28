const std = @import("std");
const sdk = @import("../sdk.zig");
const auth = @import("../lib/auth.zig");
const store = @import("../store.zig");
const role = @import("../model/role.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "user",
    .summary = "Accounts, roles, passwords and signing in",
    .details =
    \\Everything about who may use Publr. The first admin comes from `publr init`;
    \\after that, create accounts with `user create` (with a password, a generated
    \\one, or a set-password link). An account holds one or more roles, and may call
    \\what any of them grants. Core has `admin` (everything) and `editor` (content,
    \\not users, structure or settings); plugins add their own, such as the visitors
    \\of an app, whose grants reach only that app's operations (`app.<feature>.*`).
    \\
    \\`sign_in`, `sign_out` and `set_password` are open to anyone; the rest
    \\needs an admin (`--as <admin>` or `--as-admin`). Over HTTP the same operations
    \\back `POST /api/auth/sign-in`, `POST /api/auth/sign-out` and `POST /api/auth/set-password`.
    ,
};

pub const set_password_path = "/api/auth/set-password";
pub const password_link_lifetime_ms: i64 = 60 * 60 * 1000;
pub const password_token_bytes: u32 = 32;
pub const password_token_len: u32 = password_token_bytes * 2;
pub const generated_password_len: u32 = 20;

const generated_alphabet = "abcdefghjkmnpqrstuvwxyz23456789";

pub const Summary = struct {
    id: []const u8,
    email: []const u8,
    display_name: []const u8,
    /// The roles the account holds, by name.
    roles: []const []const u8,
    created_at: i64,
    active: bool,
};

pub const Link = struct { path: []const u8, expires_at: i64 };

pub const Create = struct {
    pub const name = "user.create";
    pub const description = "Create a user; omit the password to get one generated, " ++
        "or ask for a set-password link instead";
    pub const details =
        \\Admins only (`--as <admin>` or `--as-admin`). Three ways to hand over access:
        \\
        \\  1. `--password <secret>`: you choose it (or set `PUBLR_PASSWORD`).
        \\  2. no password: a strong one is generated and returned once in the output.
        \\  3. `--password_link true`: the account is created inactive and you get a
        \\     one-hour, single-use link (`/auth/set-password?token=...`) to send to the
        \\     person; prefix it with your site URL. Until they use it the account
        \\     cannot sign in. `user password_link` issues a new one at any time.
        \\
        \\`--roles` names the roles the account holds, one or more (`admin,editor`);
        \\`publr role list` lists the ones this project has. Fails as invalid for a role
        \\no compiled-in code declares.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        email: []const u8,
        display_name: []const u8,
        roles: []const []const u8 = &.{role.editor},
        password: ?[]const u8 = null,
        password_link: bool = false,
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
        .password_link = true,
    };
    pub const example_out: Out = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .roles = &.{"editor"},
        .password = null,
        .link = .{ .path = "/auth/set-password?token=6f3a...", .expires_at = 1789650000000 },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .email = "Sign-in email; must be unique, stored lowercased and trimmed",
        .display_name = "Name shown in the admin",
        .roles = "The roles the account holds, comma-separated: `admin`, `editor` or one a " ++
            "plugin declares",
        .password = "8 to 256 characters; generated when omitted; not allowed with password_link",
        .password_link = "Create the account inactive and return a set-password link instead",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_id = "The new account's id",
        .roles = "The roles given",
        .password = "The generated password, only when none was passed; shown exactly once",
        .link = "The set-password link (path + expiry, one hour), only with password_link",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.caller != .anonymous);

        if (in.password_link and in.password != null) {
            return error.Invalid;
        }

        if (in.password_link) {
            const created = try create_pending_user(ctx, in.email, in.display_name, in.roles);
            const link = try issue_link(ctx, created);

            ctx.notice("auth.user_created", created);

            return .{ .user_id = created, .roles = in.roles, .password = null, .link = link };
        }

        const created = try create_user(ctx, in.email, in.display_name, in.password, in.roles);
        ctx.notice("auth.user_created", created.user_id);

        return .{
            .user_id = created.user_id,
            .roles = in.roles,
            .password = created.password,
            .link = null,
        };
    }
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
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { user: []const u8 };
    pub const Out = struct { user_id: []const u8, link: Link };
    pub const example: In = .{ .user = "invited@example.com" };
    pub const example_out: Out = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .link = .{ .path = "/auth/set-password?token=c41d...", .expires_at = 1789650000000 },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The user's id or email",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_id = "The user's id",
        .link = "Path with the one-time token, and when it expires (one hour)",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.caller != .anonymous);

        const credentials = try find_user(ctx, in.user) orelse return error.NotFound;
        const link = try issue_link(ctx, credentials.user.id);

        ctx.notice("auth.password_link_issued", credentials.user.id);

        return .{ .user_id = credentials.user.id, .link = link };
    }
};

pub const SetPassword = struct {
    pub const name = "user.set_password";
    pub const description = "Redeem a set-password link: sets the password, activates the " ++
        "account, signs out every session";
    pub const details =
        \\Anyone holding a valid token may call it (no `--as` needed); this is what
        \\`POST /api/auth/set-password` does for a browser. The token is the `token=` part
        \\of a link from `users create --password_link true` or `user password_link`.
        \\It works once, within an hour of being issued; a wrong, used or expired token
        \\answers `not found`. Existing sessions of the account are signed out.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { token: []const u8, password: []const u8 };
    pub const Out = struct { user_id: []const u8 };
    pub const example: In = .{
        .token = "0000000000000000000000000000000000000000000000000000000000000000",
        .password = "correct horse battery",
    };
    pub const example_out: Out = .{ .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .token = "The 64-character token from the link",
        .password = "The new password, 8 to 256 characters (or `PUBLR_PASSWORD`)",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_id = "The account that was activated",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        const token_hash = hash_token(in.token) orelse return error.NotFound;
        const now_ms = ctx.now_ms;
        const found = try store.users.find_by_password_token(ctx.db, ctx.arena, token_hash, now_ms);
        const credentials = found orelse return error.NotFound;
        const password_hash = try hash_password(ctx, in.password);

        try store.users.set_password(ctx.db, credentials.user.id, password_hash, ctx.now_ms);
        _ = try store.sessions.destroy_all(ctx.db, credentials.user.id);
        ctx.notice("auth.password_set", credentials.user.id);

        return .{ .user_id = credentials.user.id };
    }
};

pub const Options = struct {
    pub const name = "user.options";
    pub const description = "User ids and display names for reference pickers";
    pub const details = "Signed-in editors and administrators can select users without reading " ++
        "their email addresses or account credentials.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Option = struct { id: []const u8, label: []const u8 };
    pub const Out = struct { users: []const Option };
    pub const example: In = .{};
    pub const example_out: Out = .{ .users = &.{
        .{ .id = "3f9c1e0a5b7d2c4e6f8a9b0c", .label = "Ada" },
        .{ .id = "9b1e7c3d5a2f4e6b8d0c1a3f", .label = "Editor" },
        .{ .id = "7d1e7c3d5a2f4e6b8d0c1a3f", .label = "Invited" },
    } };

    pub fn run(ctx: *Ctx, _: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());
        const rows = try store.users.list(ctx.db, ctx.arena);
        const users = try ctx.arena.alloc(Option, rows.len);

        for (rows, 0..) |row, index| {
            users[index] = .{ .id = row.id, .label = row.display_name };
        }

        return .{ .users = users };
    }
};

pub const List = struct {
    pub const name = "user.list";
    pub const description = "List users (id, email, display name, roles, active)";
    pub const details =
        \\Admins only. `active` is false for accounts created with a set-password link
        \\that has not been redeemed yet; such accounts cannot sign in.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { users: []const Summary };
    pub const example: In = .{};
    pub const example_out: Out = .{ .users = &.{
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
    } };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .users = "Every account, oldest first; `created_at` is Unix milliseconds",
    };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.caller != .anonymous);
        std.debug.assert(store.users.list_max > 0);

        const rows = try store.users.list(ctx.db, ctx.arena);
        const users = try ctx.arena.alloc(Summary, rows.len);

        for (rows, 0..) |row, index| {
            users[index] = summary_of(row);
        }

        return .{ .users = users };
    }
};

pub const CreatedUser = struct { user_id: []const u8, password: ?[]const u8 };

pub fn create_user(
    ctx: *Ctx,
    raw_email: []const u8,
    raw_display_name: []const u8,
    given_password: ?[]const u8,
    roles: []const []const u8,
) Error!CreatedUser {
    std.debug.assert(ctx.db.transaction_depth >= 1);
    std.debug.assert(ctx.now_ms >= 0);

    const generated = if (given_password == null) try generate_password(ctx) else null;
    const password = given_password orelse generated.?;
    const password_hash = try hash_password(ctx, password);
    const user_id = try insert_user(ctx, raw_email, raw_display_name, password_hash, roles);

    return .{ .user_id = user_id, .password = generated };
}

/// For tests: `editor@example.com` who can sign in with `correct horse battery`.
pub fn seed_editor(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.now_ms >= 0);

    var hash_buffer: [auth.password.hash_len_max]u8 = undefined;
    const password_hash = try example_password_hash(ctx, &hash_buffer);

    _ = try insert_user(ctx, "editor@example.com", "Editor", password_hash, &.{role.editor});
}

fn example_password_hash(ctx: *Ctx, buffer: *[auth.password.hash_len_max]u8) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(buffer.len == auth.password.hash_len_max);

    return ctx.auth.hash_password("correct horse battery", ctx.io, buffer) catch error.Invalid;
}

/// For tests: `admin@example.com` who can sign in with `correct horse battery`.
pub fn seed_admin(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.now_ms >= 0);

    var hash_buffer: [auth.password.hash_len_max]u8 = undefined;
    const password_hash = try example_password_hash(ctx, &hash_buffer);

    _ = try insert_user(ctx, "admin@example.com", "Admin", password_hash, &.{role.admin});
}

fn create_pending_user(
    ctx: *Ctx,
    raw_email: []const u8,
    raw_display_name: []const u8,
    roles: []const []const u8,
) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(raw_email.len > 0);

    return insert_user(ctx, raw_email, raw_display_name, null, roles);
}

/// Roles an account may be given: one to sixteen, each once, each declared by core or a
/// compiled-in plugin.
pub fn valid_roles(roles: []const []const u8) bool {
    std.debug.assert(role.user_roles_max > 0);
    std.debug.assert(registry.Roles.all.len > 0);

    if (roles.len == 0 or roles.len > role.user_roles_max) {
        return false;
    }

    for (roles, 0..) |name, index| {
        if (registry.Roles.get(name) == null) {
            return false;
        }

        for (roles[index + 1 ..]) |other| {
            if (std.mem.eql(u8, name, other)) {
                return false;
            }
        }
    }

    return true;
}

fn insert_user(
    ctx: *Ctx,
    raw_email: []const u8,
    raw_display_name: []const u8,
    password_hash: ?[]const u8,
    roles: []const []const u8,
) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(password_hash == null or password_hash.?.len > 0);

    if (!valid_roles(roles)) {
        return error.Invalid;
    }

    const email = store.users.normalize_email(ctx.arena, raw_email) catch |err| switch (err) {
        error.InvalidEmail => return error.Invalid,
        else => |other| return other,
    };
    const display_name = store.users.validate_display_name(raw_display_name) catch {
        return error.Invalid;
    };

    return store.users.insert(ctx.db, ctx.io, ctx.arena, .{
        .email = email,
        .display_name = display_name,
        .password_hash = password_hash,
        .roles = roles,
        .now_ms = ctx.now_ms,
    });
}

fn hash_password(ctx: *Ctx, password: []const u8) Error![]const u8 {
    std.debug.assert(ctx.auth.params.p == 1);

    var hash_buffer: [auth.password.hash_len_max]u8 = undefined;
    const hashed = ctx.auth.hash_password(password, ctx.io, &hash_buffer);
    const encoded = hashed catch |err| switch (err) {
        error.WeakPassword => return error.Invalid,
        error.HashFailed, error.WrongPassword => return error.Invalid,
    };

    std.debug.assert(encoded.len > 0);

    return try ctx.arena.dupe(u8, encoded);
}

fn generate_password(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(generated_alphabet.len == 31);
    std.debug.assert(generated_password_len >= auth.password.len_min);

    var raw: [generated_password_len]u8 = undefined;
    ctx.io.random(&raw);

    const password = try ctx.arena.alloc(u8, generated_password_len);

    for (raw, 0..) |byte, index| {
        password[index] = generated_alphabet[byte % generated_alphabet.len];
    }

    return password;
}

fn issue_link(ctx: *Ctx, user_id: []const u8) Error!Link {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(password_link_lifetime_ms > 0);

    var raw: [password_token_bytes]u8 = undefined;
    ctx.io.random(&raw);

    const token = std.fmt.bytesToHex(raw, .lower);
    const token_hash = hash_token(&token) orelse unreachable;
    const expires_at = ctx.now_ms + password_link_lifetime_ms;

    try store.users.set_password_token(ctx.db, user_id, token_hash, expires_at);

    const path = try std.fmt.allocPrint(ctx.arena, "{s}?token={s}", .{
        set_password_path,
        token,
    });

    return .{ .path = path, .expires_at = expires_at };
}

pub fn hash_token(token: []const u8) ?[store.users.token_hash_len]u8 {
    std.debug.assert(password_token_len == 64);
    std.debug.assert(password_token_bytes * 2 == password_token_len);

    if (token.len != password_token_len) {
        return null;
    }

    var raw: [password_token_bytes]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, token) catch return null;

    var digest: [store.users.token_hash_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&raw, &digest, .{});

    std.debug.assert(digest.len == 32);

    return digest;
}

pub fn find_user(ctx: *Ctx, id_or_email: []const u8) Error!?store.users.Credentials {
    std.debug.assert(id_or_email.len <= 64 << 10);
    std.debug.assert(ctx.now_ms >= 0);

    if (id_or_email.len == 0) {
        return null;
    }

    if (std.mem.indexOfScalar(u8, id_or_email, '@') != null) {
        const email = store.users.normalize_email(ctx.arena, id_or_email) catch return null;

        return store.users.find_by_email(ctx.db, ctx.arena, email);
    }

    return store.users.find_by_id(ctx.db, ctx.arena, id_or_email);
}

const manage = @import("user/manage.zig");
pub const fields = @import("user/fields.zig");
pub const Update = manage.Update;
pub const Delete = manage.Delete;
pub const Get = fields.Get;
pub const Validate = fields.Validate;

pub const operations = [_]type{
    Create, List, Get, Options, PasswordLink, SetPassword, Update, Delete, Validate,
};

pub fn summary_of(user: store.users.User) Summary {
    std.debug.assert(user.id.len > 0);
    std.debug.assert(user.email.len > 0);

    return .{
        .id = user.id,
        .email = user.email,
        .display_name = user.display_name,
        .roles = user.roles,
        .created_at = user.created_at,
        .active = user.active,
    };
}

const TestSDK = sdk.SDK(.{ .operations = &operations });

test "create: admins only, duplicates conflict, weak input invalid, generated password" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    var editor = harness.ctx(.{ .user = .{ .id = "u_editor", .roles = &.{"editor"} } });
    var anon = harness.ctx(.anonymous);

    const created = try TestSDK.dispatch(&admin, Create, Create.example);
    try std.testing.expectEqualStrings("editor", created.roles[0]);
    try std.testing.expect(created.password == null);
    try std.testing.expectError(error.Conflict, TestSDK.dispatch(&admin, Create, Create.example));
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&editor, Create, Create.example));
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&anon, Create, Create.example));
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&editor, List, .{}));

    var weak = Create.example;
    weak.email = "other@example.com";
    weak.password = "short";
    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&admin, Create, weak));

    var bad_email = Create.example;
    bad_email.email = "not-an-email";
    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&admin, Create, bad_email));

    const no_password: Create.In = .{ .email = "gen@example.com", .display_name = "Gen" };
    const generated = try TestSDK.dispatch(&admin, Create, no_password);
    try std.testing.expectEqual(@as(usize, generated_password_len), generated.password.?.len);
}

test "password link: pending user cannot sign in, link activates once, new link invalidates old" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const sign_in = @import("sign_in.zig");
    const FullSDK = sdk.SDK(.{ .operations = &(operations ++ sign_in.operations) });
    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    var anon = harness.ctx(.anonymous);

    const invited = try FullSDK.dispatch(&admin, Create, .{
        .email = "new@example.com",
        .display_name = "New",
        .password_link = true,
    });
    try std.testing.expect(invited.password == null);
    const link_prefix = set_password_path ++ "?token=";
    try std.testing.expect(std.mem.startsWith(u8, invited.link.?.path, link_prefix));
    try std.testing.expectEqual(password_link_lifetime_ms, invited.link.?.expires_at);

    const both = FullSDK.dispatch(&admin, Create, .{
        .email = "x@example.com",
        .display_name = "X",
        .password = "correct horse battery",
        .password_link = true,
    });
    try std.testing.expectError(error.Invalid, both);

    const login_pending = FullSDK.dispatch(&anon, sign_in.SignIn, .{
        .email = "new@example.com",
        .password = "correct horse battery",
    });
    try std.testing.expectError(error.BadCredentials, login_pending);

    const first_token = invited.link.?.path[set_password_path.len + 7 ..];
    const reissued = try FullSDK.dispatch(&admin, PasswordLink, .{ .user = "new@example.com" });
    const second_token = reissued.link.path[set_password_path.len + 7 ..];
    try std.testing.expect(!std.mem.eql(u8, first_token, second_token));

    const stale_in: SetPassword.In = .{ .token = first_token, .password = "correct horse battery" };
    const stale = FullSDK.dispatch(&anon, SetPassword, stale_in);
    try std.testing.expectError(error.NotFound, stale);

    var late = harness.ctx(.anonymous);
    late.now_ms = password_link_lifetime_ms;
    const second_in: SetPassword.In = .{
        .token = second_token,
        .password = "correct horse battery",
    };
    const expired = FullSDK.dispatch(&late, SetPassword, second_in);
    try std.testing.expectError(error.NotFound, expired);

    const activated = try FullSDK.dispatch(&anon, SetPassword, second_in);
    try std.testing.expectEqualStrings(invited.user_id, activated.user_id);

    const reused = FullSDK.dispatch(&anon, SetPassword, second_in);
    try std.testing.expectError(error.NotFound, reused);

    const signed_in = try FullSDK.dispatch(&anon, sign_in.SignIn, .{
        .email = "new@example.com",
        .password = "correct horse battery",
    });
    try std.testing.expectEqualStrings(invited.user_id, signed_in.user_id);

    const ghost = FullSDK.dispatch(&admin, PasswordLink, .{ .user = "ghost@example.com" });
    try std.testing.expectError(error.NotFound, ghost);
}

test "user field options are available to editors without account details" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    var editor = harness.ctx(.{ .user = .{ .id = "u_editor", .roles = &.{"editor"} } });
    var anon = harness.ctx(.anonymous);
    const created = try TestSDK.dispatch(&admin, Create, Create.example);
    const options = try TestSDK.dispatch(&editor, Options, .{});
    try std.testing.expectEqual(@as(usize, 1), options.users.len);
    try std.testing.expectEqualStrings(created.user_id, options.users[0].id);
    const output_fields = @typeInfo(@TypeOf(options.users[0])).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), output_fields.len);
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&anon, Options, .{}));
}
