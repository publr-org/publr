//! Changing and removing accounts; the rules that keep one admin around.
const std = @import("std");
const members = @import("members.zig");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/user/manage.zig");
const store = @import("../../store.zig");
const trash = @import("../trash.zig");
const user_operations = @import("../user.zig");
const role = @import("../../model/role.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Update = struct {
    pub const shape = public.Update;
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

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;

        try members.refuse_other_account(ctx, found.user);

        try members.refuse_roles_not_its_own(ctx, in.roles);
        try user_operations.staff.refuse_from_plugin(ctx, found.user.roles, in.roles);

        const display_name = store.users.validate_display_name(in.display_name) catch {
            return error.Invalid;
        };

        if (!try user_operations.valid_roles(ctx, in.roles)) {
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
            const defs = try user_operations.fields.definition(ctx, found.user.id, in.roles);

            try user_operations.fields.write(ctx, found.user.id, defs, text.text);
        }

        return .{
            .user_id = found.user.id,
            .roles = in.roles,
        };
    }
};

pub const Delete = struct {
    pub const shape = public.Delete;
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

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;

        try members.refuse_other_account(ctx, found.user);

        if (is_self(ctx, found.user.id)) {
            return error.Invalid;
        }

        const admin = holds(found.user.roles, role.admin);

        if (admin and try store.users.count_holding(ctx.db, role.admin) <= 1) {
            return error.Conflict;
        }

        const key = std.fmt.allocPrint(ctx.arena, "[\"{s}\"]", .{found.user.id}) catch {
            return error.OutOfMemory;
        };
        const label = std.fmt.allocPrint(ctx.arena, "User {s} ({s})", .{
            found.user.display_name,
            found.user.email,
        }) catch return error.OutOfMemory;

        _ = try trash.keep(ctx, .{
            .kind = "user",
            .key = found.user.id,
            .label = label,
            .roots = &.{
                .{
                    .table = "users",
                    .column = "id",
                    .keys = key,
                },
                .{
                    .table = "user_search",
                    .column = "record",
                    .keys = key,
                },
            },
            // Signed out for good: a restored account signs in afresh.
            .skip = &.{ "sessions", "devices", "device_requests" },
        });

        const revoked = try store.sessions.destroy_all(ctx.db, found.user.id);

        try store.user_values.clear(ctx.db, found.user.id, null);

        const deleted = try store.users.delete(ctx.db, found.user.id);

        std.debug.assert(deleted);

        return .{
            .user_id = found.user.id,
            .sessions_revoked = revoked,
        };
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

const TestSDK = sdk.SDK(.{
    .operations = &user_operations.operations,
});

test "update: renames and changes role; the last admin stays an admin" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);
    const admin_id = (try user_operations.find_user(&system, "admin@example.com")).?.user.id;
    var admin = harness.ctx(.{
        .user = .{
            .id = admin_id,
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_editor",
            .roles = &.{"editor"},
        },
    });
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
    var lead = harness.ctx(.{
        .user = .{
            .id = created.user_id,
            .roles = &.{"admin"},
        },
    });
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
    var admin = harness.ctx(.{
        .user = .{
            .id = admin_id,
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_editor",
            .roles = &.{"editor"},
        },
    });
    const Create = user_operations.Create;
    const connection = &harness.fixture.connection;

    const created = try TestSDK.dispatch(&admin, Create, Create.example);
    _ = try store.sessions.create(connection, std.testing.io, admin.arena, created.user_id, 0);
    const by_editor = TestSDK.dispatch(&editor, Delete, .{
        .user = created.user_id,
    });
    try std.testing.expectError(error.Denied, by_editor);
    const self = TestSDK.dispatch(&admin, Delete, .{
        .user = admin_id,
    });
    try std.testing.expectError(error.Invalid, self);

    const deleted = try TestSDK.dispatch(&admin, Delete, .{
        .user = "writer@example.com",
    });
    try std.testing.expectEqualStrings(created.user_id, deleted.user_id);
    try std.testing.expectEqual(@as(u32, 1), deleted.sessions_revoked);
    const gone = TestSDK.dispatch(&admin, Delete, .{
        .user = created.user_id,
    });
    try std.testing.expectError(error.NotFound, gone);

    var other = harness.ctx(.{
        .user = .{
            .id = "u_other",
            .roles = &.{"admin"},
        },
    });
    const last_admin = TestSDK.dispatch(&other, Delete, .{
        .user = admin_id,
    });
    try std.testing.expectError(error.Conflict, last_admin);
}
