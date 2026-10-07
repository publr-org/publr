//! Changing and removing accounts; the rules that keep one admin around.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const user_operations = @import("../user.zig");
const role = @import("../../model/role.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const example_id = "9b1e7c3d5a2f4e6b8d0c1a3f";

pub const Update = struct {
    pub const name = "user.update";
    pub const description = "Rename a user or change their roles";
    pub const details =
        \\Admins only. The display name and the roles are replaced together; the email
        \\and the password stay. The last admin cannot lose the `admin` role, and no
        \\admin can take it from themselves. Every session of the account stays open.
        \\With `document`, the custom field values are replaced too, validated against
        \\the groups that apply to the account's new roles (`user get` shows them).
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
        display_name: []const u8,
        roles: []const []const u8,
        document: ?[]const u8 = null,
    };
    pub const Out = struct { user_id: []const u8, roles: []const []const u8 };
    pub const example: In = .{
        .user = "editor@example.com",
        .display_name = "Editor",
        .roles = &.{"admin"},
    };
    pub const example_out: Out = .{ .user_id = example_id, .roles = &.{"admin"} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The user's id or email",
        .display_name = "Name shown in the admin, 1 to 80 characters",
        .roles = "The roles the account holds from now on, comma-separated (`role list`)",
        .document = "The custom field values as JSON, one object per group; omitted, they stay",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_id = "The user's id",
        .roles = "The roles the account holds now",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.caller != .anonymous);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const display_name = store.users.validate_display_name(in.display_name) catch {
            return error.Invalid;
        };

        if (!user_operations.valid_roles(in.roles)) {
            return error.Invalid;
        }

        const demoted = holds(found.user.roles, role.admin) and !holds(in.roles, role.admin);

        if (demoted and is_self(ctx, found.user.id)) {
            return error.Invalid;
        }

        if (demoted and try store.users.count_holding(ctx.db, role.admin) <= 1) {
            return error.Conflict;
        }

        const changed = try store.users.update(
            ctx.db,
            found.user.id,
            display_name,
            in.roles,
            ctx.now_ms,
        );

        std.debug.assert(changed);

        if (in.document) |text| {
            const defs = try user_operations.fields.definition(ctx, in.roles);

            try user_operations.fields.write(ctx, found.user.id, defs, text);
        }

        ctx.notice("auth.user_updated", found.user.id);

        return .{ .user_id = found.user.id, .roles = in.roles };
    }
};

pub const Delete = struct {
    pub const name = "user.delete";
    pub const description = "Delete a user and sign out every session they have";
    pub const details =
        \\Admins only. The account goes for good; what the person created stays,
        \\attributed to their id. You cannot delete yourself, and the last admin
        \\cannot be deleted.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct { user: []const u8 };
    pub const Out = struct { user_id: []const u8, sessions_revoked: u32 };
    pub const example: In = .{ .user = "editor@example.com" };
    pub const example_out: Out = .{ .user_id = example_id, .sessions_revoked = 1 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The user's id or email",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_id = "The deleted user's id",
        .sessions_revoked = "How many of their sessions were signed out",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.caller != .anonymous);

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;

        if (is_self(ctx, found.user.id)) {
            return error.Invalid;
        }

        const admin = holds(found.user.roles, role.admin);

        if (admin and try store.users.count_holding(ctx.db, role.admin) <= 1) {
            return error.Conflict;
        }

        const revoked = try store.sessions.destroy_all(ctx.db, found.user.id);

        try store.user_values.clear(ctx.db, found.user.id, null);

        const deleted = try store.users.delete(ctx.db, found.user.id);

        std.debug.assert(deleted);

        ctx.notice("auth.user_deleted", found.user.id);

        return .{ .user_id = found.user.id, .sessions_revoked = revoked };
    }
};

fn holds(roles: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(roles.len <= role.user_roles_max);

    for (roles) |held| {
        if (std.mem.eql(u8, held, name)) {
            return true;
        }
    }

    return false;
}

fn is_self(ctx: *const Ctx, user_id: []const u8) bool {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(ctx.caller != .anonymous);

    const own = ctx.caller.user_id() orelse return false;

    return std.mem.eql(u8, own, user_id);
}

const TestSDK = sdk.SDK(.{ .operations = &user_operations.operations });

test "update: renames and changes role; the last admin stays an admin" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);
    const admin_id = (try user_operations.find_user(&system, "admin@example.com")).?.user.id;
    var admin = harness.ctx(.{ .user = .{ .id = admin_id, .roles = &.{"admin"} } });
    var editor = harness.ctx(.{ .user = .{ .id = "u_editor", .roles = &.{"editor"} } });
    const Create = user_operations.Create;

    const created = try TestSDK.dispatch(&admin, Create, Create.example);
    const promote: Update.In = .{
        .user = created.user_id,
        .display_name = "Lead",
        .roles = &.{"admin"},
    };
    const promoted = try TestSDK.dispatch(&admin, Update, promote);
    try std.testing.expectEqualStrings("admin", promoted.roles[0]);
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&editor, Update, promote));

    const listed = try TestSDK.dispatch(&admin, user_operations.List, .{});
    try std.testing.expectEqualStrings("Lead", listed.users[1].display_name);

    const self_demote: Update.In = .{
        .user = admin_id,
        .display_name = "Admin",
        .roles = &.{"editor"},
    };
    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&admin, Update, self_demote));

    const demote: Update.In = .{
        .user = created.user_id,
        .display_name = "Lead",
        .roles = &.{"editor"},
    };
    _ = try TestSDK.dispatch(&admin, Update, demote);
    var lead = harness.ctx(.{ .user = .{ .id = created.user_id, .roles = &.{"admin"} } });
    try std.testing.expectError(error.Conflict, TestSDK.dispatch(&lead, Update, self_demote));

    const blank: Update.In = .{
        .user = created.user_id,
        .display_name = " ",
        .roles = &.{"editor"},
    };
    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&admin, Update, blank));
    const ghost: Update.In = .{
        .user = "ghost@example.com",
        .display_name = "G",
        .roles = &.{"editor"},
    };
    try std.testing.expectError(error.NotFound, TestSDK.dispatch(&admin, Update, ghost));
}

test "delete: signs the account out; never yourself, never the last admin" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);
    const admin_id = (try user_operations.find_user(&system, "admin@example.com")).?.user.id;
    var admin = harness.ctx(.{ .user = .{ .id = admin_id, .roles = &.{"admin"} } });
    var editor = harness.ctx(.{ .user = .{ .id = "u_editor", .roles = &.{"editor"} } });
    const Create = user_operations.Create;
    const connection = &harness.fixture.connection;

    const created = try TestSDK.dispatch(&admin, Create, Create.example);
    _ = try store.sessions.create(connection, std.testing.io, admin.arena, created.user_id, 0);
    const by_editor = TestSDK.dispatch(&editor, Delete, .{ .user = created.user_id });
    try std.testing.expectError(error.Denied, by_editor);
    const self = TestSDK.dispatch(&admin, Delete, .{ .user = admin_id });
    try std.testing.expectError(error.Invalid, self);

    const deleted = try TestSDK.dispatch(&admin, Delete, .{ .user = "writer@example.com" });
    try std.testing.expectEqualStrings(created.user_id, deleted.user_id);
    try std.testing.expectEqual(@as(u32, 1), deleted.sessions_revoked);
    const gone = TestSDK.dispatch(&admin, Delete, .{ .user = created.user_id });
    try std.testing.expectError(error.NotFound, gone);

    var other = harness.ctx(.{ .user = .{ .id = "u_other", .roles = &.{"admin"} } });
    const last_admin = TestSDK.dispatch(&other, Delete, .{ .user = admin_id });
    try std.testing.expectError(error.Conflict, last_admin);
}
