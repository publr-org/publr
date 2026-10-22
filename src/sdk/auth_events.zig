//! People signing in, up and out: `publr.auth.SignedIn`, `SignedUp`, `SignedOut`, hooked by
//! type. `before` runs before the session exists and may only refuse, `after` inside the
//! sign-in's write (a failed hook fails the sign-in: nobody is half signed in), `on` from the
//! queue once it committed. A hook never grants, never sees a credential, and never locks out
//! an administrator: their refusal is logged, the sign-in goes on. Signing out always goes
//! through.

const std = @import("std");
const event = @import("plugin/hook_define.zig").event;

const Signed = struct {
    /// The account that signed in
    user: []const u8,
    /// The visitor id the person had before signing in; empty when there was none
    visitor: []const u8 = "",
    /// How: `password`, `link`, or the sign-in provider's name (`github`, `google`)
    method: []const u8,
};

/// Someone signed in.
pub const SignedIn = event(.{
    .name = "auth.signed_in",
    .payload = Signed,
});
/// A person created their own account (open sign-up), emitted before their first `SignedIn`.
pub const SignedUp = event(.{
    .name = "auth.signed_up",
    .payload = Signed,
});
/// Someone signed out.
pub const SignedOut = event(.{
    .name = "auth.signed_out",
    .payload = struct {
        /// The account that signed out
        user: []const u8,
        /// The visitor id the person had while signed in; empty when there was none
        visitor: []const u8 = "",
    },
});

/// Too many wrong passwords for an email lately: this try was not checked.
pub const SignInThrottled = event(.{
    .name = "auth.sign_in_throttled",
    .payload = struct {
        /// The email tried, lower-cased
        email: []const u8,
    },
});
/// A sign-in with a password that did not match, or an email no account has.
pub const SignInFailed = event(.{
    .name = "auth.sign_in_failed",
    .payload = struct {
        /// The email tried, lower-cased
        email: []const u8,
    },
});
/// That failure was one too many: sign-ins for the email wait a while.
pub const SignInLocked = event(.{
    .name = "auth.sign_in_locked",
    .payload = struct {
        /// The email whose sign-ins wait
        email: []const u8,
    },
});
/// A sign-on link from the trusted issuer used a second time.
pub const SignOnReplayed = event(.{
    .name = "auth.sign_on_replayed",
    .payload = struct {
        /// The email the link was for
        email: []const u8,
    },
});
/// A sign-on link refused: not signed by the trusted issuer, not for this site, or too old.
pub const SignOnFailed = event(.{
    .name = "auth.sign_on_failed",
    .payload = struct {
        /// The email the link was for; empty when its signature did not check
        email: []const u8,
        /// `signature`: not signed by the trusted issuer; `expired`: not for this site, or
        /// out of time
        why: []const u8,
    },
});
/// A sign-in provider vouched for someone this site does not let in.
pub const IdentityRefused = event(.{
    .name = "auth.identity_refused",
    .payload = struct {
        /// The sign-in provider (`github`, `google`)
        provider: []const u8,
        /// `unverified`: the provider did not verify the email; `closed`: no account has it
        /// and the site does not let people sign up
        why: []const u8,
    },
});

/// The sign-in events a `before` or `after` hook may refuse.
pub const refusable_events = [_][]const u8{ SignedIn.full_name, SignedUp.full_name };

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

/// Whether a `before` or `after` hook on the event may refuse it.
pub fn refusable(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(refusable_events.len > 0);

    return listed(&refusable_events, name);
}

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

/// What no sign-in payload may carry, in any field's name: a credential, or a way to one.
const credential_words = [_][]const u8{
    "password", "token", "code", "secret", "cookie", "session", "link", "key",
};

/// The field of `Payload` named like a credential; null when there is none.
pub fn credential_field(comptime Payload_: type) ?[]const u8 {
    comptime {
        std.debug.assert(@typeInfo(Payload_) == .@"struct");
        std.debug.assert(credential_words.len > 0);

        for (@typeInfo(Payload_).@"struct".fields) |field| {
            for (credential_words) |word| {
                if (std.mem.indexOf(u8, field.name, word) != null) {
                    return field.name;
                }
            }
        }

        return null;
    }
}

test "no sign-in payload carries a credential; a field named like one is found" {
    const Leaky = struct {
        user: []const u8,
        session_token: []const u8,
    };

    try std.testing.expectEqualStrings("session_token", comptime credential_field(Leaky).?);
    try std.testing.expectEqual(@as(?[]const u8, null), comptime credential_field(Signed));
    try std.testing.expect(!refusable(SignedOut.full_name));
    try std.testing.expect(before_refused("auth.signed_out"));
    try std.testing.expect(!before_refused("auth.signed_in"));
    try std.testing.expect(refusable(SignedIn.full_name) and refusable(SignedUp.full_name));
    try std.testing.expectEqualStrings("auth.sign_on_failed", SignOnFailed.full_name);
}
