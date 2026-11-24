//! The walks a plugin has open (`publr.Rows`), innermost last. A walk holds two pieces of
//! memory: its page (the rows read at once) and its turn (what the plugin does with one
//! row). Each piece of work and each scope remembers how many walks were open when it began
//! and, when it ends, gives back the walks opened inside it that are still open: a loop
//! left with `break` or `return` holds its page only until the work around it ends.
const std = @import("std");
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
    return if (comptime guest.mode == .native) native.open(ctx.inner) else sandboxed.open();
}

/// Whether `handle` is still open: not given back with the work around it.
pub fn alive(ctx: *PluginCtx, handle: Handle) bool {
    std.debug.assert(handle.number > 0);

    return if (comptime guest.mode == .native)
        native.alive(ctx.inner, handle)
    else
        sandboxed.alive(handle);
}

/// What the call allocates is the page's from here to `page_leave`; the page given before,
/// with all it held, is given back first.
pub fn page_begin(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.page_begin(ctx.inner, handle);
    } else {
        sandboxed.page_begin(ctx, handle);
    }
}

pub fn page_leave(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.page_leave(ctx.inner, handle);
    } else {
        sandboxed.page_leave(ctx, handle);
    }
}

/// What the call allocates is the turn's until `turn_end` gives it back.
pub fn turn_begin(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.turn_begin(ctx.inner, handle);
    } else {
        sandboxed.turn_begin(ctx, handle);
    }
}

/// The turn given back, and every walk opened inside it.
pub fn turn_end(ctx: *PluginCtx, handle: Handle) void {
    std.debug.assert(alive(ctx, handle));

    if (comptime guest.mode == .native) {
        native.turn_end(ctx.inner, handle);
    } else {
        sandboxed.turn_end(ctx, handle);
    }
}

/// The walk given back, with every walk opened inside it.
pub fn close(ctx: *PluginCtx, handle: Handle) void {
    if (!alive(ctx, handle)) {
        return;
    }

    if (comptime guest.mode == .native) {
        native.end_above(ctx.inner, handle.index);
    } else {
        sandboxed.end_above(ctx, handle.index);
    }

    std.debug.assert(!alive(ctx, handle));
}
