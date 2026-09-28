//! Delivery gates: plugins deciding who may see the public site. Before a page, a not-found
//! page or an island is delivered, every gate the plugins declare (`delivery_gates`) is
//! asked about it, in plugin order. A gate may stay silent, keep what it lets through out
//! of shared caches, or answer in the page's place: a paywall, a members-only area, a site
//! still being built. The theme's assets are never gated: they show nothing of the content.

const std = @import("std");
const context = @import("context.zig");
const caller_module = @import("caller.zig");
const operation = @import("operation.zig");

pub const gates_max: u32 = 16;
pub const body_bytes_max: u32 = 64 << 10;

pub const Kind = enum { page, island };

/// What a gate is asked about.
pub const Delivery = struct {
    /// The system's context: what the gate needs to decide (its own settings, the
    /// visitor's account) it reads through operations, as the system.
    ctx: *context.Ctx,
    /// Who asks: anonymous when nobody is signed in.
    visitor: caller_module.Caller,
    /// The path asked for, `/` and on; an island's is its `/_islands/…` path.
    path: []const u8,
    kind: Kind,
};

/// What the visitor gets instead: a status from 400 to 599 and a page.
pub const Refusal = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "text/html; charset=utf-8",
};

pub const Verdict = union(enum) {
    /// Nothing to say: deliver as usual.
    open,
    /// Deliver, but never from or into a shared cache: the answer is for this visitor.
    private,
    /// Answer this instead.
    refuse: Refusal,
};

pub const Gate = *const fn (delivery: *const Delivery) operation.Error!Verdict;

/// Every gate's say: the first refusal wins, any `private` keeps the answer private. A
/// gate that fails refuses nothing on its own; its error ends the request.
pub fn decide(gates: []const Gate, delivery: *const Delivery) operation.Error!Verdict {
    std.debug.assert(gates.len <= gates_max);
    std.debug.assert(delivery.path.len > 0);

    var private = false;

    for (gates) |gate| {
        switch (try gate(delivery)) {
            .open => {},
            .private => private = true,
            .refuse => |refusal| {
                if (!valid_refusal(refusal)) {
                    return error.Invalid;
                }

                return .{ .refuse = refusal };
            },
        }
    }

    return if (private) .private else .open;
}

pub fn valid_refusal(refusal: Refusal) bool {
    std.debug.assert(body_bytes_max > 0);

    const status_ok = refusal.status >= 400 and refusal.status <= 599;

    return status_ok and refusal.body.len <= body_bytes_max and refusal.content_type.len > 0;
}

const testing = struct {
    fn silent(_: *const Delivery) operation.Error!Verdict {
        return .open;
    }

    fn members(delivery: *const Delivery) operation.Error!Verdict {
        std.debug.assert(delivery.path.len > 0);

        if (delivery.visitor.user_id() != null) {
            return .private;
        }

        return .{ .refuse = .{ .status = 403, .body = "members only" } };
    }

    fn broken(_: *const Delivery) operation.Error!Verdict {
        return .{ .refuse = .{ .status = 200, .body = "not a refusal" } };
    }
};

test "the first refusal wins, a private say keeps it private, silence changes nothing" {
    var ctx: context.Ctx = undefined;
    const anonymous: Delivery = .{ .ctx = &ctx, .visitor = .anonymous, .path = "/", .kind = .page };
    var member = anonymous;
    member.visitor = .{ .user = .{ .id = "ada", .role = .editor } };

    try std.testing.expectEqual(Verdict.open, try decide(&.{}, &anonymous));
    try std.testing.expectEqual(Verdict.open, try decide(&.{testing.silent}, &anonymous));

    const refused = try decide(&.{ testing.silent, testing.members }, &anonymous);
    try std.testing.expectEqual(@as(u16, 403), refused.refuse.status);
    try std.testing.expectEqual(Verdict.private, try decide(&.{testing.members}, &member));

    // A refusal must be one: 4xx or 5xx.
    try std.testing.expectError(error.Invalid, decide(&.{testing.broken}, &anonymous));
}
