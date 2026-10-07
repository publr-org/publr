//! Devices: agents and tools a person lets act for their account, signing in by link. This
//! file is the device's side (asking, collecting its token); `device/people.zig` the
//! person's (approving, listing, revoking).

const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const model = @import("../model/device.zig");
pub const people = @import("device/people.zig");
const collect = @import("device/collect.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const approve_path = "/admin/settings/devices/approve";
pub const device_code_bytes: u32 = 32;
pub const device_code_len: u32 = device_code_bytes * 2;
const user_code_attempts: u32 = 4;

pub const namespace: sdk.operation.Namespace = .{
    .name = "device",
    .summary = "Agents and tools acting for an account, signed in by link",
    .details =
    \\A device (an agent, the CLI on another machine) asks with `device start` and shows
    \\its person a link; they open it signed in to the admin and approve it, choosing
    \\what it may do: `read`, `drafts` (write, but publishing waits for a person) or
    \\`write`. The device collects its token with `device poll` and sends it as
    \\`Authorization: Bearer <token>`. `publr login <address>` does all of this.
    \\
    \\A device acts as its account with that account's roles, narrowed by its scope. It
    \\never destroys anything for good (deleting a content type, purging a record): that
    \\is done in the admin. Its changes show in the activity log as `token:<id>`.
    \\`device list` and `device revoke` manage them.
    ,
};

pub const operations = [_]type{Start} ++ collect.operations ++ people.operations;

pub const example_device_code = "9f2c" ** 16;

pub const Start = struct {
    pub const name = "device.start";
    pub const description = "Ask to act for an account: answers the link a person approves";
    pub const details =
        \\Anyone may call it. `name` is what the person will see ("An agent on Ada's
        \\laptop"), `scope` what the device asks to do (the person may give less). Show
        \\the person `approve_path` on this site (it carries the user code), then call
        \\`device poll` with `device_code` every `interval_s` seconds until it answers.
        \\The request lapses after ten minutes.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct { name: []const u8, scope: []const u8 = "drafts" };
    pub const Out = struct {
        device_code: []const u8,
        user_code: []const u8,
        approve_path: []const u8,
        expires_at: i64,
        interval_s: u32,
    };
    pub const example: In = .{ .name = "An agent on Ada's laptop", .scope = "drafts" };
    pub const example_out: Out = .{
        .device_code = example_device_code,
        .user_code = "WXZB-CDFG",
        .approve_path = approve_path ++ "?code=WXZB-CDFG",
        .expires_at = 1792232000000,
        .interval_s = model.poll_interval_s,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "What the person sees, 1 to 80 characters",
        .scope = "What the device asks to do: `read`, `drafts` or `write`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .device_code = "The device's secret for `device poll`; never shown to anyone",
        .user_code = "The code the person approves",
        .approve_path = "Where the person approves it, on this site",
        .expires_at = "When the request lapses, Unix milliseconds",
        .interval_s = "How often to poll, in seconds",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!model.valid_name(in.name) or model.Scope.parse(in.scope) == null) {
            return error.Invalid;
        }

        _ = try store.device_requests.cleanup(ctx.db, ctx.now_ms);

        var secret: [device_code_bytes]u8 = undefined;
        ctx.io.random(&secret);

        const device_code = std.fmt.bytesToHex(secret, .lower);
        const expires_at = ctx.now_ms + model.request_lifetime_ms;
        const user_code = try insert(ctx, &device_code, in, expires_at);
        const path = std.fmt.allocPrint(ctx.arena, "{s}?code={s}", .{ approve_path, user_code });

        return .{
            .device_code = try ctx.arena.dupe(u8, &device_code),
            .user_code = user_code,
            .approve_path = path catch return error.OutOfMemory,
            .expires_at = expires_at,
            .interval_s = model.poll_interval_s,
        };
    }

    /// The request stored under a fresh user code; a code another waiting request holds is
    /// drawn again.
    fn insert(ctx: *Ctx, device_code: []const u8, in: In, expires_at: i64) Error![]const u8 {
        std.debug.assert(device_code.len == device_code_len);

        var attempt: u32 = 0;

        while (attempt < user_code_attempts) : (attempt += 1) {
            var random: [8]u8 = undefined;
            ctx.io.random(&random);

            const user_code = model.user_code(random);
            const inserted = try store.device_requests.insert(ctx.db, .{
                .code_hash = hash_of(device_code),
                .user_code = &user_code,
                .name = in.name,
                .scope = in.scope,
                .expires_at = expires_at,
            }, ctx.now_ms);

            if (inserted) {
                return ctx.arena.dupe(u8, &user_code) catch error.OutOfMemory;
            }
        }

        return error.Busy;
    }
};

pub fn hash_of(device_code: []const u8) [32]u8 {
    std.debug.assert(device_code.len > 0);
    std.debug.assert(device_code.len <= 1 << 10);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(device_code, &hash, .{});

    return hash;
}

const registry = @import("../server/registry.zig");
const user_operations = @import("user.zig");

const Poll = collect.Poll;
const Claim = collect.Claim;

test {
    _ = people;
    _ = collect;
}

/// A device for the seeded editor, approved through the whole flow: its token.
fn approved(harness: *sdk.testing.Harness, asked: []const u8, given: []const u8) ![]const u8 {
    std.debug.assert(model.Scope.parse(asked) != null);

    var anonymous = harness.ctx(.anonymous);
    const started = try registry.SDK.dispatch(&anonymous, Start, .{
        .name = "laptop",
        .scope = asked,
    });
    const pending = try registry.SDK.dispatch(&anonymous, Poll, .{
        .device_code = started.device_code,
    });

    try std.testing.expectEqualStrings("pending", pending.state);
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&anonymous, people.Approve, .{
        .code = started.user_code,
        .scope = given,
    }));

    var system = harness.ctx(.system);
    const editor = (try registry.SDK.dispatch(&system, user_operations.List, .{})).users[0];
    var person = harness.ctx(.{ .user = .{ .id = editor.id, .roles = editor.roles } });
    const typed = try std.ascii.allocLowerString(person.arena, started.user_code);
    const shown = try registry.SDK.dispatch(&person, people.Request, .{ .code = typed });

    try std.testing.expectEqualStrings("laptop", shown.name);
    _ = try registry.SDK.dispatch(&person, people.Approve, .{
        .code = started.user_code,
        .scope = given,
    });

    const code: collect.Poll.In = .{ .device_code = started.device_code };
    const claim: collect.Claim.In = .{ .device_code = started.device_code };
    const decided = try registry.SDK.dispatch(&anonymous, Poll, code);
    const claimed = try registry.SDK.dispatch(&anonymous, Claim, claim);
    const again = try registry.SDK.dispatch(&anonymous, Poll, code);

    try std.testing.expectEqualStrings("approved", decided.state);
    try std.testing.expectEqualStrings(given, claimed.scope);
    try std.testing.expectEqualStrings("expired", again.state);
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&anonymous, Claim, claim));

    return claimed.token;
}

fn device_ctx(harness: *sdk.testing.Harness, token: []const u8) !Ctx {
    std.debug.assert(token.len == store.devices.token_len);

    const probe = harness.ctx(.anonymous);
    const device = try store.devices.validate(probe.db, probe.arena, token, 0);
    const account = (try store.users.find_by_id(probe.db, probe.arena, device.user_id)).?;

    return harness.ctx(.{ .token = .{
        .id = device.id,
        .user_id = device.user_id,
        .roles = account.user.roles,
        .scope = model.Scope.parse(device.scope).?,
        .name = device.name,
    } });
}

test "a device signs in by link: asked, approved with less, collected once" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_editor(&system);

    const token = try approved(&harness, "write", "drafts");
    var device = try device_ctx(&harness, token);
    const listed = try registry.SDK.dispatch(&device, people.List, .{});

    try std.testing.expectEqual(@as(usize, 1), listed.devices.len);
    try std.testing.expect(listed.devices[0].current);
    try std.testing.expectEqualStrings("drafts", listed.devices[0].scope);
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&device, people.List, .{
        .all = true,
    }));
    try std.testing.expectError(error.Invalid, approved(&harness, "read", "write"));
}

test "a person denies a device; a lapsed request is gone" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_editor(&system);

    var anonymous = harness.ctx(.anonymous);
    const started = try registry.SDK.dispatch(&anonymous, Start, Start.example);
    const editor = (try registry.SDK.dispatch(&system, user_operations.List, .{})).users[0];
    var person = harness.ctx(.{ .user = .{ .id = editor.id, .roles = editor.roles } });

    _ = try registry.SDK.dispatch(&person, people.Deny, .{ .code = started.user_code });
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&person, people.Approve, .{
        .code = started.user_code,
        .scope = "read",
    }));

    const answer = try registry.SDK.dispatch(&anonymous, Poll, .{
        .device_code = started.device_code,
    });
    try std.testing.expectEqualStrings("denied", answer.state);

    const lapsing = try registry.SDK.dispatch(&anonymous, Start, Start.example);
    var later = harness.ctx(.anonymous);
    later.now_ms = lapsing.expires_at;
    const lapsed = try registry.SDK.dispatch(&later, Poll, .{
        .device_code = lapsing.device_code,
    });
    try std.testing.expectEqualStrings("expired", lapsed.state);
    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&anonymous, Start, .{
        .name = "",
    }));
}

test "a device never destroys, a drafts device never publishes, a revoked one stops" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_editor(&system);
    try registry.SDK.bootstrap(&system);
    try @import("record/fixture.zig").post_type(&system);

    const record_operations = @import("record.zig");
    const lifecycle = @import("record/lifecycle.zig");
    const created = try registry.SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = record_operations.example_document,
    });
    const token = try approved(&harness, "drafts", "drafts");
    var device = try device_ctx(&harness, token);

    try std.testing.expectError(error.Failed, registry.SDK.dispatch(&device, lifecycle.Purge, .{
        .id = created.id,
    }));
    try std.testing.expectEqualStrings("NeedsPerson", device.failure.?.name);

    _ = try registry.SDK.dispatch(&device, record_operations.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Draft edit\"}",
        .expected_version = null,
    });
    try std.testing.expectError(error.Failed, registry.SDK.dispatch(&device, lifecycle.Publish, .{
        .id = created.id,
    }));
    try std.testing.expectEqualStrings("DraftsOnly", device.failure.?.name);

    const current = try registry.SDK.dispatch(&system, record_operations.Get, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("draft", current.record.status);

    const id = device.caller.token.id;
    _ = try registry.SDK.dispatch(&device, people.Revoke, .{ .id = id });
    try std.testing.expectError(
        error.DeviceNotFound,
        store.devices.validate(system.db, system.arena, token, 0),
    );
}
