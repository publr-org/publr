const std = @import("std");
const public = @import("../publr/model/status.zig");

pub const id_len_max = public.id_len_max;
pub const statuses_max = public.statuses_max;
pub const transitions_max = public.transitions_max;

pub const Color = public.Color;
pub const Status = public.Status;

/// Each status standing in for another (`alias`) given that one's meaning, when the site
/// knows it; one whose alias is unknown keeps its own.
pub fn resolve_aliases(statuses: []Status) void {
    std.debug.assert(statuses.len <= statuses_max * 64);

    for (statuses) |*standing_in| {
        if (standing_in.alias.len == 0) {
            continue;
        }

        for (statuses) |target| {
            const found = target.alias.len == 0 and std.mem.eql(u8, target.id, standing_in.alias);

            if (found) {
                standing_in.label = target.label;
                standing_in.color = target.color;
                standing_in.live = target.live;
                break;
            }
        }
    }
}

test "a status standing in for another takes its meaning when the site knows it" {
    var statuses = [_]Status{
        .{
            .id = "orders.paid",
            .label = "Paid",
            .color = .success,
            .live = true,
        },
        .{
            .id = "shop.paid",
            .label = "Settled",
            .alias = "orders.paid",
        },
        .{
            .id = "shop.held",
            .label = "Held",
            .alias = "orders.held",
        },
    };

    resolve_aliases(&statuses);

    try std.testing.expectEqualStrings("Paid", statuses[1].label);
    try std.testing.expect(statuses[1].live);
    try std.testing.expectEqualStrings("Held", statuses[2].label);
    try std.testing.expect(!statuses[2].live);
}

pub const Transition = public.Transition;
pub const core_statuses = public.core_statuses;
pub const core_transitions = public.core_transitions;

pub fn Registry(comptime statuses: []const Status, comptime transitions: []const Transition) type {
    comptime validate(statuses, transitions);

    return struct {
        pub const all = statuses;
        pub const all_transitions = transitions;

        pub fn find(id: []const u8) ?Status {
            comptime std.debug.assert(statuses.len > 0);

            for (statuses) |status| {
                if (std.mem.eql(u8, status.id, id)) {
                    return status;
                }
            }

            return null;
        }

        pub fn initial() Status {
            comptime std.debug.assert(statuses.len > 0);

            inline for (statuses) |status| {
                if (status.initial) {
                    return status;
                }
            }

            unreachable;
        }

        pub fn is_live(id: []const u8) bool {
            const status = find(id) orelse return false;

            std.debug.assert(status.id.len > 0);
            std.debug.assert(std.mem.eql(u8, status.id, id));

            return status.live;
        }

        pub fn allows(from: []const u8, to: []const u8) bool {
            std.debug.assert(from.len > 0);
            std.debug.assert(to.len > 0);

            for (transitions) |transition| {
                const from_ok = std.mem.eql(u8, transition.from, "*") or
                    std.mem.eql(u8, transition.from, from);

                if (from_ok and std.mem.eql(u8, transition.to, to)) {
                    return true;
                }
            }

            return false;
        }
    };
}

fn validate(comptime statuses: []const Status, comptime transitions: []const Transition) void {
    comptime {
        if (statuses.len == 0 or statuses.len > statuses_max) {
            @compileError("status registry needs 1 to 64 statuses");
        }

        if (transitions.len > transitions_max) {
            @compileError("too many transitions");
        }

        var initials: u32 = 0;

        for (statuses, 0..) |status, index| {
            if (status.id.len == 0 or status.id.len > id_len_max) {
                @compileError("status id length: " ++ status.id);
            }

            if (status.initial) {
                initials += 1;
            }

            for (statuses[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.id, status.id)) {
                    @compileError("duplicate status: " ++ status.id);
                }
            }
        }

        if (initials != 1) {
            @compileError("exactly one status must be initial");
        }

        for (transitions) |transition| {
            const from_known = std.mem.eql(u8, transition.from, "*") or known(
                statuses,
                transition.from,
            );

            if (!from_known or !known(statuses, transition.to)) {
                @compileError("transition to/from unknown status: " ++ transition.from ++ " -> " ++
                    transition.to);
            }
        }
    }
}

fn known(comptime statuses: []const Status, comptime id: []const u8) bool {
    comptime {
        std.debug.assert(id.len > 0);
        std.debug.assert(statuses.len > 0);

        for (statuses) |status| {
            if (std.mem.eql(u8, status.id, id)) {
                return true;
            }
        }

        return false;
    }
}

pub const Core = Registry(&core_statuses, &core_transitions);

test "core registry: draft is initial, published is live, archived is not listed" {
    try std.testing.expectEqualStrings("draft", Core.initial().id);
    try std.testing.expect(Core.is_live("published"));
    try std.testing.expect(!Core.is_live("draft"));
    try std.testing.expect(!Core.is_live("nope"));
    try std.testing.expect(!Core.find("archived").?.listed);
    try std.testing.expect(Core.allows("draft", "published"));
    try std.testing.expect(Core.allows("published", "archived"));
    try std.testing.expect(!Core.allows("draft", "nope"));
    try std.testing.expect(!Core.allows("archived", "published"));
    try std.testing.expect(Core.allows("published", "trashed"));
    try std.testing.expect(Core.allows("trashed", "draft"));
    try std.testing.expect(!Core.allows("trashed", "published"));
}

test "plugins extend the registry" {
    const extended = core_statuses ++ [_]Status{.{
        .id = "in_review",
        .label = "In review",
        .color = .info,
    }};
    const more = core_transitions ++ [_]Transition{
        .{
            .from = "draft",
            .to = "in_review",
            .label = "Request review",
        },
        .{
            .from = "in_review",
            .to = "published",
            .label = "Approve",
        },
    };
    const Extended = Registry(&extended, &more);

    try std.testing.expect(Extended.allows("in_review", "published"));
    try std.testing.expectEqual(@as(usize, 5), Extended.all.len);
}
