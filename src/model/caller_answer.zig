//! A ready answer to who may call an operation, kept as data so a site can read and override
//! it: `publr.authorize.user_is_signed_in` and the like.

pub const Answer = union(enum) {
    /// Anyone, signed in or not: what `.untrusted_callers` without `.authorize` means. No
    /// plugin writes it and no site sets it; the name is kept for stored manifests.
    visitor,
    /// Anyone signed in.
    signed_in,
    /// Anyone holding one of the roles.
    roles: []const []const u8,
    /// Other plugins' code only.
    plugin_calls,
};
