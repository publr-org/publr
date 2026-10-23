//! What a plugin builds on: `pub const depends_on = .{ "newsletter@^1.2" }`, each the name
//! of another plugin and, after `@`, the versions it works with (exact, `1.2.3`, or caret,
//! `^0.2`: the same leftmost non-zero part, no older). A compiled-in plugin's requirements
//! are checked when the binary is built; an installed plugin's when it is enabled.
const std = @import("std");
const plugin_define = @import("define.zig");

pub const depends_on_max: u32 = 16;
const version_range = @import("../../model/version_range.zig");

pub const parse = version_range.parse;
pub const satisfies = version_range.satisfies;

/// Whether `list` (`depends_on` or `compatible_with`) names the plugin `name`.
pub fn names(list: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (list) |text| {
        if (text.len > 0 and std.mem.eql(u8, parse(text).name, name)) {
            return true;
        }
    }

    return false;
}

/// Whether `list` names the plugin that owns `operation_name`.
pub fn names_owner(list: []const []const u8, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);

    for (list) |text| {
        const parent = if (text.len > 0) parse(text).name else "";

        if (parent.len > 0 and @import("../plugin_access.zig").own(parent, operation_name)) {
            return true;
        }
    }

    return false;
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

        if (!plugin_define.has(Plugin, "depends_on")) {
            return &.{};
        }

        return plugin_define.get(Plugin, "depends_on");
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

test "compiled-in requirements are checked when the binary is built" {
    const Base = test_plugin("base", "0.2.3", .{});
    const Dependent = test_plugin("dependent", "0.1.0", .{
        .depends_on = .{"base@^0.2"},
    });

    comptime check(.{ Base, Dependent });
    try std.testing.expectEqual(@as(usize, 1), comptime of(Dependent).len);
    try std.testing.expect(!comptime reaches(.{ Base, Dependent }, "base", "dependent", 2));
}

test "an installed plugin's manifest carries its depends_on" {
    const Child = test_plugin("child", "1.0.0", .{
        .depends_on = .{"parent@^1.0"},
    });
    const manifest = comptime @import("manifest.zig").of(Child);

    try std.testing.expectEqualStrings("parent@^1.0", (comptime of(Child))[0]);
    try std.testing.expectEqualStrings("parent@^1.0", manifest.depends_on[0]);
}

fn test_plugin(
    comptime name: []const u8,
    comptime version: []const u8,
    comptime options: anytype,
) type {
    return plugin_define.Bind(struct {
        pub const plugin = plugin_define.define(.{
            .name = name,
            .version = version,
        }, options);
    }, plugin_define.Words(.{
        .{ "main", "Test plugin" },
    }));
}
