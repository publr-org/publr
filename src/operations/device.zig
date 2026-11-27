//! Devices: agents and tools a person lets act for their account, signing in by link. This
//! file is the device's side (asking, collecting its token); `device/people.zig` the
//! person's (approving, listing, revoking).

const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const model = @import("../model/device.zig");
pub const people = @import("device/people.zig");
const collect = @import("device/collect.zig");
const public = @import("../publr/operations/device.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const approve_path = public.approve_path;
pub const device_code_bytes: u32 = 32;
pub const device_code_len: u32 = device_code_bytes * 2;
const user_code_attempts: u32 = 4;

pub const namespace = public.namespace;

pub const Offer = @import("device/offer.zig").Offer;
pub const oauth = @import("device/oauth.zig");
pub const operations = [_]type{ Start, Offer } ++ collect.operations ++ people.operations ++
    oauth.operations;

pub const example_device_code = public.example_device_code;

pub const Start = struct {
    pub const shape = public.Start;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
        const user_code = try insert(ctx, .{
            .code_hash = hash_of(&device_code),
            .name = in.name,
            .scope = in.scope,
            .expires_at = expires_at,
        });
        const path = std.fmt.allocPrint(ctx.arena, "{s}?code={s}", .{ approve_path, user_code });

        return .{
            .device_code = try ctx.arena.dupe(u8, &device_code),
            .user_code = user_code,
            .approve_path = path catch return error.OutOfMemory,
            .expires_at = expires_at,
            .interval_s = model.poll_interval_s,
        };
    }
};

pub fn hash_of(device_code: []const u8) [32]u8 {
    std.debug.assert(device_code.len > 0);
    std.debug.assert(device_code.len <= 1 << 10);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(device_code, &hash, .{});

    return hash;
}

pub const Stored = struct {
    code_hash: [32]u8,
    name: []const u8,
    scope: []const u8,
    expires_at: i64,
    client_id: []const u8 = "",
    redirect_uri: []const u8 = "",
    code_challenge: []const u8 = "",
    client_state: []const u8 = "",
};

/// A request stored under a fresh user code, which it answers; a code another waiting
/// request holds is drawn again.
pub fn insert(ctx: *Ctx, new: Stored) Error![]const u8 {
    std.debug.assert(new.name.len > 0);
    std.debug.assert(new.expires_at > ctx.now_ms);

    var attempt: u32 = 0;

    while (attempt < user_code_attempts) : (attempt += 1) {
        var random: [8]u8 = undefined;
        ctx.io.random(&random);

        const user_code = model.user_code(random);
        const inserted = try store.device_requests.insert(ctx.db, .{
            .code_hash = new.code_hash,
            .user_code = &user_code,
            .name = new.name,
            .scope = new.scope,
            .expires_at = new.expires_at,
            .client_id = new.client_id,
            .redirect_uri = new.redirect_uri,
            .code_challenge = new.code_challenge,
            .client_state = new.client_state,
        }, ctx.now_ms);

        if (inserted) {
            return ctx.arena.dupe(u8, &user_code) catch error.OutOfMemory;
        }
    }

    return error.Busy;
}

const registry = @import("../server/registry.zig");
const user_operations = @import("user.zig");

const Poll = collect.Poll;
const Claim = collect.Claim;

test {
    _ = people;
    _ = collect;
    _ = oauth;
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
    var person = harness.ctx(.{
        .user = .{
            .id = editor.id,
            .roles = editor.roles,
        },
    });
    const typed = try std.ascii.allocLowerString(person.arena, started.user_code);
    const shown = try registry.SDK.dispatch(&person, people.Request, .{
        .code = typed,
    });

    try std.testing.expectEqualStrings("laptop", shown.name);
    _ = try registry.SDK.dispatch(&person, people.Approve, .{
        .code = started.user_code,
        .scope = given,
    });

    const code: collect.Poll.In = .{
        .device_code = started.device_code,
    };
    const claim: collect.Claim.In = .{
        .device_code = started.device_code,
    };
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

    return harness.ctx(.{
        .token = .{
            .id = device.id,
            .user_id = device.user_id,
            .roles = account.user.roles,
            .scope = model.Scope.parse(device.scope).?,
            .name = device.name,
        },
    });
}

test "a device signs in by link: asked, approved with less, collected once" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_editor(&system);

    const token = try approved(&harness, "publish", "production");
    var device = try device_ctx(&harness, token);
    const listed = try registry.SDK.dispatch(&device, people.List, .{});

    try std.testing.expectEqual(@as(usize, 1), listed.devices.len);
    try std.testing.expect(listed.devices[0].current);
    try std.testing.expectEqualStrings("production", listed.devices[0].scope);
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&device, people.List, .{
        .all = true,
    }));
    try std.testing.expectError(error.Invalid, approved(&harness, "read", "publish"));
}

test "a person changes what a device may do; the device never does" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_editor(&system);

    const token = try approved(&harness, "publish", "write");
    var device = try device_ctx(&harness, token);
    const id = (try registry.SDK.dispatch(&device, people.List, .{})).devices[0].id;

    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&device, people.Update, .{
        .id = id,
        .scope = "publish",
    }));

    const editor = (try registry.SDK.dispatch(&system, user_operations.List, .{})).users[0];
    var person = harness.ctx(.{
        .user = .{
            .id = editor.id,
            .roles = editor.roles,
        },
    });

    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&person, people.Update, .{
        .id = id,
        .scope = "drafts",
    }));

    _ = try registry.SDK.dispatch(&person, people.Update, .{
        .id = id,
        .scope = "production",
    });

    var again = try device_ctx(&harness, token);
    const listed = try registry.SDK.dispatch(&again, people.List, .{});

    try std.testing.expectEqualStrings("production", listed.devices[0].scope);
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
    var person = harness.ctx(.{
        .user = .{
            .id = editor.id,
            .roles = editor.roles,
        },
    });

    _ = try registry.SDK.dispatch(&person, people.Deny, .{
        .code = started.user_code,
    });
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
        .document = .{
            .text = record_operations.example_document,
        },
    });
    const token = try approved(&harness, "production", "production");
    var device = try device_ctx(&harness, token);

    try std.testing.expectError(error.Failed, registry.SDK.dispatch(&device, lifecycle.Purge, .{
        .id = created.id,
    }));
    // Not removed: listed for the device's person, who confirms it.
    try std.testing.expectEqualStrings("ListedForRemoval", device.failure.?.name);

    _ = try registry.SDK.dispatch(&device, record_operations.Save, .{
        .id = created.id,
        .document = .{
            .text = "{\"title\":\"Draft edit\"}",
        },
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
    _ = try registry.SDK.dispatch(&device, people.Revoke, .{
        .id = id,
    });
    try std.testing.expectError(
        error.DeviceNotFound,
        store.devices.validate(system.db, system.arena, token, 0),
    );
}
