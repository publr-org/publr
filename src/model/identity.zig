//! An external identity: who a sign-in provider says someone is. Pure rules on the shape of
//! one, nothing about accounts, which are `identity.sign_in`'s to decide.

const std = @import("std");
const account = @import("account.zig");

pub const provider_len_max: u32 = 32;
pub const id_len_max: u32 = 255;
pub const name_len_max: u32 = account.display_name_len_max;
pub const avatar_len_max: u32 = 2048;
pub const email_len_max: u32 = account.email_len_max;

/// What a provider plugin returns from a callback, and what the routes hand the operations.
pub const Identity = struct {
    /// The provider's public name: `github`, `google`.
    provider: []const u8,
    /// The provider's stable id for the person: never their email or login name.
    id: []const u8,
    email: ?[]const u8 = null,
    /// The provider vouches for the email: only then may it link or create an account.
    verified: bool = false,
    name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};

/// `[a-z][a-z0-9_]*`, at most 32 characters: what the routes and the rows use.
pub fn valid_provider(provider: []const u8) bool {
    comptime std.debug.assert(provider_len_max > 0);

    if (provider.len == 0 or provider.len > provider_len_max) {
        return false;
    }

    for (provider, 0..) |char, index| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';
        const ok = lower or char == '_' or (digit and index > 0);

        if (!ok) {
            return false;
        }
    }

    return true;
}

/// A provider's id is opaque: printable ASCII, no spaces, 1 to 255 characters.
pub fn valid_id(id: []const u8) bool {
    comptime std.debug.assert(id_len_max > 0);

    if (id.len == 0 or id.len > id_len_max) {
        return false;
    }

    for (id) |char| {
        if (char <= ' ' or char > '~') {
            return false;
        }
    }

    return true;
}

/// The provider and id are well-formed and the optional parts are within their limits.
pub fn valid(identity: Identity) bool {
    comptime std.debug.assert(avatar_len_max > 0);

    const email_ok = identity.email == null or identity.email.?.len <= email_len_max;
    const name_ok = identity.name == null or identity.name.?.len <= name_len_max;
    const avatar_ok = identity.avatar == null or identity.avatar.?.len <= avatar_len_max;

    return valid_provider(identity.provider) and valid_id(identity.id) and
        email_ok and name_ok and avatar_ok;
}

test "a provider is a plugin-like name, an id is opaque but printable" {
    try std.testing.expect(valid_provider("github"));
    try std.testing.expect(valid_provider("auth_google2"));
    try std.testing.expect(!valid_provider(""));
    try std.testing.expect(!valid_provider("GitHub"));
    try std.testing.expect(!valid_provider("2fa"));
    try std.testing.expect(!valid_provider("git-hub"));
    try std.testing.expect(!valid_provider("a" ** (provider_len_max + 1)));

    try std.testing.expect(valid_id("12345"));
    try std.testing.expect(valid_id("110248495921712042890"));
    try std.testing.expect(!valid_id(""));
    try std.testing.expect(!valid_id("has space"));
    try std.testing.expect(!valid_id("tab\there"));
    try std.testing.expect(!valid_id("é"));
    try std.testing.expect(!valid_id("x" ** (id_len_max + 1)));
}

test "an identity is valid when its parts are" {
    try std.testing.expect(valid(.{ .provider = "github", .id = "1" }));
    try std.testing.expect(valid(.{
        .provider = "github",
        .id = "1",
        .email = "ada@example.com",
        .verified = true,
        .name = "Ada",
        .avatar = "https://example.com/ada.png",
    }));
    try std.testing.expect(!valid(.{ .provider = "", .id = "1" }));
    try std.testing.expect(!valid(.{ .provider = "github", .id = "" }));
    try std.testing.expect(!valid(.{ .provider = "github", .id = "1", .name = "n" ** 200 }));
    try std.testing.expect(!valid(.{ .provider = "github", .id = "1", .avatar = "a" ** 3000 }));
}
