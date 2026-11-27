//! The calls `publr.Ctx` makes the same way in both builds, written once on top of `call`.
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const words = @import("../plugin/words.zig");
const files = @import("../files.zig");
const link = @import("../operations/link.zig");
// Until `publr.Error` is the public set: an operation's errors, database ones among them.
const Error = @import("../../sdk/operation.zig").Error;

/// Inside a computed field's function: the value it answers holds until `time`, and is
/// worked out again then whatever else happens (a sale ends). The earliest one counts.
pub fn holds_until(ctx: *Ctx, time: words.Time) Error!void {
    std.debug.assert(time.ms > 0);

    _ = try ctx.call(@import("../operations/internal.zig").HoldsUntil, .{
        .until_ms = time.ms,
    });
}

/// A link a person opens without signing in, for one purpose (`intent`, the plugin's
/// own word) and one subject, until `expires` (null: until revoked): its `token`, and
/// its `path` (`/_links/<token>`, which runs the plugin's operation named `intent`).
pub fn sign(
    ctx: *Ctx,
    intent: []const u8,
    subject: []const u8,
    expires: ?words.Time,
) Error!link.Sign.Out {
    std.debug.assert(intent.len > 0);

    return ctx.call(link.Sign, .{
        .intent = intent,
        .subject = subject,
        .expires_at = if (expires) |time| time.ms else 0,
    });
}

/// The subject a link's token was signed for, when it is good for `intent`; not found
/// otherwise (another purpose, past its time, revoked).
pub fn verify(ctx: *Ctx, intent: []const u8, token: []const u8) Error![]const u8 {
    std.debug.assert(intent.len > 0);

    const read = try ctx.call(link.Verify, .{
        .intent = intent,
        .token = token,
    });

    return read.subject;
}

/// A file the plugin makes, written in pieces (`write`) and kept with `done` as a file of
/// one of its own media types (`type_handle`, `kind` `media`): see `publr.Ctx.Making`.
pub fn make_file(ctx: *Ctx, type_handle: []const u8, filename: []const u8) files.Making {
    std.debug.assert(type_handle.len > 0);

    return files.Making.begin(ctx, type_handle, filename);
}

/// Fills `buffer` (at most 64 bytes) from the host's cryptographic source: codes a person
/// must not guess. Never a hash of an id, which anyone who knows the id can work out.
pub fn random(ctx: *Ctx, buffer: []u8) Error!void {
    std.debug.assert(buffer.len > 0);

    const random_operation = @import("../../operations/random.zig");
    const answered = try ctx.call(random_operation.Random, .{
        .bytes = @intCast(buffer.len),
    });

    return random_operation.fill(buffer, answered.hex);
}

/// The site's time zone, to read moments on its clock: `ctx.now().local_date(zone)`.
pub fn time_zone(ctx: *Ctx) Error!words.TimeZone {
    const answered = try ctx.call(@import("../../operations/job.zig").TimeZone, .{});

    std.debug.assert(answered.rule.len > 0);

    return .{
        .name = answered.name,
        .rule = answered.rule,
    };
}
