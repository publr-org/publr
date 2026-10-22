//! Where a name a plugin file imports keeps its words: `const Shout = @import("hooks/shout.zig")`
//! in `main.zig` makes `Shout.run` the words filed under `hooks.shout.run`, so a hook defined
//! in one file and listed in another still finds its reason.
const std = @import("std");

pub const path_parts_max: u32 = 16;

/// The key of `member` in the file `path` imports, seen from the file keyed `from`
/// (`main`, `hooks.shout`); null for a path outside the plugin or not a `.zig` file.
pub fn member_key(
    arena: std.mem.Allocator,
    from: []const u8,
    path: []const u8,
    member: []const u8,
) !?[]const u8 {
    std.debug.assert(from.len > 0);
    std.debug.assert(member.len > 0);

    if (!std.mem.endsWith(u8, path, ".zig") or std.mem.startsWith(u8, path, "/")) {
        return null;
    }

    var parts: [path_parts_max][]const u8 = undefined;
    var count: u32 = 0;
    var folders = std.mem.splitScalar(u8, from, '.');
    var folder_count = std.mem.count(u8, from, ".");

    while (folder_count > 0) : (folder_count -= 1) {
        parts[count] = folders.next().?;
        count += 1;
    }

    var steps = std.mem.splitScalar(u8, path[0 .. path.len - ".zig".len], '/');

    while (steps.next()) |step| {
        if (std.mem.eql(u8, step, "..")) {
            if (count == 0) {
                return null;
            }

            count -= 1;
        } else if (step.len > 0 and !std.mem.eql(u8, step, ".")) {
            if (count == path_parts_max) {
                return null;
            }

            parts[count] = step;
            count += 1;
        }
    }

    if (count == 0) {
        return null;
    }

    const file = try std.mem.join(arena, ".", parts[0..count]);

    return try std.fmt.allocPrint(arena, "{s}.{s}", .{ file, member });
}

test "an imported file's member, from the root and from a folder, never outside" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "hooks.shout.run",
        (try member_key(arena, "main", "hooks/shout.zig", "run")).?,
    );
    try std.testing.expectEqualStrings(
        "records.notes.run",
        (try member_key(arena, "hooks.shout", "../records/notes.zig", "run")).?,
    );
    try std.testing.expectEqualStrings(
        "hooks.tidy.run",
        (try member_key(arena, "hooks.shout", "./tidy.zig", "run")).?,
    );
    try std.testing.expect(try member_key(arena, "main", "../elsewhere.zig", "run") == null);
    try std.testing.expect(try member_key(arena, "main", "/etc/x.zig", "run") == null);
    try std.testing.expect(try member_key(arena, "main", "std", "run") == null);
}
