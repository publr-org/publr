const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/user.zig");
const auth = @import("../lib/auth.zig");
const store = @import("../store.zig");
const role = @import("../model/role.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const invitation_path = public.invitation_path;
pub const password_link_lifetime_ms: i64 = 60 * 60 * 1000;
pub const password_token_bytes: u32 = 32;
pub const password_token_len: u32 = password_token_bytes * 2;
pub const generated_password_len: u32 = 20;

const generated_alphabet = "abcdefghjkmnpqrstuvwxyz23456789";

pub const Summary = public.Summary;

pub const Link = public.Link;

pub const Create = struct {
    pub const shape = public.Create;
    pub const name = shape.name;
    pub const secret = shape.secret;
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
        std.debug.assert(ctx.caller != .anonymous);

        if (in.password_link and in.password != null) {
            return error.Invalid;
        }

        try check_user_type(ctx, in.user_type);
        try visitors.refuse_other_type(ctx, in.user_type);

        const roles = try roles_of_new(ctx, in.roles, in.user_type);

        try staff.refuse_from_plugin(ctx, &.{}, roles);

        if (in.password_link) {
            const created = try create_pending_user(ctx, in.email, in.display_name, roles);

            try give_type(ctx, created, in.user_type);

            const link = try issue_link(ctx, created);

            ctx.emit(UserCreated, .{
                .user = created,
            });

            return .{
                .user_id = created,
                .roles = roles,
                .password = null,
                .link = link,
            };
        }

        const created = try create_user(ctx, in.email, in.display_name, in.password, roles);

        try give_type(ctx, created.user_id, in.user_type);
        ctx.emit(UserCreated, .{
            .user = created.user_id,
        });

        return .{
            .user_id = created.user_id,
            .roles = roles,
            .password = created.password,
            .link = null,
        };
    }
};

/// The roles a new account holds: the ones named, and with a type its roles joining them.
/// Nothing is given unasked: no roles named and no type is an account holding none. A type
/// giving a staff role gives nothing: a type of user is never a way into the admin.
fn roles_of_new(
    ctx: *Ctx,
    named: ?[]const []const u8,
    user_type: []const u8,
) Error![]const []const u8 {
    std.debug.assert(user_type.len <= 1 << 16);
    std.debug.assert(ctx.now_ms >= 0);

    if (user_type.len == 0) {
        return named orelse &.{};
    }

    const user_types = @import("../sdk/user_types.zig");
    const declared = try user_types.find(ctx, user_type) orelse return error.Invalid;

    if (try user_types.staff_role_given(ctx, declared) != null) {
        return error.Denied;
    }

    var roles: std.ArrayList([]const u8) = .empty;

    try roles.appendSlice(ctx.arena, named orelse &.{});

    for (declared.roles) |given| {
        if (!visitors.held(roles.items, given)) {
            try roles.append(ctx.arena, given);
        }
    }

    return roles.items;
}

/// A type given is one a plugin registers now.
fn check_user_type(ctx: *Ctx, user_type: []const u8) Error!void {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(user_type.len <= 1 << 16);

    if (user_type.len == 0) {
        return;
    }

    if (try @import("../sdk/user_types.zig").find(ctx, user_type) == null) {
        return error.Invalid;
    }
}

fn give_type(ctx: *Ctx, user_id: []const u8, user_type: []const u8) Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(user_type.len <= 64);

    if (user_type.len > 0) {
        _ = try store.user_types.add(ctx.db, user_id, user_type);
    }
}

pub const PasswordLink = struct {
    pub const shape = public.PasswordLink;
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
        std.debug.assert(ctx.caller != .anonymous);

        const credentials = try find_user(ctx, in.user) orelse return error.NotFound;

        try visitors.refuse_other_account(ctx, credentials.user);

        const link = try issue_link(ctx, credentials.user.id);

        return .{
            .user_id = credentials.user.id,
            .link = link,
        };
    }
};

pub const SetPassword = struct {
    pub const shape = public.SetPassword;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const secret = shape.secret;
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

        const token_hash = hash_token(in.token) orelse return error.NotFound;
        const now_ms = ctx.now_ms;
        const found = try store.users.find_by_password_token(ctx.db, ctx.arena, token_hash, now_ms);
        const credentials = found orelse return error.NotFound;
        const password_hash = try hash_password(ctx, in.password);

        try store.users.set_password(ctx.db, credentials.user.id, password_hash, ctx.now_ms);
        _ = try store.sessions.destroy_all(ctx.db, credentials.user.id);
        _ = try store.devices.revoke_all(ctx.db, credentials.user.id, ctx.now_ms);

        return .{
            .user_id = credentials.user.id,
            .email = credentials.user.email,
        };
    }
};

pub const Options = struct {
    pub const shape = public.Options;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Option = shape.Option;
    pub const Out = shape.Out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());

        var window = try window_of(in.query, in.limit, in.offset);

        window.type_roles = try @import("../sdk/user_types.zig").roles_given_json(ctx);

        const rows = try store.users.page(ctx.db, ctx.arena, window);
        const users = try ctx.arena.alloc(Option, rows.len);

        for (rows, 0..) |row, index| {
            users[index] = .{
                .id = row.id,
                .label = row.display_name,
            };
        }

        return .{
            .users = users,
            .total = try store.users.count_matching(ctx.db, window),
        };
    }
};

/// A page of users as asked for; `Invalid` past the bounds every list shares.
fn window_of(query: []const u8, limit: u32, offset: u32) Error!store.users.Window {
    if (limit == 0 or limit > sdk.operation.page_limit_max or query.len > 256) {
        return error.Invalid;
    }

    std.debug.assert(limit <= store.users.list_max);

    return .{
        .query = query,
        .limit = limit,
        .offset = offset,
    };
}

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const field_docs = shape.field_docs;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.caller != .anonymous);
        std.debug.assert(store.users.list_max > 0);

        var window = try window_of(in.query, in.limit, in.offset);

        if (in.sort.len > model.field.path_len_max) {
            return error.Invalid;
        }

        if (in.user_type.len > model.user_type.name_len_max) {
            return error.Invalid;
        }

        try visitors.refuse_unread_type(ctx, in.user_type);

        window.sort = in.sort;
        window.user_type = in.user_type;
        window.type_roles = try @import("../sdk/user_types.zig").roles_given_json(ctx);

        const rows = try store.users.page(ctx.db, ctx.arena, window);
        const users = try ctx.arena.alloc(Summary, rows.len);

        for (rows, 0..) |row, index| {
            users[index] = summary_of(row);
        }

        return .{
            .users = users,
            .total = try store.users.count_matching(ctx.db, window),
            .extended = try stored_columns(ctx, users),
        };
    }
};

/// The fields plugins store on accounts that their columns show, read for the page at once.
fn stored_columns(ctx: *Ctx, users: []const Summary) Error!sdk.Extended {
    const extended = try sdk.Extended.start(ctx.arena, &ctx.plugin);

    std.debug.assert(users.len <= store.users.list_max);

    if (users.len == 0) {
        return extended;
    }

    const ids = try ctx.arena.alloc([]const u8, users.len);

    for (users, ids) |user, *id| {
        id.* = user.id;
    }

    const list = std.json.Stringify.valueAlloc(ctx.arena, ids, .{}) catch {
        return error.OutOfMemory;
    };

    for (try registry.all_columns(ctx)) |column| {
        if (!column.stored or !column.on("users")) {
            continue;
        }

        const found = try store.user_values.field_values(ctx.db, ctx.arena, column.field, list);

        for (found) |each| {
            try extended.set(each.record, column.field, switch (each.value) {
                .integer => |number| .{
                    .integer = number,
                },
                .real => |number| .{
                    .float = number,
                },
                .text => |text| .{
                    .string = text,
                },
                .blob, .null => continue,
            });
        }
    }

    return extended;
}

pub const CreatedUser = struct {
    user_id: []const u8,
    password: ?[]const u8,
};

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

    return .{
        .user_id = user_id,
        .password = generated,
    };
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

pub fn create_pending_user(
    ctx: *Ctx,
    raw_email: []const u8,
    raw_display_name: []const u8,
    roles: []const []const u8,
) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(raw_email.len > 0);

    return insert_user(ctx, raw_email, raw_display_name, null, roles);
}

/// Roles an account may be given: one to sixteen, each once, each a stored role.
pub fn valid_roles(ctx: *const Ctx, roles: []const []const u8) Error!bool {
    std.debug.assert(role.user_roles_max > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (roles.len > role.user_roles_max) {
        return false;
    }

    for (roles, 0..) |name, index| {
        if (!try sdk.stored_roles.exists(ctx, name)) {
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

    if (!try valid_roles(ctx, roles)) {
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
    return issue_link_at(ctx, user_id, invitation_path);
}

/// A one-hour set-password link to `page` (the admin's welcome, or a page of the app an
/// account of a user type signs in to); the account's earlier link stops working.
pub fn issue_link_at(ctx: *Ctx, user_id: []const u8, page: []const u8) Error!Link {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(password_link_lifetime_ms > 0);

    var raw: [password_token_bytes]u8 = undefined;
    ctx.io.random(&raw);

    const token = std.fmt.bytesToHex(raw, .lower);
    const token_hash = hash_token(&token) orelse unreachable;
    const expires_at = ctx.now_ms + password_link_lifetime_ms;

    try store.users.set_password_token(ctx.db, user_id, token_hash, expires_at);

    const path = try std.fmt.allocPrint(ctx.arena, "{s}?token={s}", .{
        page,
        token,
    });

    return .{
        .path = path,
        .expires_at = expires_at,
    };
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

pub const language = @import("user/language.zig");
pub const visitors = @import("user/visitors.zig");
pub const columns = @import("user/columns.zig");
pub const types = @import("user/types.zig");
pub const staff = @import("user/staff.zig");
pub const AddType = types.AddType;
pub const RemoveType = types.RemoveType;

pub const operations = [_]type{
    Create,
    List,
    Get,
    Options,
    PasswordLink,
    SetPassword,
    Update,
    Delete,
    Validate,
    language.Language,
    language.SetLanguage,
    columns.Columns,
    columns.SetColumns,
} ++ visitors.operations ++ types.operations;

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
        .user_types = user.user_types,
    };
}

const TestSDK = sdk.SDK(.{
    .operations = &operations,
});

test "create: admins only, duplicates conflict, weak input invalid, generated password" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_editor",
            .roles = &.{"editor"},
        },
    });
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

    const no_password: Create.In = .{
        .email = "gen@example.com",
        .display_name = "Gen",
    };
    const generated = try TestSDK.dispatch(&admin, Create, no_password);
    try std.testing.expectEqual(@as(usize, generated_password_len), generated.password.?.len);
}

test "password link: pending user cannot sign in, link activates once, new link invalidates old" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const sign_in = @import("sign_in.zig");
    const FullSDK = sdk.SDK(.{
        .operations = &(operations ++ sign_in.operations),
    });
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var anon = harness.ctx(.anonymous);

    const invited = try FullSDK.dispatch(&admin, Create, .{
        .email = "new@example.com",
        .display_name = "New",
        .password_link = true,
    });
    try std.testing.expect(invited.password == null);
    const link_prefix = invitation_path ++ "?token=";
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

    const first_token = invited.link.?.path[invitation_path.len + 7 ..];
    const reissued = try FullSDK.dispatch(&admin, PasswordLink, .{
        .user = "new@example.com",
    });
    const second_token = reissued.link.path[invitation_path.len + 7 ..];
    try std.testing.expect(!std.mem.eql(u8, first_token, second_token));

    const stale_in: SetPassword.In = .{
        .token = first_token,
        .password = "correct horse battery",
    };
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

    const ghost = FullSDK.dispatch(&admin, PasswordLink, .{
        .user = "ghost@example.com",
    });
    try std.testing.expectError(error.NotFound, ghost);
}

test "user field options are available to editors without account details" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_editor",
            .roles = &.{"editor"},
        },
    });
    var anon = harness.ctx(.anonymous);
    const created = try TestSDK.dispatch(&admin, Create, Create.example);
    const options = try TestSDK.dispatch(&editor, Options, .{});
    try std.testing.expectEqual(@as(usize, 1), options.users.len);
    try std.testing.expectEqualStrings(created.user_id, options.users[0].id);
    const output_fields = @typeInfo(@TypeOf(options.users[0])).@"struct".field_names;
    try std.testing.expectEqual(@as(usize, 2), output_fields.len);
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&anon, Options, .{}));
}

/// An account was made: by an administrator, by signing up, through a sign-in provider, or
/// the first one when the project was set up.
pub const UserCreated = event_define(.{
    .name = "auth.user_created",
    .payload = struct {
        /// The new account
        user: []const u8,
    },
});

const event_define = @import("../publr/plugin/hook_define.zig").event;
