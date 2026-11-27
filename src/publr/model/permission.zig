//! How a plugin's requests read to an administrator: the risk each carries and the switches
//! a grant takes.

/// A request's risk: low and medium ones are granted on enabling, high ones wait.
pub const Tier = enum { low, medium, high };

/// A yes/no option on a grant, each a switch in the admin.
pub const Flag = enum { drafts, private, internal, publish };

/// What a plugin was given for one request (`ctx.grant(key)`): whether the key is on, and
/// its flags as granted now.
pub const Grant = struct {
    on: bool,
    drafts: bool = false,
    private: bool = false,
    internal: bool = false,
    publish: bool = false,
    /// `http.fetch`'s domains as granted now: compiled in, as asked; installed, the list an
    /// administrator left (as asked until one is saved).
    domains: []const []const u8 = &.{},

    pub const off: Grant = .{
        .on = false,
    };
};
