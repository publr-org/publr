//! Sign-in providers as core keeps them: the contract is `publr/extend/sign_in.zig`; here
//! are its checks and the lookups the login pages make.

const std = @import("std");
const model = @import("../model/identity.zig");
const exchange_module = @import("plugin/exchange.zig");

pub const ExchangeCtx = exchange_module.ExchangeCtx;
const PluginCtx = @import("plugin/context.zig").PluginCtx;
pub const Error = @import("../publr/operation.zig").Error;
const public = @import("../publr/extend/sign_in.zig");

pub const providers_max = public.providers_max;
pub const label_len_max = public.label_len_max;
pub const icon_len_max = public.icon_len_max;
pub const exchange_ms_max = public.exchange_ms_max;
pub const header_len_max = public.header_len_max;
pub const Authorize = public.Authorize;
pub const Callback = public.Callback;
pub const Claims = public.Claims;
pub const SignInProvider = public.SignInProvider;
pub const FromRequest = public.FromRequest;

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

    const redirects = provider.authorize_url != null and provider.exchange != null;
    const half = (provider.authorize_url == null) != (provider.exchange == null);

    if (half or redirects == (provider.from_request != null)) {
        return "a provider has `authorize_url` and `exchange`, or `from_request`, not both";
    }

    if (provider.from_request) |reading| {
        if (!valid_header(reading.header)) {
            return "`from_request.header` is a lower-case header name, at most 64 characters";
        }
    }

    return null;
}

fn valid_header(header: []const u8) bool {
    std.debug.assert(header_len_max > 0);

    if (header.len == 0 or header.len > header_len_max) {
        return false;
    }

    for (header) |char| {
        const allowed = std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

/// The provider read from the request that is declared, when there is one: at most one may
/// be (`plugin.zig` refuses a second).
pub fn from_request_of(providers: []const SignInProvider) ?*const SignInProvider {
    std.debug.assert(providers.len <= providers_max);

    for (providers) |*provider| {
        if (provider.from_request != null) {
            return provider;
        }
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
        .exchange = &exchange,
    };

    /// Declared but never offered: no credentials.
    pub const missing: SignInProvider = .{
        .name = "missing",
        .label = "Missing",
        .icon = "M2 2h20v20H2z",
        .available = &never,
        .authorize_url = &authorize_url,
        .exchange = &exchange,
    };

    /// A proxy in front that trusts whatever `x-test-identity` says: `<id>:<email>`,
    /// vouched; anything without a colon names nobody.
    pub const forwarded: SignInProvider = .{
        .name = "forwarded",
        .label = "Forwarded",
        .icon = "M2 12h20",
        .available = &always,
        .from_request = .{
            .header = "x-test-identity",
            .read = &read_forwarded,
        },
    };

    fn always() bool {
        return true;
    }

    fn never() bool {
        return false;
    }

    fn read_forwarded(ctx: *PluginCtx, value: []const u8) Error!?Claims {
        std.debug.assert(ctx.now().ms >= 0);
        std.debug.assert(value.len <= 64 << 10);

        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;

        if (colon == 0 or colon + 1 == value.len) {
            return null;
        }

        return .{
            .provider = forwarded.name,
            .subject = value[0..colon],
            .email = value[colon + 1 ..],
            .verified = true,
        };
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

    fn exchange(_: *ExchangeCtx, callback: Callback) Error!Claims {
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
            .subject = id,
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
    bad_icon.icon = &@as([icon_len_max + 1]u8, @splat('i'));
    try std.testing.expect(problem(bad_icon) != null);

    const both = [_]SignInProvider{ testing.trusting, testing.missing };
    try std.testing.expectEqualStrings("Missing", find(&both, "missing").?.label);
    try std.testing.expect(find(&both, "github") == null);
    try std.testing.expect(from_request_of(&both) == null);
}

test "a provider redirects or reads the request, never both nor half of one" {
    try std.testing.expect(problem(testing.forwarded) == null);

    var both = testing.forwarded;
    both.authorize_url = testing.trusting.authorize_url;
    both.exchange = testing.trusting.exchange;
    try std.testing.expect(problem(both) != null);

    var half = testing.trusting;
    half.exchange = null;
    try std.testing.expect(problem(half) != null);

    var neither = testing.trusting;
    neither.authorize_url = null;
    neither.exchange = null;
    try std.testing.expect(problem(neither) != null);

    var shouting = testing.forwarded;
    shouting.from_request.?.header = "X-Test-Identity";
    try std.testing.expect(problem(shouting) != null);

    const declared = [_]SignInProvider{ testing.trusting, testing.forwarded };
    try std.testing.expectEqualStrings("forwarded", from_request_of(&declared).?.name);
}
