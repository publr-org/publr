//! What a field of an operation's shape holds, read through its optional and its list: a
//! tree's node finds itself in its children (`fields: []const Def`), which the build's walks
//! over a shape read once.
const std = @import("std");

/// The type a field holds through its optional and its list; text is itself.
pub fn inner_of(comptime Field: type) type {
    comptime {
        std.debug.assert(@typeInfo(Field) != .type);

        return switch (@typeInfo(Field)) {
            .optional => |optional| inner_of(optional.child),
            .pointer => |pointer| if (pointer.child == u8) Field else inner_of(pointer.child),
            else => Field,
        };
    }
}

test "a field holds its list's item, through an optional, and text is itself" {
    const Node = struct {
        children: ?[]const @This() = null,
    };

    try std.testing.expect(inner_of(?[]const Node) == Node);
    try std.testing.expect(inner_of([]const u8) == []const u8);
}
