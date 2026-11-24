//! A compiled-in plugin's hook run in memory of its own (`plugin_memory.zig`), given back
//! as it ends. A hook changes what it is handed by pointer (a `before` hook the input, an
//! `after` hook the answer): what it changed is copied whole to its caller's memory first,
//! and what it left alone is not copied. Only a hook whose changeable values are settled
//! (`moved.settled`) can run so: for one of them, a change always shows in the value's own
//! bytes. Any other hook works in its caller's memory.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const moved = @import("moved.zig");
const operation = @import("operation.zig");
const plugin_memory = @import("plugin_memory.zig");

const Error = operation.Error;

/// What `Middleware.run` takes after its context.
fn Taken(comptime Middleware: type, comptime position: u32) type {
    return @typeInfo(@TypeOf(Middleware.run)).@"fn".param_types[position + 1].?;
}

/// Whether the hook may change what it takes at `position`: a pointer to a value it may
/// write.
fn changes(comptime Middleware: type, comptime position: u32) bool {
    const info = @typeInfo(Taken(Middleware, position));

    return info == .pointer and info.pointer.size == .one and !info.pointer.attrs.@"const";
}

/// Whether everything the hook may change is settled.
pub fn settles(comptime Middleware: type) bool {
    comptime {
        const count = @typeInfo(@TypeOf(Middleware.run)).@"fn".param_types.len - 1;

        std.debug.assert(count <= 8);

        for (0..count) |position| {
            if (changes(Middleware, position)) {
                if (!moved.settled(std.meta.Child(Taken(Middleware, position)))) {
                    return false;
                }
            }
        }

        return true;
    }
}

/// The bytes of everything the hook may change, together.
fn changeable_bytes(comptime Middleware: type) u32 {
    comptime {
        const count = @typeInfo(@TypeOf(Middleware.run)).@"fn".param_types.len - 1;
        var total: u32 = 0;

        std.debug.assert(count <= 8);

        for (0..count) |position| {
            if (changes(Middleware, position)) {
                total += @sizeOf(std.meta.Child(Taken(Middleware, position)));
            }
        }

        return total;
    }
}

/// The hook run on `args` in memory of its own. Whatever it answers, what it changed is in
/// the caller's memory when this returns: a hook that fails may be passed over, and what it
/// had changed by then is still read.
pub fn run(
    ctx: *Ctx,
    comptime Middleware: type,
    wrapped: anytype,
    args: anytype,
) Error!void {
    comptime std.debug.assert(settles(Middleware));
    std.debug.assert(ctx.now_ms >= 0);

    var before: [changeable_bytes(Middleware)]u8 = undefined;
    var at: usize = 0;

    inline for (args, 0..) |arg, position| {
        if (comptime changes(Middleware, position)) {
            const bytes = std.mem.asBytes(arg);

            @memcpy(before[at..][0..bytes.len], bytes);
            at += bytes.len;
        }
    }

    var work: plugin_memory.Work = undefined;

    work.begin(ctx);

    const ran = @call(.auto, Middleware.run, .{wrapped} ++ args);

    work.leave();
    defer work.end();

    if (!work.own()) {
        return ran;
    }

    at = 0;

    inline for (args, 0..) |arg, position| {
        if (comptime changes(Middleware, position)) {
            const Value = std.meta.Child(Taken(Middleware, position));
            const bytes = std.mem.asBytes(arg);

            if (!std.mem.eql(u8, before[at..][0..bytes.len], bytes)) {
                arg.* = try moved.copy(Value, ctx.arena, arg.*);
            }

            at += bytes.len;
        }
    }

    return ran;
}

test "a hook's changeable values decide whether it can work in memory of its own" {
    const Input = struct {
        title: []const u8,
        tags: []const []const u8,
    };
    const Open = struct {
        rows: []u32,
    };
    const Reading = struct {
        pub fn run(_: *Ctx, _: *const Open, _: *Input) Error!void {}
    };
    const Writing = struct {
        pub fn run(_: *Ctx, _: *Open) Error!void {}
    };
    const Told = struct {
        pub fn run(_: *Ctx, _: []const u8, _: u32) Error!void {}
    };

    try std.testing.expect(comptime settles(Reading));
    try std.testing.expect(comptime !settles(Writing));
    try std.testing.expect(comptime settles(Told));
    try std.testing.expectEqual(@as(u32, @sizeOf(Input)), comptime changeable_bytes(Reading));
    try std.testing.expectEqual(@as(u32, 0), comptime changeable_bytes(Told));
}
