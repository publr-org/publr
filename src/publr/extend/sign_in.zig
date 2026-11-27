//! A sign-in provider, as a built-in plugin declares it with `host.sign_in_provider`: a
//! "Continue with X" button on the login pages. Core makes the state and the PKCE pair,
//! keeps the callback, runs the provider's `exchange` as a fixed step of it, and decides
//! whose account it is; the plugin only knows how to talk to its provider. A provider of
//! the other kind reads who someone is from a header a proxy in front puts on every request
//! (`from_request`).
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const ExchangeCtx = @import("../exchange_ctx.zig").ExchangeCtx;
const Error = @import("../operation.zig").Error;

pub const providers_max: u32 = 16;
pub const label_len_max: u32 = 32;
pub const icon_len_max: u32 = 4096;
/// How long the exchange may take, all its requests together: the visitor waits on it.
pub const exchange_ms_max: u32 = 10_000;

/// What the core gives `authorize_url`: where the provider must send the browser back, and
/// the two values it must carry.
pub const Authorize = struct {
    callback_url: []const u8,
    state: []const u8,
    /// `base64url(sha256(verifier))`; the plugin passes it as `code_challenge`, `S256`.
    code_challenge: []const u8,
};

/// What the core gives `exchange`: the provider's `code` and the verifier the challenge was
/// made from, to swap for who the person is.
pub const Callback = struct {
    callback_url: []const u8,
    code: []const u8,
    code_verifier: []const u8,
};

/// Who the person is, as the provider says: core maps it to an account.
pub const Claims = struct {
    /// The provider's `name`; anything else is refused.
    provider: []const u8,
    /// The person's stable id at the provider.
    subject: []const u8,
    email: ?[]const u8 = null,
    /// Whether the provider verified `email`.
    verified: bool = false,
    name: ?[]const u8 = null,
    /// A picture's address, when the provider has one.
    avatar: ?[]const u8 = null,
};

pub const SignInProvider = struct {
    /// In URLs and identity rows: `github`, `google`; `[a-z][a-z0-9_]*`, at most 32.
    name: []const u8,
    /// "Continue with <label>".
    label: []const u8,
    /// The provider's mark: the `d` of one path on a 24 by 24 canvas, filled with the
    /// button's text colour. Brand marks are the plugin's to ship, never the icon set's.
    icon: []const u8,
    /// Whether the provider can be offered now: its client id is in the environment. Core
    /// also waits for every secret the plugin declares to be set.
    available: *const fn () bool,
    /// Where to send the browser to sign in with the provider. Set together with
    /// `exchange`, or neither when the provider reads `from_request`.
    authorize_url: ?*const fn (arena: std.mem.Allocator, request: Authorize) Error![]const u8 =
        null,
    /// Swaps the callback's code for who the person is: the one step of a sign-in that waits
    /// on another server. Its ctx sends only to the plugin's own `http.fetch` domains, its
    /// secrets filled as they leave, within `exchange_ms_max`. `BadCredentials` when the
    /// provider refused the code; any error fails the sign-in ("Try again").
    exchange: ?*const fn (ctx: *ExchangeCtx, callback: Callback) Error!Claims = null,
    /// Who the person is, read from a header a proxy in front of the site puts on every
    /// request (an identity-aware proxy), in place of a redirect and an exchange.
    from_request: ?FromRequest = null,
    /// The plugin that declares it: set by core.
    plugin: []const u8 = "",
};

/// A provider that a proxy in front of the site answers for: every request carries who the
/// person is, signed. While one is available the admin signs in through it alone and checks
/// it on every request.
pub const FromRequest = struct {
    /// The request header it reads, lower case: `x-goog-iap-jwt-assertion`.
    header: []const u8,
    /// The person the header's value names, when it checks out; null when it does not. A
    /// deciding step: no outside calls, only the plugin's own stored data.
    read: *const fn (ctx: *Ctx, value: []const u8) Error!?Claims,
    /// What someone the proxy let through gets when no account holds them: the roles for a
    /// new account (empty: an account with none, waiting for an administrator), or null for
    /// none, as today. What an administrator chose for new members; a deciding step like
    /// `read`. Left out: accounts are only ever made by an administrator.
    new_member: ?*const fn (ctx: *Ctx, claims: Claims) Error!?[]const []const u8 = null,
};

pub const header_len_max: u32 = 64;
