//! The walks a plugin has open (`publr.Rows`), innermost last. A walk holds two pieces of
//! memory: its page (the rows read at once) and its turn (what the plugin does with one
//! row). Each piece of work and each scope remembers how many walks were open when it began
//! and, when it ends, gives back the walks opened inside it that are still open: a loop
//! left with `break` or `return` holds its page only until the work around it ends.
const std = @import("std");
const host_of = @import("context.zig").host_of;
const behind_of = @import("context.zig").behind_of;
const guest = @import("guest.zig");
const PluginCtx = @import("context.zig").PluginCtx;

/// Walks open at once in one plugin call: as deep as calls through plugins may nest.
pub const depth_max: u32 = 8;

/// One open walk: its place on the stack, and the number it was opened with, so a walk
/// given back with the work around it is never taken for a later one.
pub const Handle = struct {
    index: u32,
    number: u32,
};

const native = if (guest.mode == .native) @import("walks/native.zig") else void;
const sandboxed = if (guest.mode == .sandboxed) @import("walks/guest.zig") else void;

/// A new walk, innermost; refused past `depth_max` walks open at once.
pub fn open(ctx: *PluginCtx) error{Invalid}!Handle {
    if (comptime guest.mode == .sandboxed) {
        return sandboxed.open();
    }

    return native.open(host_of(ctx).inner);
}

/// Whether `handle` is still open: not given back with the work around it.
pub fn alive(ctx: *PluginCtx, handle: Handle) bool {
    std.debug.assert(handle.number > 0);

    return if (comptime guest.mode == .native)
        native.alive(host_of(ctx).inner, handle)
    else
        sandboxed.alive(handle);
}

/// What the call allocates is the page's from here to `page_leave`; the page given before,
/// with all it held, is given back first.
pub fn page_begin(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.page_begin(host_of(ctx).inner, handle);
    } else {
        sandboxed.page_begin(behind_of(ctx), handle);
    }
}

pub fn page_leave(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.page_leave(host_of(ctx).inner, handle);
    } else {
        sandboxed.page_leave(behind_of(ctx), handle);
    }
}

/// What the call allocates is the turn's until `turn_end` gives it back.
pub fn turn_begin(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.turn_begin(host_of(ctx).inner, handle);
    } else {
        sandboxed.turn_begin(behind_of(ctx), handle);
    }
}

/// The turn given back, and every walk opened inside it.
pub fn turn_end(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.turn_end(host_of(ctx).inner, handle);
    } else {
        sandboxed.turn_end(behind_of(ctx), handle);
    }
}

/// The walk given back, with every walk opened inside it.
pub fn close(ctx: *PluginCtx, handle: Handle) void {
    if (!alive(ctx, handle)) {
        return;
    }

    if (comptime guest.mode == .native) {
        native.end_above(host_of(ctx).inner, handle.index);
    } else {
        sandboxed.end_above(behind_of(ctx), handle.index);
    }

    std.debug.assert(!alive(ctx, handle));
}
