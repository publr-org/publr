const std = @import("std");
const ids = @import("../lib/id.zig");
const account = @import("../model/account.zig");
const db = @import("../lib/db.zig");
const user_roles = @import("user_roles.zig");

pub const id_len = ids.len;
pub const email_len_max = account.email_len_max;
pub const display_name_len_max = account.display_name_len_max;
pub const normalize_email = account.normalize_email;
pub const validate_display_name = account.validate_display_name;
pub const EmailError = account.EmailError;
pub const NameError = account.NameError;
pub const list_max: u32 = 1000;

pub const token_hash_len: u32 = 32;

pub const User = struct {
    id: []const u8,
    email: []const u8,
    display_name: []const u8,
    /// The names of the roles the account holds.
    roles: []const []const u8,
    created_at: i64,
    active: bool,
};

pub const Credentials = struct {
    user: User,
    password_hash: ?[]const u8,
};

pub const Insert = struct {
    email: []const u8,
    display_name: []const u8,
    password_hash: ?[]const u8,
    roles: []const []const u8,
    now_ms: i64,
};

pub const new_id = ids.random;

/// For tests: an empty users table.
pub fn delete_all(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(id_len == 24);

    try connection.exec("DELETE FROM users");
}

pub fn count(connection: *db.Db) db.Error!u32 {
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*) FROM users");
    defer select.finalize();

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// How many accounts hold the role `name`.
pub fn count_holding(connection: *db.Db, name: []const u8) db.Error!u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    return user_roles.holders(connection, name);
}

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    row: Insert,
) db.Error![]const u8 {
    std.debug.assert(row.password_hash == null or row.password_hash.?.len > 0);
    std.debug.assert(row.now_ms >= 0);

    var id_buffer: [id_len]u8 = undefined;
    const id = arena.dupe(u8, new_id(io, &id_buffer)) catch return error.OutOfMemory;

    var statement = try connection.prepare(
        "INSERT INTO users " ++
            "(id, email, display_name, password_hash, created_at, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, row.email);
    try statement.bind_text(3, row.display_name);
    try statement.bind_optional_text(4, row.password_hash);
    try statement.bind_int(5, row.now_ms);
    try statement.exec();
    try user_roles.set(connection, id, row.roles);

    return id;
}

const select_columns = "id, email, display_name, created_at, password_hash FROM users";

pub fn set_password_token(
    connection: *db.Db,
    user_id: []const u8,
    token_hash: [token_hash_len]u8,
    expires_at: i64,
) db.Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(expires_at > 0);

    var statement = try connection.prepare(
        "UPDATE users SET password_token_hash = ?1, password_token_expires_at = ?2 WHERE id = ?3",
    );
    defer statement.finalize();

    try statement.bind_blob(1, &token_hash);
    try statement.bind_int(2, expires_at);
    try statement.bind_text(3, user_id);
    try statement.exec();
}

pub fn find_by_password_token(
    connection: *db.Db,
    arena: std.mem.Allocator,
    token_hash: [token_hash_len]u8,
    now_ms: i64,
) db.Error!?Credentials {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(token_hash.len == token_hash_len);

    var select = try connection.prepare(
        "SELECT " ++ select_columns ++
            " WHERE password_token_hash = ?1 AND password_token_expires_at > ?2",
    );
    defer select.finalize();

    try select.bind_blob(1, &token_hash);
    try select.bind_int(2, now_ms);

    return try read_credentials(connection, &select, arena);
}

pub fn set_password(
    connection: *db.Db,
    user_id: []const u8,
    password_hash: []const u8,
    now_ms: i64,
) db.Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(password_hash.len > 0);

    var statement = try connection.prepare(
        "UPDATE users SET password_hash = ?1, password_token_hash = NULL, " ++
            "password_token_expires_at = NULL, updated_at = ?2 WHERE id = ?3",
    );
    defer statement.finalize();

    try statement.bind_text(1, password_hash);
    try statement.bind_int(2, now_ms);
    try statement.bind_text(3, user_id);
    try statement.exec();
}

pub fn find_by_email(
    connection: *db.Db,
    arena: std.mem.Allocator,
    email: []const u8,
) db.Error!?Credentials {
    std.debug.assert(email.len > 0);
    std.debug.assert(email.len <= email_len_max);

    var select = try connection.prepare("SELECT " ++ select_columns ++ " WHERE email = ?1");
    defer select.finalize();

    try select.bind_text(1, email);

    return try read_credentials(connection, &select, arena);
}

pub fn find_by_id(
    connection: *db.Db,
    arena: std.mem.Allocator,
    id: []const u8,
) db.Error!?Credentials {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= account.id_len_max);

    var select = try connection.prepare("SELECT " ++ select_columns ++ " WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    return try read_credentials(connection, &select, arena);
}

/// The account's name and roles, replaced together; false when there is no such account.
pub fn update(
    connection: *db.Db,
    user_id: []const u8,
    display_name: []const u8,
    roles: []const []const u8,
    now_ms: i64,
) db.Error!bool {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(display_name.len <= display_name_len_max);

    var statement = try connection.prepare(
        "UPDATE users SET display_name = ?1, updated_at = ?2 WHERE id = ?3",
    );
    defer statement.finalize();

    try statement.bind_text(1, display_name);
    try statement.bind_int(2, now_ms);
    try statement.bind_text(3, user_id);
    try statement.exec();

    if (connection.changes() != 1) {
        return false;
    }

    try user_roles.set(connection, user_id, roles);

    return true;
}

pub fn delete(connection: *db.Db, user_id: []const u8) db.Error!bool {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var statement = try connection.prepare("DELETE FROM users WHERE id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, user_id);
    try statement.exec();

    return connection.changes() == 1;
}

pub fn list(connection: *db.Db, arena: std.mem.Allocator) db.Error![]User {
    std.debug.assert(list_max > 0);

    var select = try connection.prepare(
        "SELECT " ++ select_columns ++ " ORDER BY created_at, email LIMIT " ++
            std.fmt.comptimePrint("{d}", .{list_max}),
    );
    defer select.finalize();

    var users: std.ArrayList(User) = .empty;

    while (try select.step()) {
        std.debug.assert(users.items.len < list_max);
        const credentials = try read_row(connection, &select, arena);
        users.append(arena, credentials.user) catch return error.OutOfMemory;
    }

    return users.items;
}

/// `select_columns`, in order.
const Columns = struct {
    id: []const u8,
    email: []const u8,
    display_name: []const u8,
    created_at: i64,
    password_hash: ?[]const u8,
};

fn read_credentials(
    connection: *db.Db,
    select: *db.Statement,
    arena: std.mem.Allocator,
) db.Error!?Credentials {
    std.debug.assert(id_len > 0);
    std.debug.assert(email_len_max > 0);

    if (!try select.step()) {
        return null;
    }

    return try read_row(connection, select, arena);
}

fn read_row(
    connection: *db.Db,
    select: *db.Statement,
    arena: std.mem.Allocator,
) db.Error!Credentials {
    const columns = try select.read(Columns, arena);

    std.debug.assert(columns.id.len > 0);
    std.debug.assert(columns.email.len > 0);

    return .{
        .user = .{
            .id = columns.id,
            .email = columns.email,
            .display_name = columns.display_name,
            .roles = try user_roles.of(connection, arena, columns.id),
            .created_at = columns.created_at,
            .active = columns.password_hash != null,
        },
        .password_hash = columns.password_hash,
    };
}

test "insert, count, find by email/id, list; emails are unique" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(u32, 0), try count(&fixture.connection));

    const id = try insert(&fixture.connection, std.testing.io, arena, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password_hash = "$argon2id$x",
        .roles = &.{"admin"},
        .now_ms = 1_000,
    });

    try std.testing.expectEqual(@as(usize, id_len), id.len);
    try std.testing.expectEqual(@as(u32, 1), try count(&fixture.connection));

    const by_email = (try find_by_email(&fixture.connection, arena, "ada@example.com")).?;
    try std.testing.expectEqualStrings(id, by_email.user.id);
    try std.testing.expectEqualStrings("$argon2id$x", by_email.password_hash.?);
    try std.testing.expect(by_email.user.active);
    try std.testing.expectEqualStrings("admin", by_email.user.roles[0]);

    const by_id = (try find_by_id(&fixture.connection, arena, id)).?;
    try std.testing.expectEqualStrings("Ada", by_id.user.display_name);
    try std.testing.expect((try find_by_id(&fixture.connection, arena, "missing")) == null);

    const duplicate = insert(&fixture.connection, std.testing.io, arena, .{
        .email = "ada@example.com",
        .display_name = "Ada 2",
        .password_hash = "$argon2id$y",
        .roles = &.{"editor"},
        .now_ms = 2_000,
    });
    try std.testing.expectError(error.Constraint, duplicate);

    const users = try list(&fixture.connection, arena);
    try std.testing.expectEqual(@as(usize, 1), users.len);
}

test "pending user: no password, token lookup honours expiry, set_password activates" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = try insert(&fixture.connection, std.testing.io, arena, .{
        .email = "pending@example.com",
        .display_name = "Pending",
        .password_hash = null,
        .roles = &.{"editor"},
        .now_ms = 1_000,
    });
    const pending = (try find_by_id(&fixture.connection, arena, id)).?;
    try std.testing.expect(!pending.user.active);
    try std.testing.expect(pending.password_hash == null);

    const token_hash: [token_hash_len]u8 = @splat(9);
    try set_password_token(&fixture.connection, id, token_hash, 5_000);
    const connection = &fixture.connection;
    const live = try find_by_password_token(connection, arena, token_hash, 4_999);
    const expired = try find_by_password_token(connection, arena, token_hash, 5_000);
    try std.testing.expect(live != null);
    try std.testing.expect(expired == null);

    try set_password(&fixture.connection, id, "$argon2id$z", 4_000);
    const active = (try find_by_id(&fixture.connection, arena, id)).?;
    try std.testing.expect(active.user.active);
    const consumed = try find_by_password_token(connection, arena, token_hash, 4_999);
    try std.testing.expect(consumed == null);
}

test "update changes name and roles; delete answers whether a row went" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = try insert(&fixture.connection, std.testing.io, arena, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password_hash = "$argon2id$x",
        .roles = &.{"editor"},
        .now_ms = 1_000,
    });

    const promoted = &.{ "admin", "editor" };
    try std.testing.expect(try update(&fixture.connection, id, "Ada L.", promoted, 2_000));
    const changed = (try find_by_id(&fixture.connection, arena, id)).?;
    try std.testing.expectEqualStrings("Ada L.", changed.user.display_name);
    try std.testing.expectEqual(@as(usize, 2), changed.user.roles.len);
    try std.testing.expectEqual(@as(u32, 1), try count_holding(&fixture.connection, "admin"));
    try std.testing.expect(!try update(&fixture.connection, "missing", "X", &.{}, 2_000));

    try std.testing.expect(try delete(&fixture.connection, id));
    try std.testing.expect(!try delete(&fixture.connection, id));
    try std.testing.expectEqual(@as(u32, 0), try count(&fixture.connection));
}
