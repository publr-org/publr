//! An account's identities: which providers vouch for it, adding one, dropping one.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const identity_operations = @import("../identity.zig");
const user_operations = @import("../user.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Link = struct {
    pub const name = "identity.link";
    pub const description = "Link a provider's identity to an account";
    pub const details =
        \\Administrators, and the system: `/auth/<provider>/callback` calls it for a
        \\signed-in person once the provider plugin has verified who they are, so an
        \\account gains a second way in. An identity already linked, to this account or
        \\another, is a conflict; an account may hold sixteen.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
        provider: []const u8,
        id: []const u8,
        email: ?[]const u8 = null,
        verified: bool = false,
        name: ?[]const u8 = null,
        avatar: ?[]const u8 = null,
    };
    pub const Out = struct { linked: bool };
    pub const example: In = .{
        .user = "ada@example.com",
        .provider = "google",
        .id = "110248495921712042890",
        .email = identity_operations.example_in.email,
        .verified = true,
    };
    pub const example_out: Out = .{ .linked = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The account to link to, by id or email",
        .provider = identity_operations.in_docs.provider,
        .id = identity_operations.in_docs.id,
        .email = identity_operations.in_docs.email,
        .verified = identity_operations.in_docs.verified,
        .name = identity_operations.in_docs.name,
        .avatar = identity_operations.in_docs.avatar,
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .linked = "Always true" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        const identity = try identity_operations.identity_of(.{
            .provider = in.provider,
            .id = in.id,
            .email = in.email,
            .verified = in.verified,
            .name = in.name,
            .avatar = in.avatar,
        });
        const account = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const user_id = account.user.id;

        if (try store.identities.find(ctx.db, ctx.arena, identity.provider, identity.id) != null) {
            return error.Conflict;
        }

        try identity_operations.link(ctx, user_id, identity);
        ctx.notice("auth.identity_linked", user_id);

        return .{ .linked = true };
    }
};

pub const Summary = struct {
    provider: []const u8,
    id: []const u8,
    email: ?[]const u8,
    created_at: i64,
    last_used_at: i64,
};

pub const List = struct {
    pub const name = "identity.list";
    pub const description = "The providers that vouch for an account";
    pub const details =
        \\A signed-in account lists its own; `user` names another account, for the system
        \\and administrators. Nothing is written.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { user: ?[]const u8 = null };
    pub const Out = struct { identities: []const Summary };
    pub const example: In = .{};
    pub const example_out: Out = .{ .identities = &.{.{
        .provider = "github",
        .id = "583231",
        .email = "ada@example.com",
        .created_at = 1789640000000,
        .last_used_at = 1792232000000,
    }} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The account's id; the caller's own when omitted",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .identities = "Each linked identity, oldest first; times are Unix milliseconds",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(store.identities.per_user_max > 0);

        const user_id = try subject(ctx, in.user);
        const rows = try store.identities.of_user(ctx.db, ctx.arena, user_id);
        const identities = ctx.arena.alloc(Summary, rows.len) catch return error.OutOfMemory;

        for (rows, 0..) |row, index| {
            identities[index] = .{
                .provider = row.provider,
                .id = row.provider_id,
                .email = row.email,
                .created_at = row.created_at,
                .last_used_at = row.last_used_at,
            };
        }

        std.debug.assert(identities.len <= store.identities.per_user_max);

        return .{ .identities = identities };
    }
};

pub const Unlink = struct {
    pub const name = "identity.unlink";
    pub const description = "Drop a provider's identity from an account";
    pub const details =
        \\A signed-in account drops its own; `user` names another account, for the system
        \\and administrators. The last identity of an account without a password stays: dropping it
        \\would lock the account out, and that is a conflict. An identity the account does
        \\not hold is not found.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { provider: []const u8, id: []const u8, user: ?[]const u8 = null };
    pub const Out = struct { unlinked: bool };
    pub const example: In = .{ .provider = "github", .id = "583231" };
    pub const example_out: Out = .{ .unlinked = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .provider = identity_operations.in_docs.provider,
        .id = identity_operations.in_docs.id,
        .user = "The account's id; the caller's own when omitted",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .unlinked = "Always true" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        const user_id = try subject(ctx, in.user);
        const identity = try identity_operations.identity_of(.{
            .provider = in.provider,
            .id = in.id,
        });
        const row = try store.identities.find(ctx.db, ctx.arena, identity.provider, identity.id);

        if (row == null or !std.mem.eql(u8, row.?.user_id, user_id)) {
            return error.NotFound;
        }

        const account = try store.users.find_by_id(ctx.db, ctx.arena, user_id) orelse {
            return error.NotFound;
        };
        const last = try store.identities.count_of_user(ctx.db, user_id) == 1;

        if (last and account.password_hash == null) {
            return error.Conflict;
        }

        const removed = try store.identities.delete(ctx.db, identity.provider, identity.id);
        std.debug.assert(removed);

        ctx.notice("auth.identity_unlinked", user_id);

        return .{ .unlinked = true };
    }
};

/// Whose identities: the signed-in caller's own, or whoever an administrator or the
/// system names.
fn subject(ctx: *Ctx, named: ?[]const u8) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const user_id = switch (ctx.caller) {
        .user => |user| named orelse user.id,
        .system => named orelse return error.Invalid,
        else => return error.Denied,
    };

    if (user_id.len == 0 or user_id.len > store.users.id_len) {
        return error.Invalid;
    }

    if (ctx.caller == .user and !std.mem.eql(u8, user_id, ctx.caller.user.id)) {
        const held = ctx.caller.user.roles;

        if (!@import("../../server/registry.zig").Roles.allows(held, "user.update")) {
            return error.Denied;
        }
    }

    std.debug.assert(user_id.len > 0);

    return user_id;
}

test "an account links, lists and unlinks its own identities, never the last way in" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const SDK = @import("../../server/registry.zig").SDK;
    const user = @import("../user.zig");
    var system = harness.ctx(.system);
    var anon = harness.ctx(.anonymous);

    try SDK.bootstrap(&system);
    const ada = try SDK.dispatch(&system, user.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .roles = &.{"editor"},
        .password = "correct horse battery",
    });
    const eve = try SDK.dispatch(&system, user.Create, .{
        .email = "eve@example.com",
        .display_name = "Eve",
        .roles = &.{"editor"},
        .password = "correct horse battery",
    });
    var as_ada = harness.ctx(.{ .user = .{ .id = ada.user_id, .roles = &.{"editor"} } });
    var as_eve = harness.ctx(.{ .user = .{ .id = eve.user_id, .roles = &.{"editor"} } });
    var to_ada = Link.example;
    to_ada.user = ada.user_id;

    try std.testing.expectError(error.Denied, SDK.dispatch(&as_ada, Link, to_ada));
    try std.testing.expect((try SDK.dispatch(&system, Link, to_ada)).linked);
    try std.testing.expectError(error.Conflict, SDK.dispatch(&system, Link, to_ada));

    var to_eve = to_ada;
    to_eve.user = "eve@example.com";
    try std.testing.expectError(error.Conflict, SDK.dispatch(&system, Link, to_eve));

    var to_nobody = to_ada;
    to_nobody.user = "nobody@example.com";
    to_nobody.id = "7";
    try std.testing.expectError(error.NotFound, SDK.dispatch(&system, Link, to_nobody));

    const mine = try SDK.dispatch(&as_ada, List, .{});
    try std.testing.expectEqual(@as(usize, 1), mine.identities.len);
    try std.testing.expectEqualStrings(Link.example.id, mine.identities[0].id);
    const eves = try SDK.dispatch(&as_eve, List, .{});
    try std.testing.expectEqual(@as(usize, 0), eves.identities.len);
    const peek = SDK.dispatch(&as_eve, List, .{ .user = ada.user_id });
    try std.testing.expectError(error.Denied, peek);
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, List, .{}));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, List, .{}));
    const named = try SDK.dispatch(&system, List, .{ .user = ada.user_id });
    try std.testing.expectEqual(@as(usize, 1), named.identities.len);

    const drop: Unlink.In = .{ .provider = Link.example.provider, .id = Link.example.id };
    try std.testing.expectError(error.NotFound, SDK.dispatch(&as_eve, Unlink, drop));
    try std.testing.expect((try SDK.dispatch(&as_ada, Unlink, drop)).unlinked);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&as_ada, Unlink, drop));
    const none = try SDK.dispatch(&as_ada, List, .{});
    try std.testing.expectEqual(@as(usize, 0), none.identities.len);
}

test "the last identity of an account without a password cannot be dropped" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const SDK = @import("../../server/registry.zig").SDK;
    var system = harness.ctx(.system);

    try SDK.bootstrap(&system);
    _ = try SDK.dispatch(&system, identity_operations.Configure, .{ .open_sign_up = "editor" });
    const sign_in = identity_operations.SignIn;
    const created = try SDK.dispatch(&system, sign_in, identity_operations.example_in);
    var as_created = harness.ctx(.{ .user = .{ .id = created.user_id, .roles = &.{"editor"} } });

    try std.testing.expectError(error.Conflict, SDK.dispatch(&as_created, Unlink, Unlink.example));

    var google = Link.example;
    google.user = created.user_id;
    _ = try SDK.dispatch(&system, Link, google);
    try std.testing.expect((try SDK.dispatch(&as_created, Unlink, Unlink.example)).unlinked);

    const left = try SDK.dispatch(&as_created, List, .{});
    try std.testing.expectEqual(@as(usize, 1), left.identities.len);
    try std.testing.expectEqualStrings("google", left.identities[0].provider);
    try std.testing.expectError(error.Conflict, SDK.dispatch(&as_created, Unlink, .{
        .provider = "google",
        .id = Link.example.id,
    }));
}
