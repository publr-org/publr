//! Operations a built-in plugin names by their full name, as Publr is compiled.

/// The operation named `name` in this build, or null when the build has none.
pub fn find_operation(comptime name: []const u8) ?type {
    comptime {
        if (name.len == 0 or @import("std").mem.indexOfScalar(u8, name, '.') == null) {
            @compileError("find_operation: a full name, `<namespace>.<verb>`");
        }

        return @import("../../server/registry.zig").SDK.find(name);
    }
}

test "an operation of the build is found by its name, an unknown one is not" {
    comptime {
        if (find_operation("role.list") == null or find_operation("nobody.nothing") != null) {
            unreachable;
        }
    }
}
