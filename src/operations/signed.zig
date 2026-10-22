//! Around making a session, the sign-in events plugins hook (`publr.auth`): `before`
//! hooks first (they may only refuse), then the session, then `after` hooks inside the same
//! write, then the event for the queued `on` hooks. An administrator is never refused.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const role = @import("../model/role.zig");
const registry = @import("../server/registry.zig");
const events = @import("../sdk/auth_events.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const User = store.users.User;

/// What `before` hooks hear, ahead of the session: their refusal fails the sign-in.
pub fn before(ctx: *Ctx, user: User, method: []const u8) Error!void {
    std.debug.assert(user.id.len > 0);
    std.debug.assert(method.len > 0);

    const payload = signed(ctx, user, method);

    try registry.SDK.event_hooks(ctx, .before, events.SignedIn, payload, spared(user));
}

/// Once the session is made: `after` hooks in the same write, then the event.
pub fn after(ctx: *Ctx, user: User, method: []const u8) Error!void {
    std.debug.assert(user.id.len > 0);
    std.debug.assert(method.len > 0);

    const payload = signed(ctx, user, method);

    try registry.SDK.event_hooks(ctx, .after, events.SignedIn, payload, spared(user));
    raise(ctx, events.SignedIn, payload);
}

/// A person created their own account: `before` and `after` hooks may refuse it, then the
/// event; emitted ahead of their first sign-in.
pub fn signed_up(ctx: *Ctx, user: User, method: []const u8) Error!void {
    std.debug.assert(user.id.len > 0);
    std.debug.assert(method.len > 0);

    const payload = signed(ctx, user, method);

    try registry.SDK.event_hooks(ctx, .before, events.SignedUp, payload, spared(user));
    try registry.SDK.event_hooks(ctx, .after, events.SignedUp, payload, spared(user));
    raise(ctx, events.SignedUp, payload);
}

/// Someone signed out: `after` hooks, which never stop it, then the event.
pub fn signed_out(ctx: *Ctx, user_id: []const u8) Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(!events.refusable(events.SignedOut.full_name));

    const payload: events.SignedOut.Payload = .{
        .user = user_id,
        .visitor = ctx.visitor,
    };

    try registry.SDK.event_hooks(ctx, .after, events.SignedOut, payload, true);
    raise(ctx, events.SignedOut, payload);
}

fn signed(ctx: *const Ctx, user: User, method: []const u8) events.SignedIn.Payload {
    std.debug.assert(user.id.len > 0);

    return .{
        .user = user.id,
        .visitor = ctx.visitor,
        .method = method,
    };
}

fn spared(user: User) bool {
    std.debug.assert(user.id.len > 0);

    for (user.roles) |held| {
        if (std.mem.eql(u8, held, role.admin)) {
            return true;
        }
    }

    return false;
}

fn raise(ctx: *Ctx, comptime Event: type, payload: Event.Payload) void {
    std.debug.assert(Event.full_name.len > 0);
    std.debug.assert(ctx.parent != null);

    ctx.emit_heard(Event.full_name, payload);
}

test "sign-in hooks: before refuses, after writes in the same write, administrators go on" {
    const internal = @import("internal.zig");
    const sign_in = @import("sign_in.zig");
    const users = @import("user.zig");
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var system = project.ctx(.system);
    try users.seed_editor(&system);
    try users.seed_admin(&system);

    const editor: sign_in.SignIn.In = .{
        .email = "editor@example.com",
        .password = "correct horse battery",
    };
    const admin: sign_in.SignIn.In = .{
        .email = "admin@example.com",
        .password = "correct horse battery",
    };

    var refused = project.ctx(.anonymous);
    // The visitor greeter's `before` hook refuses.
    refused.visitor = "0000000000000000000000ff";
    const refusing = registry.SDK.dispatch(&refused, sign_in.SignIn, editor);

    try std.testing.expectError(error.Denied, refusing);

    const spared_in = try registry.SDK.dispatch(&refused, sign_in.SignIn, admin);
    try std.testing.expect(spared_in.token.len > 0);

    var anyone = project.ctx(.anonymous);
    const signed_in = try registry.SDK.dispatch(&anyone, sign_in.SignIn, editor);
    _ = try registry.SDK.dispatch(&anyone, sign_in.SignOut, .{
        .token = signed_in.token,
    });

    const kept = try registry.SDK.dispatch(&system, internal.Find, .{
        .plugin = "greeter",
        .kind = "visit",
    });
    var names: [8][]const u8 = undefined;

    for (kept.records, 0..) |record, index| {
        names[index] = record.document;
    }

    const all = try std.mem.join(system.arena, "|", names[0..kept.records.len]);

    // The refused sign-in wrote nothing; the administrator's and the editor's each one note.
    try std.testing.expectEqual(@as(usize, 3), kept.records.len);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, all, "signed:password"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, all, "\"left\""));
}

test "sign-in hooks fail closed, only read in before, carry the visitor, spare administrators" {
    const internal = @import("internal.zig");
    const sign_in = @import("sign_in.zig");
    const users = @import("user.zig");
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var system = project.ctx(.system);
    try users.seed_editor(&system);
    try users.seed_admin(&system);

    const editor: sign_in.SignIn.In = .{
        .email = "editor@example.com",
        .password = "correct horse battery",
    };
    const admin: sign_in.SignIn.In = .{
        .email = "admin@example.com",
        .password = "correct horse battery",
    };

    // A hook that crashes refuses (fails closed); an administrator still signs in.
    var crashing = project.ctx(.anonymous);
    crashing.visitor = "0000000000000000000000fe";
    const crashed = registry.SDK.dispatch(&crashing, sign_in.SignIn, editor);

    try std.testing.expectError(error.Unavailable, crashed);
    _ = try registry.SDK.dispatch(&crashing, sign_in.SignIn, admin);

    // A refusal in the plugin's own words reaches the caller; an administrator goes on.
    var suspended = project.ctx(.anonymous);
    suspended.visitor = "0000000000000000000000fc";
    const refused = registry.SDK.dispatch(&suspended, sign_in.SignIn, editor);

    try std.testing.expectError(error.Failed, refused);
    try std.testing.expectEqualStrings("AccountSuspended", suspended.failure.?.name);
    try std.testing.expectEqualStrings("This account is on hold.", suspended.failure.?.message);

    var spared_ctx = project.ctx(.anonymous);
    spared_ctx.visitor = "0000000000000000000000fc";
    const spared_in = try registry.SDK.dispatch(&spared_ctx, sign_in.SignIn, admin);

    try std.testing.expect(spared_ctx.failure == null);
    try std.testing.expectEqualStrings("admin", spared_in.roles[0]);

    // A `before` hook that tries to write is refused the write; the sign-in goes on.
    var writing = project.ctx(.anonymous);
    writing.visitor = "0000000000000000000000fd";
    const signed_in = try registry.SDK.dispatch(&writing, sign_in.SignIn, editor);

    try std.testing.expect(signed_in.token.len > 0);
    try std.testing.expectEqualStrings("editor", signed_in.roles[0]);

    const kept = try registry.SDK.dispatch(&system, internal.Find, .{
        .plugin = "greeter",
        .kind = "visit",
    });
    var names: [8][]const u8 = undefined;

    for (kept.records, 0..) |record, index| {
        names[index] = record.document;
    }

    const all = try std.mem.join(system.arena, "|", names[0..kept.records.len]);

    // Two administrators' sign-ins and the editor's, each with the visitor from before; the
    // write the `before` hook tried is not there, nor any credential.
    try std.testing.expectEqual(@as(usize, 3), kept.records.len);
    try std.testing.expect(std.mem.indexOf(u8, all, "\"before\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, all, "password:0000000000000000000000fd") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "correct horse") == null);
    try std.testing.expect(std.mem.indexOf(u8, all, signed_in.token) == null);
}
