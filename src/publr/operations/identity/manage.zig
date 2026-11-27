//! An account's identities: which providers vouch for it, adding one, dropping one.
const operation = @import("../../operation.zig");
const identity_operations = @import("../identity.zig");

/// A provider's identity an account holds.
pub const Summary = struct {
    provider: []const u8,
    id: []const u8,
    email: ?[]const u8,
    created_at: i64,
    last_used_at: i64,
};

pub const Link = struct {
    pub const name = "identity.link";
    pub const description = "Link a provider's identity to an account";
    pub const details =
        \\Administrators, and the system: `/auth/<provider>/callback` calls it for a
        \\signed-in person once the provider plugin has verified who they are, so an
        \\account gains a second way in. An identity already linked, to this account or
        \\another, is a conflict; an account may hold sixteen.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
        provider: []const u8,
        id: []const u8,
        email: ?[]const u8 = null,
        verified: bool = false,
        name: ?[]const u8 = null,
        avatar: ?[]const u8 = null,
    };
    pub const Out = struct {
        linked: bool,
        user_id: []const u8,
    };
    pub const example: In = .{
        .user = "ada@example.com",
        .provider = "google",
        .id = "110248495921712042890",
        .email = identity_operations.example_in.email,
        .verified = true,
    };
    pub const example_out: Out = .{
        .linked = true,
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The account to link to, by id or email",
        .provider = identity_operations.in_docs.provider,
        .id = identity_operations.in_docs.id,
        .email = identity_operations.in_docs.email,
        .verified = identity_operations.in_docs.verified,
        .name = identity_operations.in_docs.name,
        .avatar = identity_operations.in_docs.avatar,
    };
    pub const output_docs: operation.Docs(Out) = .{
        .linked = "Always true",
        .user_id = "The account's id",
    };
};

pub const List = struct {
    pub const name = "identity.list";
    pub const description = "The providers that vouch for an account";
    pub const details =
        \\A signed-in account lists its own; `user` names another account, for the system
        \\and administrators. Nothing is written.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        user: ?[]const u8 = null,
    };
    pub const Out = struct {
        identities: []const Summary,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .identities = &.{.{
            .provider = "github",
            .id = "583231",
            .email = "ada@example.com",
            .created_at = 1789640000000,
            .last_used_at = 1792232000000,
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The account's id; the caller's own when omitted",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .identities = "Each linked identity, oldest first; times are Unix milliseconds",
    };
};

pub const Unlink = struct {
    pub const name = "identity.unlink";
    pub const description = "Drop a provider's identity from an account";
    pub const details =
        \\A signed-in account drops its own; `user` names another account, for the system
        \\and administrators. The last identity of an account without a password stays: dropping it
        \\would lock the account out, and that is a conflict. An identity the account does
        \\not hold is not found.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        provider: []const u8,
        id: []const u8,
        user: ?[]const u8 = null,
    };
    pub const Out = struct {
        unlinked: bool,
        user_id: []const u8,
    };
    pub const example: In = .{
        .provider = "github",
        .id = "583231",
    };
    pub const example_out: Out = .{
        .unlinked = true,
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
    };
    pub const field_docs: operation.Docs(In) = .{
        .provider = identity_operations.in_docs.provider,
        .id = identity_operations.in_docs.id,
        .user = "The account's id; the caller's own when omitted",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .unlinked = "Always true",
        .user_id = "The account's id",
    };
};
