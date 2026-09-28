const std = @import("std");
const sdk = @import("../sdk.zig");
const auth = @import("../lib/auth.zig");
const settings = @import("../store/settings.zig");
const user = @import("user.zig");
const store = @import("../store.zig");
pub const changes = @import("site/changes.zig");
pub const impact = @import("site/impact.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Role = sdk.caller.Role;

pub const namespace: sdk.operation.Namespace = .{
    .name = "site",
    .summary = "The installation itself: first-run setup",
    .details =
    \\What a fresh Publr needs before it can be used. `publr init` (short for
    \\`site init`) sets the site up: it creates the first admin and marks the site as
    \\initialised, exactly once. More site-wide concerns (settings, info) will join
    \\this namespace.
    ,
};

pub const setup_key = "site.initialised_at";

pub const Init = struct {
    pub const name = "site.init";
    pub const description = "Set up a fresh installation: creates the first admin, exactly once";
    pub const details =
        \\Run this once, right after the first `serve` (or before). It creates the first
        \\account with the `admin` role and records that the site is set up, so it can
        \\never run again: not after deleting users, not with `--as-admin`. Anyone may
        \\call it, which is why running it early matters. Later accounts are created
        \\with `user create`.
        \\
        \\Omit `--password` to have a strong one generated and printed once, or set the
        \\`PUBLR_PASSWORD` environment variable to keep it out of your shell history.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        email: []const u8,
        display_name: []const u8,
        password: ?[]const u8 = null,
    };
    pub const Out = struct { user_id: []const u8, role: Role, password: ?[]const u8 };
    pub const example: In = .{ .email = "ada@example.com", .display_name = "Ada" };
    pub const example_out: Out = .{
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .role = .admin,
        .password = "k7pm2xq9rt4wnb8vhc3z",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .email = "Sign-in email; stored lowercased and trimmed",
        .display_name = "Name shown in the admin",
        .password = "8 to 256 characters; generated and shown once when omitted",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_id = "The new account's id",
        .role = "Always `admin` for the first account",
        .password = "The generated password, only when you did not pass one; shown exactly once",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.email.len > 64 << 10) {
            return error.Invalid;
        }

        if (try settings.get(ctx.db, ctx.arena, setup_key) != null) {
            return error.Conflict;
        }

        if (try store.users.count_admins(ctx.db) != 0) {
            return error.Conflict;
        }

        const created = try user.create_user(ctx, in.email, in.display_name, in.password, .admin);
        var stamp_buffer: [24]u8 = undefined;
        const stamp = std.fmt.bufPrint(&stamp_buffer, "{d}", .{ctx.now_ms}) catch unreachable;

        try settings.set(ctx.db, setup_key, stamp, ctx.now_ms);
        ctx.notice("site.initialised", created.user_id);
        ctx.notice("auth.user_created", created.user_id);

        return .{ .user_id = created.user_id, .role = .admin, .password = created.password };
    }
};

/// Whether `site init` has happened: the admin sends a fresh installation to setup.
pub const Status = struct {
    pub const name = "site.status";
    pub const description = "Whether the site has been initialised (its first admin created)";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { initialised: bool };
    pub const example: In = .{};
    pub const example_out: Out = .{ .initialised = true };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(setup_key.len > 0);

        const stamp = try settings.get(ctx.db, ctx.arena, setup_key);

        return .{ .initialised = stamp != null };
    }
};

pub const operations = [_]type{ Init, Status, impact.Impact };
pub const middleware = [_]type{changes.RecordChanged};

const TestSDK = sdk.SDK(.{ .operations = &operations });
const UserSDK = sdk.SDK(.{ .operations = &user.operations });

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
    try std.testing.expectEqual(Role.admin, first.role);
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
    const in: Init.In = .{ .email = "a@example.com", .display_name = "A" };
    const out = try TestSDK.dispatch(&anon, Init, in);
    try std.testing.expectEqual(@as(usize, user.generated_password_len), out.password.?.len);

    var system = harness.ctx(.system);
    const listed = try UserSDK.dispatch(&system, user.List, .{});
    try std.testing.expect(listed.users[0].active);
}
