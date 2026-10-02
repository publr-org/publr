//! A plugin and the versions another works with: `newsletter@^1.2`. Exact (`1.2.3`) or
//! caret (`^0.2`: the same leftmost non-zero part, no older); no range, any version.
const std = @import("std");

const parts_max: u32 = 3;

pub const Requirement = struct {
    name: []const u8,
    /// Empty: any version.
    range: []const u8 = "",
};

/// `name` or `name@range`.
pub fn parse(text: []const u8) Requirement {
    std.debug.assert(text.len > 0);

    const at = std.mem.indexOfScalar(u8, text, '@') orelse return .{ .name = text };

    return .{ .name = text[0..at], .range = text[at + 1 ..] };
}

/// Whether `version` is in `range`: any when the range is empty, the same when exact, and for
/// `^a.b.c` at least `a.b.c` with the same leftmost non-zero part. Malformed is never.
pub fn satisfies(version: []const u8, range: []const u8) bool {
    std.debug.assert(version.len > 0);

    if (range.len == 0) {
        return true;
    }

    const have = numbers(version) orelse return false;

    if (range[0] != '^') {
        const want = numbers(range) orelse return false;

        return std.mem.eql(u32, &have.parts, &want.parts);
    }

    const want = numbers(range[1..]) orelse return false;
    const fixed = for (want.parts[0..want.len], 0..) |part, index| {
        if (part != 0) {
            break index;
        }
    } else want.len -| 1;

    for (0..fixed + 1) |index| {
        if (have.parts[index] != want.parts[index]) {
            return false;
        }
    }

    return std.mem.order(u32, &have.parts, &want.parts) != .lt;
}

const Numbers = struct { parts: [parts_max]u32 = @splat(0), len: u32 = 0 };

/// `1`, `1.2` or `1.2.3`, the missing parts 0; a pre-release or build suffix ignored.
fn numbers(text: []const u8) ?Numbers {
    std.debug.assert(parts_max == 3);

    const end = std.mem.indexOfAny(u8, text, "-+") orelse text.len;
    var found: Numbers = .{};
    var pieces = std.mem.splitScalar(u8, text[0..end], '.');

    while (pieces.next()) |piece| {
        if (found.len == parts_max) {
            return null;
        }

        found.parts[found.len] = std.fmt.parseInt(u32, piece, 10) catch return null;
        found.len += 1;
    }

    return if (found.len == 0) null else found;
}

test "a requirement is a name and, after @, the versions it takes" {
    const plain = parse("newsletter");
    try std.testing.expectEqualStrings("newsletter", plain.name);
    try std.testing.expectEqualStrings("", plain.range);

    const ranged = parse("newsletter@^1.2");
    try std.testing.expectEqualStrings("newsletter", ranged.name);
    try std.testing.expectEqualStrings("^1.2", ranged.range);
}

test "exact and caret ranges" {
    try std.testing.expect(satisfies("0.2.0", ""));
    try std.testing.expect(satisfies("0.2.0", "0.2.0"));
    try std.testing.expect(!satisfies("0.2.1", "0.2.0"));
    try std.testing.expect(satisfies("0.2.0", "^0.2"));
    try std.testing.expect(satisfies("0.2.7", "^0.2.1"));
    try std.testing.expect(!satisfies("0.2.0", "^0.2.1"));
    try std.testing.expect(!satisfies("0.3.0", "^0.2"));
    try std.testing.expect(satisfies("1.4.0", "^1.2"));
    try std.testing.expect(!satisfies("2.0.0", "^1.2"));
    try std.testing.expect(satisfies("0.0.3", "^0.0.3"));
    try std.testing.expect(!satisfies("0.0.4", "^0.0.3"));
    try std.testing.expect(satisfies("1.0.0-beta", "^1"));
    try std.testing.expect(!satisfies("x", "^1"));
    try std.testing.expect(!satisfies("1.0.0", "^x"));
}
