//! The person's side of devices: the request they approve or deny, and the devices that
//! act for them, which they list and revoke. Every operation here is open (any account,
//! whatever its roles, manages its own devices) and checks who calls itself.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/device.zig");
const role = @import("../../model/role.zig");
const ai_model = @import("../../model/ai.zig");
const oauth = @import("oauth.zig");
const public = @import("../../publr/operations/device/people.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Request, Approve, Deny, List, Update, Revoke };

pub const example_code = public.example_code;
pub const example_device_id = public.example_device_id;

/// The account of a person signed in: never a device (a device never lets in another), never
/// anyone else.
fn person_of(ctx: *const Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    return switch (ctx.caller) {
        .user => |user| user.id,
        .anonymous, .token, .system, .plugin => error.Denied,
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
    pub const shape = public.Request;
    pub const example_signed_in = shape.example_signed_in;
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
        _ = try person_of(ctx);

        const request = try waiting(ctx, in.code);

        return .{
            .name = request.name,
            .scope = request.scope,
            .expires_at = request.expires_at,
            .returns_to = request.redirect_uri,
        };
    }
};

pub const Approve = struct {
    pub const shape = public.Approve;
    pub const example_signed_in = shape.example_signed_in;
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

        return .{
            .approved = true,
            .sent_back = try oauth.sent_back(ctx, request, true),
        };
    }
};

pub const Deny = struct {
    pub const shape = public.Deny;
    pub const example_signed_in = shape.example_signed_in;
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

        return .{
            .denied = true,
            .sent_back = try oauth.sent_back(ctx, request, false),
        };
    }
};

pub const Item = public.Item;

pub const List = struct {
    pub const shape = public.List;
    pub const example_signed_in = shape.example_signed_in;
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
        const user_id = ctx.caller.user_id() orelse return error.Denied;

        if (in.all and !ctx.caller.holds(role.admin)) {
            return error.Denied;
        }

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const owner: ?[]const u8 = if (in.all) null else user_id;
        const found = try store.devices.page(ctx.db, ctx.arena, owner, in.offset, in.limit);
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

        return .{
            .devices = items,
            .total = try store.devices.count(ctx.db, owner),
        };
    }
};

pub const Revoke = struct {
    pub const shape = public.Revoke;
    pub const example_signed_in = shape.example_signed_in;
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

        return .{
            .revoked = true,
        };
    }
};

pub const Update = struct {
    pub const shape = public.Update;
    pub const example_signed_in = shape.example_signed_in;
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
        const user_id = try person_of(ctx);

        std.debug.assert(ctx.db.transaction_depth >= 1);

        const given = model.Scope.parse(in.scope) orelse return error.Invalid;

        if (in.id.len == 0 or in.id.len > store.devices.id_len) {
            return error.NotFound;
        }

        const device = try store.devices.find(ctx.db, ctx.arena, in.id) orelse {
            return error.NotFound;
        };
        const own = std.mem.eql(u8, device.user_id, user_id);

        if (!own and !ctx.caller.holds(role.admin)) {
            return error.NotFound;
        }

        if (!try store.devices.set_scope(ctx.db, device.id, @tagName(given))) {
            return error.NotFound;
        }

        return .{
            .scope = @tagName(given),
        };
    }
};

/// The tools connected to this site, on any account, the last used first: `limit` of them,
/// never the device a conversation here lends itself for a turn. The Overview shows them to
/// every account that reaches it.
pub fn recently_used(ctx: *Ctx, limit: u32) Error![]const store.devices.Device {
    std.debug.assert(limit > 0);

    return store.devices.recently_used(ctx.db, ctx.arena, ai_model.device_name, limit);
}
