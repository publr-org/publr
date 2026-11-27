//! The plugin SDK's names as a plugin's code writes them, each an `sdk:` item of the
//! surface (`plugin surface`, the release's `surface.json`): every name of the public root
//! (`sdk:Ctx`), and every member of one that is a namespace or a type (`sdk:Ctx.call`,
//! `sdk:operation.define`). Read from `publr/root.zig`, whose reach the root check holds to
//! the public files first.
const std = @import("std");
const public = @import("../../publr/root.zig");
const public_root = @import("../../sdk/public_root.zig");
const Deprecated = @import("../../publr/operation.zig").Deprecated;

/// An SDK name on its way out, beside its name as `names` lists it (`sdk:Ctx.grant`).
pub const Deprecation = struct {
    name: []const u8,
    deprecated: Deprecated,
};

/// Every SDK name on its way out: one entry each, checked against `names`.
pub const deprecated = [_]Deprecation{};

comptime {
    public_root.check();
}

pub const names = listed: {
    @setEvalBranchQuota(names_max * 64);

    var list: []const []const u8 = &.{};

    for (std.meta.declarations(public)) |decl| {
        const value = @field(public, decl);

        list = list ++ &[_][]const u8{"sdk:" ++ decl};

        if (@TypeOf(value) == type) {
            for (members(value)) |member| {
                list = list ++ &[_][]const u8{"sdk:" ++ decl ++ "." ++ member};
            }
        }
    }

    if (list.len > names_max) {
        @compileError("the SDK has more than names_max names");
    }

    const final = list[0..list.len].*;

    break :listed final;
};

/// How many names the SDK may have, root names and their members.
const names_max: u32 = 4096;

fn members(comptime Type: type) []const [:0]const u8 {
    return switch (@typeInfo(Type)) {
        inline .@"struct", .@"enum", .@"union", .@"opaque" => |container| container.decl_names,
        else => &.{},
    };
}

comptime {
    for (deprecated) |item| {
        if (!std.mem.startsWith(u8, item.name, "sdk:")) {
            @compileError(item.name ++ ": an SDK name is listed as `sdk:<name>`");
        }

        @import("../../sdk/operation.zig").check_deprecated(item.name, item.deprecated);
    }
}

test "the SDK's names are listed once each, the root's first" {
    try std.testing.expect(names.len > std.meta.declarations(public).len);

    for (names, 0..) |name, index| {
        try std.testing.expect(std.mem.startsWith(u8, name, "sdk:"));

        for (names[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }

    try std.testing.expect(listed_in("sdk:Ctx"));
    try std.testing.expect(listed_in("sdk:operation.define"));
    try std.testing.expect(!listed_in("sdk:db"));
}

fn listed_in(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |one| {
        if (std.mem.eql(u8, one, name)) {
            return true;
        }
    }

    return false;
}
