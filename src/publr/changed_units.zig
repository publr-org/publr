//! What a write changed, unit by unit, heard inside the write: a record, a term, a type, a
//! taxonomy, a field group, a plugin, a view, an account, an internal record. For a built-in
//! plugin that keeps its own account of changes (what a deployment carries):
//! `pub const hooks = publr.changed_units.hooks(&.{ .record, .term }, changed);`.
const std = @import("std");
const guest = @import("../sdk/plugin/guest.zig");
const Ctx = @import("ctx.zig").Ctx;

pub const Kind = enum {
    record,
    term,
    content_type,
    taxonomy,
    field_group,
    plugin,
    view,
    user,
    internal,
};

/// One thing a write changed: a type's or taxonomy's handle, a field group's, a plugin's
/// name, a view's id (a type's default view by the type's handle), anything else's id.
pub const Unit = struct {
    kind: Kind,
    key: []const u8,

    /// `plugin:shelf`.
    pub fn text(unit: Unit, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        std.debug.assert(unit.key.len > 0);

        const written = try std.fmt.allocPrint(arena, "{t}:{s}", .{ unit.kind, unit.key });

        std.debug.assert(written.len > unit.key.len);

        return written;
    }
};

/// What the plugin does with a unit a write changed, inside that write: `operation` is the
/// write's name.
pub const Keep = fn (ctx: *Ctx, operation: []const u8, unit: Unit) void;

/// One `publr.after` hook for each write that may change a unit of `kinds`, listed in the
/// plugin's `.hooks`: each hands `keep` the units of those kinds its write changed, in
/// order. A built-in plugin's alone: an installed build that asks for it does not compile.
pub fn hooks(comptime kinds: []const Kind, comptime keep: Keep) Hooks(kinds) {
    if (comptime guest.mode == .sandboxed) {
        @compileError("publr.changed_units.hooks is for a built-in plugin");
    }

    comptime std.debug.assert(kinds.len > 0);

    return core().hooks(kinds, Kept(keep).run);
}

fn Hooks(comptime kinds: []const Kind) type {
    if (guest.mode == .sandboxed) {
        return [0]type;
    }

    return @TypeOf(core().hooks(kinds, Kept(keep_nothing).run));
}

fn core() type {
    return @import("../sdk/changed_units.zig");
}

fn Kept(comptime keep: Keep) type {
    return struct {
        fn run(inner: *@import("../sdk.zig").Ctx, operation: []const u8, unit: Unit) void {
            std.debug.assert(operation.len > 0);

            var api: @import("../sdk/plugin/context.zig").HostApi = .{
                .inner = inner,
            };

            keep(api.ctx(), operation, unit);
        }
    };
}

fn keep_nothing(ctx: *Ctx, operation: []const u8, unit: Unit) void {
    _ = ctx;
    std.debug.assert(operation.len > 0);
    std.debug.assert(unit.key.len > 0);
}
