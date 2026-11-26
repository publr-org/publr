//! People signing in, up and out: `publr.auth.SignedIn`, `SignedUp`, `SignedOut`, hooked by
//! type. `before` runs before the session exists and may only refuse, `after` inside the
//! sign-in's write (a failed hook fails the sign-in: nobody is half signed in), `on` from the
//! queue once it committed. A hook never grants, never sees a credential, and never locks out
//! an administrator: their refusal is logged, the sign-in goes on. Signing out always goes
//! through.

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
    .refusable = true,
});
/// A person created their own account (open sign-up), emitted before their first `SignedIn`.
pub const SignedUp = event(.{
    .name = "auth.signed_up",
    .payload = Signed,
    .refusable = true,
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
