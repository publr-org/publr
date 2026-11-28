const std = @import("std");

/// The Publr release this is; a release writes it.
pub const version = "0.9.1";

test "version is a semantic version with three components" {
    var parts: u32 = 0;
    var iterator = std.mem.splitScalar(u8, version, '.');

    while (iterator.next()) |part| : (parts += 1) {
        try std.testing.expect(part.len > 0);
        _ = try std.fmt.parseInt(u32, part, 10);
    }

    try std.testing.expectEqual(@as(u32, 3), parts);
}
