//! The person's side of devices: the request they approve or deny, and the devices that
//! act for them, which they list and revoke. Every operation here is open (any account,
//! whatever its roles, manages its own devices) and checks who calls itself.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/device.zig");
const role = @import("../../model/role.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Request, Approve, Deny, List, Revoke };

pub const example_code = "WXZB-CDFG";
pub const example_device_id = "56a0794f6b1c67062563204a";

/// The account of a person signed in: never a device (a device never lets in another), never
/// anyone else.
fn person_of(ctx: *const Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    return switch (ctx.caller) {
        .user => |user| user.id,
        .anonymous, .token, .machine, .system, .plugin => error.Denied,
    };
}

/// A request still waiting, by the code the person has.
fn waiting(ctx: *Ctx, code: []const u8) Error!store.device_requests.Request {
    std.debug.assert(ctx.now_ms >= 0);

    const user_code = model.normalize_user_code(code) orelse return error.NotFound;
    const found = try store.device_requests.find_by_user_code(ctx.db, ctx.arena, &user_code);
    const request = found orelse return error.NotFound;

    if (request.expires_at <= ctx.now_ms or !std.mem.eql(u8, request.state, "pending")) {
        return error.NotFound;
    }

    std.debug.assert(request.name.len > 0);

    return request;
}

pub const Request = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.request";
    pub const description = "What a waiting device asks for, by the code its person has";
    pub const details =
        \\Any signed-in account; what the approve page shows. Not found once the request
        \\was decided or lapsed.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct { code: []const u8 };
    pub const Out = struct { name: []const u8, scope: []const u8, expires_at: i64 };
    pub const example: In = .{ .code = example_code };
    pub const example_out: Out = .{
        .name = "An agent on Ada's laptop",
        .scope = "drafts",
        .expires_at = 1792232000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{ .code = "The user code, `WXZB-CDFG`" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .name = "What the device calls itself",
        .scope = "What it asks to do",
        .expires_at = "When the request lapses, Unix milliseconds",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        _ = try person_of(ctx);

        const request = try waiting(ctx, in.code);

        return .{ .name = request.name, .scope = request.scope, .expires_at = request.expires_at };
    }
};

pub const Approve = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.approve";
    pub const description = "Let a waiting device act for your account";
    pub const details =
        \\A signed-in account approves for itself, never through a device. `scope` may be
        \\what the device asked or less. The device collects its token on its next poll.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct { code: []const u8, scope: []const u8 };
    pub const Out = struct { approved: bool };
    pub const example: In = .{ .code = example_code, .scope = "drafts" };
    pub const example_out: Out = .{ .approved = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .code = "The user code, `WXZB-CDFG`",
        .scope = "`read`, `drafts` or `write`, no more than it asked",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .approved = "Always true" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const user_id = try person_of(ctx);
        const request = try waiting(ctx, in.code);
        const given = model.Scope.parse(in.scope) orelse return error.Invalid;
        const asked = model.Scope.parse(request.scope) orelse return error.Invalid;

        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!given.within(asked)) {
            return error.Invalid;
        }

        const decided = try store.device_requests.decide(ctx.db, .{
            .user_code = request.user_code,
            .state = "approved",
            .scope = @tagName(given),
            .user_id = user_id,
        }, ctx.now_ms);

        if (!decided) {
            return error.NotFound;
        }

        return .{ .approved = true };
    }
};

pub const Deny = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.deny";
    pub const description = "Refuse a waiting device";
    pub const details = "A signed-in account. The device learns it on its next poll.";
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct { code: []const u8 };
    pub const Out = struct { denied: bool };
    pub const example: In = .{ .code = example_code };
    pub const example_out: Out = .{ .denied = true };
    pub const field_docs: sdk.operation.Docs(In) = .{ .code = "The user code, `WXZB-CDFG`" };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .denied = "Always true" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const user_id = try person_of(ctx);
        const request = try waiting(ctx, in.code);
        const decided = try store.device_requests.decide(ctx.db, .{
            .user_code = request.user_code,
            .state = "denied",
            .scope = request.scope,
            .user_id = user_id,
        }, ctx.now_ms);

        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!decided) {
            return error.NotFound;
        }

        return .{ .denied = true };
    }
};

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    scope: []const u8,
    user_id: []const u8,
    /// The account's email, so an administrator sees whose it is.
    email: []const u8,
    created_at: i64,
    last_used_at: i64,
    /// The device making this call.
    current: bool,
};

pub const List = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.list";
    pub const description = "The devices acting for your account, or for everyone's";
    pub const details =
        \\Any signed-in account sees its own; a device sees its account's. `all` lists every
        \\account's, for administrators. Revoked devices are not listed. Newest first.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct { all: bool = false };
    pub const Out = struct { devices: []const Item };
    pub const example: In = .{};
    pub const example_out: Out = .{ .devices = &.{.{
        .id = example_device_id,
        .name = "An agent on Ada's laptop",
        .scope = "drafts",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .email = "ada@example.com",
        .created_at = 1792232000000,
        .last_used_at = 1792235600000,
        .current = false,
    }} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .all = "Every account's devices (administrators only)",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .devices = "Up to 256, newest first" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const user_id = ctx.caller.user_id() orelse return error.Denied;

        if (in.all and !ctx.caller.holds(role.admin)) {
            return error.Denied;
        }

        const owner: ?[]const u8 = if (in.all) null else user_id;
        const found = try store.devices.list(ctx.db, ctx.arena, owner);
        const items = ctx.arena.alloc(Item, found.len) catch return error.OutOfMemory;
        const current: []const u8 = if (ctx.caller == .token) ctx.caller.token.id else "";

        for (found, items) |device, *item| {
            const account = try store.users.find_by_id(ctx.db, ctx.arena, device.user_id);

            item.* = .{
                .id = device.id,
                .name = device.name,
                .scope = device.scope,
                .user_id = device.user_id,
                .email = if (account) |credentials| credentials.user.email else "",
                .created_at = device.created_at,
                .last_used_at = device.last_used_at,
                .current = std.mem.eql(u8, device.id, current),
            };
        }

        std.debug.assert(items.len <= store.devices.listed_max);

        return .{ .devices = items };
    }
};

pub const Revoke = struct {
    /// Its example runs as a signed-in account (`--as`), though anyone may call it.
    pub const example_signed_in = true;
    pub const name = "device.revoke";
    pub const description = "Stop a device acting for its account";
    pub const details =
        \\A signed-in account revokes its own devices, an administrator anyone's; a device
        \\may revoke only itself (`publr logout`). It stops working at once.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { revoked: bool };
    pub const example: In = .{ .id = example_device_id };
    pub const example_out: Out = .{ .revoked = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The device, as `device list` shows it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .revoked = "Always true" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const user_id = ctx.caller.user_id() orelse return error.Denied;

        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len == 0 or in.id.len > store.devices.id_len) {
            return error.NotFound;
        }

        const device = try store.devices.find(ctx.db, ctx.arena, in.id) orelse {
            return error.NotFound;
        };
        const own = std.mem.eql(u8, device.user_id, user_id);
        const allowed = switch (ctx.caller) {
            .token => |token| std.mem.eql(u8, token.id, device.id),
            else => own or ctx.caller.holds(role.admin),
        };

        if (!allowed) {
            return error.NotFound;
        }

        if (!try store.devices.revoke(ctx.db, device.id, ctx.now_ms)) {
            return error.NotFound;
        }

        ctx.notice("auth.device_revoked", device.id);

        return .{ .revoked = true };
    }
};
