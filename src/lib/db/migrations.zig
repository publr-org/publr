const std = @import("std");
const migration = @import("migration.zig");

/// The release whose `schema.sql` core's chain starts from: a database it or any later
/// release made reaches today's shape by the migrations in `core`.
pub const baseline = "0.7.5";

/// Core's migrations since the baseline, oldest first, one per minor or major release:
/// `migrations/<x.y.0>.zig`, and the unreleased one while the next is being written, which
/// the Release workflow names. Each entry is
///
///     .of("publr", "<x.y.0>", @import("migrations/<x.y.0>.zig"), @embedFile(...)),
///
/// written over five lines. Released ones never change and are never removed.
/// `zig build migration-draft` starts the next one.
pub const core = [_]migration.Migration{
    .of(
        "publr",
        migration.unreleased,
        @import("migrations/0.8.0.zig"),
        @embedFile("migrations/0.8.0.zig"),
    ),
};

/// What a database recorded, less core's rows named for a release before the baseline: the
/// releases before it recorded those, `schema.sql` holds what they made, and they stay in
/// the table for those releases to read.
pub fn since_baseline(
    arena: std.mem.Allocator,
    recorded: []const migration.Applied,
) ![]const migration.Applied {
    std.debug.assert(recorded.len <= migration.migrations_max);

    const start = comptime std.SemanticVersion.parse(baseline) catch unreachable;
    var kept: std.ArrayList(migration.Applied) = .empty;

    for (recorded) |row| {
        const core_row = std.mem.eql(u8, row.source, "publr");
        const release = std.SemanticVersion.parse(row.name) catch null;
        const before = core_row and release != null and release.?.order(start) == .lt;

        if (!before) {
            try kept.append(arena, row);
        }
    }

    std.debug.assert(kept.items.len <= recorded.len);

    return kept.items;
}

test "core's rows from before the baseline are left out, every other row kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const rows = [_]migration.Applied{
        .{
            .source = "publr",
            .name = "0.3.0",
            .sha256 = "a",
            .one_way = false,
        },
        .{
            .source = "publr",
            .name = "0.4.0",
            .sha256 = "b",
            .one_way = false,
        },
        .{
            .source = "publr",
            .name = baseline,
            .sha256 = "c",
            .one_way = false,
        },
        .{
            .source = "publr",
            .name = migration.unreleased,
            .sha256 = "d",
            .one_way = false,
        },
        .{
            .source = "shop",
            .name = "0.1.0",
            .sha256 = "e",
            .one_way = false,
        },
    };
    const kept = try since_baseline(arena_state.allocator(), &rows);

    try std.testing.expectEqual(@as(usize, 3), kept.len);
    try std.testing.expectEqualStrings(baseline, kept[0].name);
    try std.testing.expectEqualStrings(migration.unreleased, kept[1].name);
    try std.testing.expectEqualStrings("shop", kept[2].source);
}
