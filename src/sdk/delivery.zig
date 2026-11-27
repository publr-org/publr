//! Delivery gates as core asks them (`publr/extend/delivery.zig` is the contract): every
//! gate in plugin order, the first refusal winning.

const std = @import("std");
const context = @import("context.zig");
const caller_module = @import("caller.zig");
const operation = @import("operation.zig");

const public = @import("../publr/extend/delivery.zig");

pub const gates_max = public.gates_max;
pub const body_bytes_max = public.body_bytes_max;
pub const Delivery = public.Delivery;
pub const Refusal = public.Refusal;
pub const Verdict = public.Verdict;
pub const Gate = public.Gate;

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

                return .{
                    .refuse = refusal,
                };
            },
        }
    }

    return if (private) .private else .open;
}

pub fn valid_refusal(refusal: Refusal) bool {
    std.debug.assert(body_bytes_max > 0);

    const status_ok = refusal.status >= 400 and refusal.status <= 599;

    return status_ok and refusal.body.len <= body_bytes_max;
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

        return .{
            .refuse = .{
                .status = 403,
                .body = "members only",
            },
        };
    }

    fn broken(_: *const Delivery) operation.Error!Verdict {
        return .{
            .refuse = .{
                .status = 200,
                .body = "not a refusal",
            },
        };
    }
};

test "the first refusal wins, a private say keeps it private, silence changes nothing" {
    var host: @import("plugin/context.zig").HostApi = undefined;
    const anonymous: Delivery = .{
        .ctx = host.ctx(),
        .visitor = .{
            .from = .app,
        },
        .path = "/",
    };
    var member = anonymous;
    member.visitor = .{
        .from = .app,
        .person = true,
        .account_id = "ada",
        .held_roles = &.{"editor"},
    };

    try std.testing.expectEqual(Verdict.open, try decide(&.{}, &anonymous));
    try std.testing.expectEqual(Verdict.open, try decide(&.{testing.silent}, &anonymous));

    const refused = try decide(&.{ testing.silent, testing.members }, &anonymous);
    try std.testing.expectEqual(@as(u16, 403), refused.refuse.status);
    try std.testing.expectEqual(Verdict.private, try decide(&.{testing.members}, &member));

    // A refusal must be one: 4xx or 5xx.
    try std.testing.expectError(error.Invalid, decide(&.{testing.broken}, &anonymous));
}
