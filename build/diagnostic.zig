//! Build configuration and filesystem failures are ordinary command failures.
const std = @import("std");

pub fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.assert(format.len > 0);
    std.log.err(format, args);
    std.process.exit(1);
}
