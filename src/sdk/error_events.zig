//! Which errors raise `publr.errors.Failed` (`publr/error_events.zig`), and which of core's
//! events only `on` hooks may hear.
const std = @import("std");
const auth_events = @import("auth_events.zig");

pub const Failed = @import("../publr/error_events.zig").Failed;

/// The errors a caller is told about as an answer, not a fault: no `Failed` for them.
const refusals = [_][]const u8{
    "Denied",
    "Invalid",
    "NotFound",
    "Conflict",
    "Throttled",
    "Failed",
    "BadCredentials",
};

/// Whether an Error log entry with this error raises `Failed`: a fault, not a refusal, and
/// not a hook on `Failed` itself failing (it would raise again forever).
pub fn raises(error_name: []const u8, what: []const u8) bool {
    std.debug.assert(error_name.len > 0);
    std.debug.assert(what.len > 0);

    for (refusals) |name| {
        if (std.mem.eql(u8, name, error_name)) {
            return false;
        }
    }

    return !std.mem.eql(u8, what, "event:" ++ Failed.full_name);
}

/// Core's events kept outside the write that raised them and heard by `on` hooks only: a
/// `before` or `after` on one fails the build and is refused at install.
pub fn on_only(name: []const u8) bool {
    std.debug.assert(name.len <= 128);
    std.debug.assert(auth_events.refused.len > 0);

    // A plugin's own event has no full name until it is bound: never one of core's.
    if (name.len == 0) {
        return false;
    }

    if (std.mem.eql(u8, name, Failed.full_name)) {
        return true;
    }

    for (auth_events.refused) |refused| {
        if (std.mem.eql(u8, refused, name)) {
            return true;
        }
    }

    return false;
}

test "faults raise Failed, refusals and a failing tracker do not" {
    try std.testing.expect(raises("Unavailable", "orders.place"));
    try std.testing.expect(raises("Logged", "job:printer.print"));
    try std.testing.expect(!raises("Invalid", "orders.place"));
    try std.testing.expect(!raises("Failed", "orders.place"));
    try std.testing.expect(!raises("Logged", "event:errors.failed"));
    try std.testing.expect(on_only("errors.failed") and on_only("auth.sign_on_failed"));
    try std.testing.expect(!on_only("auth.signed_in"));
}
