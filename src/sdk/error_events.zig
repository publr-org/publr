//! `publr.errors.Failed`: everything that lands in the Error log as an error (a failed or
//! crashed call, an `.err` log line, a failed job or `on` run), for error trackers and
//! alerts. Kept outside the write that rolled back, like the Error log entry, and heard by
//! `on` hooks only. Refusals a caller is told about raise nothing.
const std = @import("std");
const event = @import("plugin/hook_define.zig").event;
const auth_events = @import("auth_events.zig");

pub const Failed = event(.{
    .name = "errors.failed",
    .payload = struct {
        /// What failed: an operation (`orders.place`), a job's run (`job:<plugin>.<name>`), a
        /// hook's run on an event (`event:<name>`), a sign-in provider's step
        /// (`sign_in:<provider>`)
        what: []const u8,
        /// The plugin it belongs to; empty for core's
        plugin: []const u8 = "",
        /// The error's name (`Unavailable`, `OutOfMemory`); `Logged` for an error line
        error_name: []const u8,
        /// What the error or the line says; empty when nothing does
        message: []const u8 = "",
        /// Who called: `user`, `token`, `machine`, `plugin`, `anonymous`, `system`, or `job`
        /// for queued work
        caller: []const u8,
        /// When, in milliseconds since 1970
        at: i64,
        /// The Error log entry's id
        entry: i64,
    },
});

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
