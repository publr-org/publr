//! Taxonomies registered on other plugins' types as the site keeps them
//! (`publr/plugin/taxonomy_define.zig` is what a plugin writes): whose each is, and which
//! types its patterns pick.
const std = @import("std");

pub const to_max = @import("../../publr/plugin/taxonomy_define.zig").to_max;

/// A registration as the site keeps it: whose it is.
pub const Registered = struct {
    plugin: []const u8,
    taxonomy: []const u8,
    to: []const []const u8,
};

/// Whether `pattern` picks the type `handle`: itself, `plugin.*` for every type of that
/// plugin, `*` for every one.
pub fn matches(pattern: []const u8, handle: []const u8) bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(handle.len > 0);

    if (std.mem.eql(u8, pattern, "*")) {
        return true;
    }

    if (std.mem.endsWith(u8, pattern, ".*")) {
        const prefix = pattern[0 .. pattern.len - 1];

        return std.mem.startsWith(u8, handle, prefix) and handle.len > prefix.len;
    }

    return std.mem.eql(u8, pattern, handle);
}

/// Whether `pattern` is one type by name, not a pattern.
pub fn is_exact(pattern: []const u8) bool {
    std.debug.assert(pattern.len > 0);

    return !std.mem.eql(u8, pattern, "*") and !std.mem.endsWith(u8, pattern, ".*");
}

test "a pattern picks one type, a plugin's types, or every type" {
    try std.testing.expect(matches("*", "post"));
    try std.testing.expect(matches("products.*", "products.variant"));
    try std.testing.expect(!matches("products.*", "products"));
    try std.testing.expect(!matches("products.*", "productsx.variant"));
    try std.testing.expect(matches("events.event", "events.event"));
    try std.testing.expect(!matches("events.event", "events.other"));
    try std.testing.expect(is_exact("events.event"));
    try std.testing.expect(!is_exact("products.*"));
    try std.testing.expect(!is_exact("*"));
}
