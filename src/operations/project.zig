const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/project.zig");
const auth = @import("../lib/auth.zig");
const settings = @import("../store/settings.zig");
const user = @import("user.zig");
const language = @import("user/language.zig");
const store = @import("../store.zig");
pub const changes = @import("project/changes.zig");
pub const impact = @import("project/impact.zig");
pub const move_app = @import("project/move_app.zig");
pub const Put = @import("project/put.zig").Put;
pub const Get = @import("project/get.zig").Get;

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const role = @import("../model/role.zig");

pub const namespace = public.namespace;

pub const setup_key = "project.initialised_at";

pub const Init = struct {
    pub const shape = public.Init;
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

        if (in.email.len > 64 << 10) {
            return error.Invalid;
        }

        if (try settings.get(ctx.db, ctx.arena, setup_key) != null) {
            return error.Conflict;
        }

        if (try store.users.count_holding(ctx.db, role.admin) != 0) {
            return error.Conflict;
        }

        if (!try language.valid(ctx, in.language)) {
            return language.refused(ctx, "language");
        }

        const admin: []const []const u8 = &.{role.admin};
        const created = try user.create_user(ctx, in.email, in.display_name, in.password, admin);

        try language.set_first(ctx, created.user_id, in.language);
        var stamp_buffer: [24]u8 = undefined;
        const stamp = std.fmt.bufPrint(&stamp_buffer, "{d}", .{ctx.now_ms}) catch unreachable;

        try settings.set(ctx.db, setup_key, stamp, ctx.now_ms);
        ctx.emit(user.UserCreated, .{
            .user = created.user_id,
        });

        return .{
            .user_id = created.user_id,
            .roles = admin,
            .password = created.password,
        };
    }
};

pub const Status = struct {
    pub const shape = public.Status;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(setup_key.len > 0);

        const stamp = try settings.get(ctx.db, ctx.arena, setup_key);
        // A database made before `init` recorded the stamp has its administrator all the same.
        const administered = try store.users.count_holding(ctx.db, role.admin) != 0;

        return .{
            .initialised = stamp != null or administered,
        };
    }
};

test "status: initialised once set up, or when an administrator exists without the stamp" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var anon = harness.ctx(.anonymous);
    const fresh = try TestSDK.dispatch(&anon, Status, .{});

    try std.testing.expect(!fresh.initialised);

    _ = try TestSDK.dispatch(&anon, Init, .{
        .email = "a@example.com",
        .display_name = "A",
        .password = "correct horse battery",
    });
    try settings.delete(&harness.fixture.connection, setup_key);

    const unstamped = try TestSDK.dispatch(&anon, Status, .{});

    try std.testing.expect(unstamped.initialised);
}

pub const operations = [_]type{
    Init,
    Status,
    impact.Impact,
    move_app.MoveApp,
    @import("user/language.zig").SetSiteLanguage,
    Put,
    Get,
};
pub const hooks = changes.hooks ++ @import("activity.zig").hooks;

const TestSDK = sdk.SDK(.{
    .operations = &operations,
});
const UserSDK = sdk.SDK(.{
    .operations = &user.operations,
});

test "init runs once: anonymous may call it, then it conflicts for everyone, even system" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var anon = harness.ctx(.anonymous);
    const first = try TestSDK.dispatch(&anon, Init, .{
        .email = " Admin@Example.com ",
        .display_name = "Ada",
        .password = "correct horse battery",
    });
    try std.testing.expectEqualStrings("admin", first.roles[0]);
    try std.testing.expectEqual(@as(usize, store.users.id_len), first.user_id.len);
    try std.testing.expect(first.password == null);

    var system = harness.ctx(.system);
    try std.testing.expectError(error.Conflict, TestSDK.dispatch(&anon, Init, Init.example));
    try std.testing.expectError(error.Conflict, TestSDK.dispatch(&system, Init, Init.example));

    try store.users.delete_all(&harness.fixture.connection);
    try std.testing.expectError(error.Conflict, TestSDK.dispatch(&system, Init, Init.example));
}

test "init without a password generates one and returns it once" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var anon = harness.ctx(.anonymous);
    const in: Init.In = .{
        .email = "a@example.com",
        .display_name = "A",
    };
    const out = try TestSDK.dispatch(&anon, Init, in);
    try std.testing.expectEqual(@as(usize, user.generated_password_len), out.password.?.len);

    var system = harness.ctx(.system);
    const listed = try UserSDK.dispatch(&system, user.List, .{});
    try std.testing.expect(listed.users[0].active);
}

test "init sets the site language and the first admin's own, never asked again; unknown refused" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var anon = harness.ctx(.anonymous);

    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&anon, Init, .{
        .email = "a@example.com",
        .display_name = "A",
        .password = "correct horse battery",
        .language = "xx",
    }));

    // Refused before anything is made: the project can still be set up.
    const first = try TestSDK.dispatch(&anon, Init, .{
        .email = "a@example.com",
        .display_name = "A",
        .password = "correct horse battery",
        .language = "en",
    });
    var ada = harness.ctx(.{
        .user = .{
            .id = first.user_id,
            .roles = &.{"admin"},
        },
    });
    const shown = try UserSDK.dispatch(&ada, language.Language, .{});

    try std.testing.expect(shown.answered);
    try std.testing.expectEqualStrings("en", shown.site);
    try std.testing.expectEqualStrings("en", shown.shown);
}

test {
    _ = @import("project/put_tests.zig");
    _ = @import("project/get_tests.zig");
    _ = @import("project/changes_tests.zig");
}
