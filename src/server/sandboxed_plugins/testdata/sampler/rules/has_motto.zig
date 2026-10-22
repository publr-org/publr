//! Places a field group on the accounts that have, or haven't, a sampler motto.
const publr = @import("publr");
const std = @import("std");

const Profile = @import("../records/profile.zig");

/// What the admin's dropdown offers.
fn values(ctx: *publr.Ctx) publr.Error![]const []const u8 {
    std.debug.assert(ctx.now().ms >= 0);

    return &.{ "yes", "no" };
}

/// "yes" for an account whose Sampler profile has a motto.
fn matches(
    ctx: *publr.Ctx,
    target: publr.location.Target,
    rule: publr.location.Rule,
) publr.Error!bool {
    std.debug.assert(target.id.len > 0);

    if (target.destination != .user) {
        return false;
    }

    const profile = try publr.fields.get(ctx, Profile.Fields, target.id);
    const set = profile.motto != null and profile.motto.?.len > 0;

    return rule.compare(if (set) "yes" else "no");
}

pub const location_rule = .{
    .name = "has_motto",
    .label = "Has a sampler motto",
    .values = values,
    .matches = matches,
};
