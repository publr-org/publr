//! Which of core's sign-in events (`publr/auth_events.zig`) a `before` hook may not hear,
//! and which are refusals heard by `on` hooks only.
const std = @import("std");
const public = @import("../publr/auth_events.zig");

pub const SignedIn = public.SignedIn;
pub const SignedUp = public.SignedUp;
pub const SignedOut = public.SignedOut;
pub const SignInThrottled = public.SignInThrottled;
pub const SignInFailed = public.SignInFailed;
pub const SignInLocked = public.SignInLocked;
pub const SignOnReplayed = public.SignOnReplayed;
pub const SignOnFailed = public.SignOnFailed;
pub const IdentityRefused = public.IdentityRefused;

/// Core's events that a `before` hook may not hear: they already happened. An installed
/// plugin asking for one is refused at install, as a compiled-in one fails to build.
pub const unrefusable = [_][]const u8{SignedOut.full_name};

/// Core's refusals people may want to hear of: they happen in a call that is refused, so
/// they are kept outside its write and heard by `on` hooks only.
pub const refused = [_][]const u8{
    SignInThrottled.full_name,
    SignInFailed.full_name,
    SignInLocked.full_name,
    SignOnReplayed.full_name,
    SignOnFailed.full_name,
    IdentityRefused.full_name,
};

/// Whether `name` is one of core's events a `before` hook may not hear.
pub fn before_refused(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(unrefusable.len > 0);

    return listed(&unrefusable, name);
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(names.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

test "a sign-in or sign-up may be refused; a sign-out may not" {
    try std.testing.expect(!SignedOut.refusable);
    try std.testing.expect(before_refused("auth.signed_out"));
    try std.testing.expect(!before_refused("auth.signed_in"));
    try std.testing.expect(SignedIn.refusable and SignedUp.refusable);
    try std.testing.expectEqualStrings("auth.sign_on_failed", SignOnFailed.full_name);
}
