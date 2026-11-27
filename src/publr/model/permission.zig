//! How a plugin's requests read to an administrator: the risk each carries and the switches
//! a grant takes.

/// A request's risk: low and medium ones are granted on enabling, high ones wait.
pub const Tier = enum { low, medium, high };

/// A yes/no option on a grant, each a switch in the admin.
pub const Flag = enum { drafts, private, internal, publish };
