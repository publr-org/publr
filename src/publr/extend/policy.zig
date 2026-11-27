//! A rule on who may call operations, beside each operation's own, as a built-in plugin
//! declares one with `host.policy`. Core asks every policy about every call it allows and
//! keeps the narrowest answer: a policy only takes away. A deciding step: pure, no calls.
const caller = @import("../caller.zig");
const operation = @import("../operation.zig");

/// The call a policy is asked about.
pub const Request = struct {
    operation_name: []const u8,
    kind: operation.Kind,
    /// The content type the call names (its input's `type`), if any.
    type_id: ?[]const u8 = null,
    /// The operation says anyone may call it (`pub const open = true`), like signing in.
    open: bool = false,
    /// The type the call names is one the compiled-in plugin making the call declares.
    own_type: bool = false,
    /// Made inside another operation, not by whoever sent the request.
    nested: bool = false,
    /// Made while the site's pages are drawn.
    delivery: bool = false,
};

pub const Decision = enum { allow, deny };

/// What a policy allows of the call.
pub const Grant = struct {
    decision: Decision = .allow,
    read_only: bool = false,
    /// The content types in reach; null: every one.
    types: ?[]const []const u8 = null,
    /// Only the records the caller made.
    own_only: bool = false,
    /// Only what is live: no drafts.
    live_only: bool = false,
    /// Only public types.
    public_types_only: bool = false,

    pub const deny: Grant = .{
        .decision = .deny,
    };
    pub const allow_all: Grant = .{};
};

pub const View = caller.View;

pub const Policy = *const fn (who: View, request: Request) Grant;
