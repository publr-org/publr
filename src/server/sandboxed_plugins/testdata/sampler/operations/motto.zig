//! Give an account the sampler's motto.
//!
//! Writes the Motto of the account's Sampler profile, the sampler's own field group on
//! users, and answers it as read back. Administrators may call it. Compiled in only: an
//! installed plugin can't reach its field group yet.
//!
//! Example:
//!   in: { "user": "admin@example.com", "motto": "Keep notes" }
//!   out: { "motto": "Keep notes" }
const publr = @import("publr");
const std = @import("std");

const Profile = @import("../records/profile.zig");

pub const In = struct {
    /// The account's id or email
    user: []const u8,
    /// The motto
    motto: []const u8,
};

pub const Out = struct {
    /// The motto as read back
    motto: ?[]const u8,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.user.len > 0);
    std.debug.assert(in.motto.len <= 64 << 10);

    try publr.fields.save(ctx, Profile.Fields, in.user, .{
        .motto = in.motto,
    });

    const kept = try publr.fields.get(ctx, Profile.Fields, in.user);

    return .{
        .motto = kept.motto,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "motto",
    .kind = .write,
    .run = run,
});
