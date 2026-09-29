//! The sign-in provider contract: what a plugin declares to put a "Continue with X" button
//! on the login pages. The core makes the state and the PKCE pair, keeps the callback, and
//! decides whose account it is; the plugin only knows how to talk to its provider.

const std = @import("std");
const operation = @import("operation.zig");
const model = @import("../model/identity.zig");

pub const Identity = model.Identity;
pub const Error = operation.Error;
pub const providers_max: u32 = 16;
pub const label_len_max: u32 = 32;
pub const icon_len_max: u32 = 4096;

/// What the core gives `authorize_url`: where the provider must send the browser back, and
/// the two values it must carry.
pub const Authorize = struct {
    callback_url: []const u8,
    state: []const u8,
    /// `base64url(sha256(verifier))`; the plugin passes it as `code_challenge`, `S256`.
    code_challenge: []const u8,
};

/// What the core gives `identity`: the provider's `code` and the verifier the challenge was
/// made from, to exchange for the person's identity.
pub const Callback = struct {
    callback_url: []const u8,
    code: []const u8,
    code_verifier: []const u8,
};

pub const SignInProvider = struct {
    /// In URLs and identity rows: `github`, `google`; `[a-z][a-z0-9_]*`, at most 32.
    name: []const u8,
    /// "Continue with <label>".
    label: []const u8,
    /// The provider's mark: the `d` of one path on a 24 by 24 canvas, filled with the
    /// button's text colour. Brand marks are the plugin's to ship, never the icon set's.
    icon: []const u8,
    /// Whether the provider can be offered now: its credentials are in the environment.
    available: *const fn () bool,
    /// Where to send the browser to sign in with the provider.
    authorize_url: *const fn (arena: std.mem.Allocator, request: Authorize) Error![]const u8,
    /// The person the callback's code stands for. `Unavailable` when the provider could
    /// not be reached, `BadCredentials` when it refused the code.
    identity: *const fn (io: std.Io, arena: std.mem.Allocator, callback: Callback) Error!Identity,
};

/// The declaration is well-formed; the message names what is not.
pub fn problem(provider: SignInProvider) ?[]const u8 {
    comptime std.debug.assert(label_len_max > 0);
    comptime std.debug.assert(icon_len_max > 0);

    if (!model.valid_provider(provider.name)) {
        return "`name` is [a-z][a-z0-9_]*, at most 32 characters";
    }

    if (provider.label.len == 0 or provider.label.len > label_len_max) {
        return "`label` is 1 to 32 characters";
    }

    if (provider.icon.len == 0 or provider.icon.len > icon_len_max) {
        return "`icon` is a path of 1 to 4096 characters";
    }

    return null;
}

/// The provider of that name, when one is declared.
pub fn find(providers: []const SignInProvider, name: []const u8) ?*const SignInProvider {
    std.debug.assert(providers.len <= providers_max);
    std.debug.assert(name.len <= model.provider_len_max + 1);

    for (providers) |*provider| {
        if (std.mem.eql(u8, provider.name, name)) {
            return provider;
        }
    }

    return null;
}

pub const testing = struct {
    /// A provider that trusts whatever the "code" says: `<id>:<email>` verified,
    /// `<id>:<email>:unverified` not, `refuse` refused, `down` unreachable.
    pub const trusting: SignInProvider = .{
        .name = "trusting",
        .label = "Trusting",
        .icon = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20z",
        .available = &always,
        .authorize_url = &authorize_url,
        .identity = &identity,
    };

    /// Declared but never offered: no credentials.
    pub const missing: SignInProvider = .{
        .name = "missing",
        .label = "Missing",
        .icon = "M2 2h20v20H2z",
        .available = &never,
        .authorize_url = &authorize_url,
        .identity = &identity,
    };

    fn always() bool {
        return true;
    }

    fn never() bool {
        return false;
    }

    fn authorize_url(arena: std.mem.Allocator, request: Authorize) Error![]const u8 {
        std.debug.assert(request.state.len > 0);
        std.debug.assert(request.code_challenge.len > 0);

        return std.fmt.allocPrint(
            arena,
            "https://provider.test/authorize?redirect_uri={s}&state={s}&code_challenge={s}",
            .{ request.callback_url, request.state, request.code_challenge },
        ) catch error.OutOfMemory;
    }

    fn identity(_: std.Io, _: std.mem.Allocator, callback: Callback) Error!Identity {
        std.debug.assert(callback.code_verifier.len > 0);
        std.debug.assert(callback.callback_url.len > 0);

        if (std.mem.eql(u8, callback.code, "refuse")) {
            return error.BadCredentials;
        }

        if (std.mem.eql(u8, callback.code, "down")) {
            return error.Unavailable;
        }

        var parts = std.mem.splitScalar(u8, callback.code, ':');
        const id = parts.next() orelse return error.BadCredentials;
        const email = parts.next();
        const unverified = parts.next() != null;

        return .{
            .provider = trusting.name,
            .id = id,
            .email = email,
            .verified = email != null and !unverified,
            .name = "Trusted Person",
        };
    }
};

test "a declaration names a valid provider, label and icon" {
    try std.testing.expect(problem(testing.trusting) == null);

    var bad_name = testing.trusting;
    bad_name.name = "Git-Hub";
    try std.testing.expect(problem(bad_name) != null);

    var bad_label = testing.trusting;
    bad_label.label = "";
    try std.testing.expect(problem(bad_label) != null);

    var bad_icon = testing.trusting;
    bad_icon.icon = "i" ** (icon_len_max + 1);
    try std.testing.expect(problem(bad_icon) != null);

    const both = [_]SignInProvider{ testing.trusting, testing.missing };
    try std.testing.expectEqualStrings("Missing", find(&both, "missing").?.label);
    try std.testing.expect(find(&both, "github") == null);
}
