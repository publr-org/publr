//! What a plugin builds on: `pub const depends_on = .{ "newsletter@^1.2" }`, each the name
//! of another plugin and, after `@`, the versions it works with (exact, `1.2.3`, or caret,
//! `^0.2`: the same leftmost non-zero part, no older). A compiled-in plugin's requirements
//! are checked when the binary is built; an installed plugin's when it is enabled.
const std = @import("std");

pub const depends_on_max: u32 = 16;
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

/// Every compiled-in plugin's requirements met by another compiled-in plugin, and none
/// requiring itself, directly or round a loop: a compile error naming what is wrong.
pub fn check(comptime plugins: anytype) void {
    comptime {
        for (plugins) |Plugin| {
            const name = Plugin.manifest.name;
            const list = of(Plugin);

            if (list.len > depends_on_max) {
                @compileError("plugin " ++ name ++ ": `depends_on` names at most 16 plugins");
            }

            for (list) |text| {
                const wanted = parse(text);
                const found = find(plugins, wanted.name) orelse @compileError("plugin " ++
                    name ++ " depends on " ++ wanted.name ++ ", which is not compiled in");

                if (!satisfies(found.manifest.version, wanted.range)) {
                    @compileError("plugin " ++ name ++ " depends on " ++ text ++ "; " ++
                        wanted.name ++ " is " ++ found.manifest.version);
                }

                if (reaches(plugins, wanted.name, name, plugins.len * depends_on_max)) {
                    @compileError("plugin " ++ name ++ " depends on " ++ wanted.name ++
                        ", which depends on it back");
                }
            }
        }
    }
}

pub fn of(comptime Plugin: type) []const []const u8 {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "depends_on")) {
            return &.{};
        }

        return &Plugin.depends_on;
    }
}

fn find(comptime plugins: anytype, comptime name: []const u8) ?type {
    comptime {
        std.debug.assert(name.len > 0);

        for (plugins) |Plugin| {
            if (std.mem.eql(u8, Plugin.manifest.name, name)) {
                return Plugin;
            }
        }

        return null;
    }
}

/// Whether `from` depends on `target`, directly or through others: a walk over at most
/// `limit` plugins.
fn reaches(
    comptime plugins: anytype,
    comptime from: []const u8,
    comptime target: []const u8,
    comptime limit: u32,
) bool {
    comptime {
        std.debug.assert(from.len > 0 and target.len > 0);

        var pending: []const []const u8 = &.{from};
        var visited: u32 = 0;

        while (pending.len > 0 and visited <= limit) : (visited += 1) {
            const Plugin = find(plugins, pending[0]) orelse {
                pending = pending[1..];
                continue;
            };

            pending = pending[1..];

            for (of(Plugin)) |text| {
                const next = parse(text).name;

                if (std.mem.eql(u8, next, target)) {
                    return true;
                }

                pending = pending ++ &[_][]const u8{next};
            }
        }

        return false;
    }
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

test "compiled-in requirements are checked when the binary is built" {
    const Base = struct {
        pub const manifest = .{ .name = "base", .version = "0.2.3" };
    };
    const Dependent = struct {
        pub const manifest = .{ .name = "dependent", .version = "0.1.0" };
        pub const depends_on = [_][]const u8{"base@^0.2"};
    };

    comptime check(.{ Base, Dependent });
    try std.testing.expectEqual(@as(usize, 1), comptime of(Dependent).len);
    try std.testing.expect(!comptime reaches(.{ Base, Dependent }, "base", "dependent", 2));
}

test "an installed plugin's manifest carries its depends_on" {
    const Child = struct {
        pub const manifest = .{ .name = "child", .version = "1.0.0", .summary = "Test child" };
        pub const depends_on = .{"parent@^1.0"};
    };
    const manifest = comptime @import("manifest.zig").of(Child);

    try std.testing.expectEqualStrings("parent@^1.0", (comptime of(Child))[0]);
    try std.testing.expectEqualStrings("parent@^1.0", manifest.depends_on[0]);
}
