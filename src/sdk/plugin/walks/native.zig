//! A compiled-in plugin's walks (`../walks.zig`): each page and each turn a piece of work
//! (`Work`) over the plugins' memory, kept on core's context so it stays where it began
//! until it ends.
const std = @import("std");
const Ctx = @import("../../context.zig").Ctx;
const Work = @import("../../plugin_memory/work.zig").Work;
const walks = @import("../walks.zig");

const Handle = walks.Handle;

pub const Slot = struct {
    page: Work = undefined,
    turn: Work = undefined,
    page_open: bool = false,
    turn_open: bool = false,
    number: u32 = 0,
};

pub const Stack = struct {
    slots: [walks.depth_max]Slot = @splat(.{}),
    len: u32 = 0,
    /// Walks opened so far: the next one's number.
    opened: u32 = 0,
};

pub fn open(ctx: *Ctx) error{Invalid}!Handle {
    const stack = &ctx.walks;

    std.debug.assert(stack.len <= walks.depth_max);

    if (stack.len == walks.depth_max) {
        return error.Invalid;
    }

    const index = stack.len;

    stack.opened +%= 1;
    stack.opened = @max(stack.opened, 1);
    stack.slots[index] = .{
        .number = stack.opened,
    };
    stack.len += 1;

    return .{
        .index = index,
        .number = stack.opened,
    };
}

pub fn alive(ctx: *const Ctx, handle: Handle) bool {
    const stack = &ctx.walks;

    std.debug.assert(handle.index < walks.depth_max);

    return handle.index < stack.len and stack.slots[handle.index].number == handle.number;
}

pub fn page_begin(ctx: *Ctx, handle: Handle) void {
    const slot = &ctx.walks.slots[handle.index];

    std.debug.assert(!slot.turn_open);

    if (slot.page_open) {
        slot.page.end();
    }

    slot.page.begin(ctx);
    slot.page_open = true;
}

pub fn page_leave(ctx: *Ctx, handle: Handle) void {
    const slot = &ctx.walks.slots[handle.index];

    std.debug.assert(slot.page_open);

    slot.page.leave();
}

pub fn turn_begin(ctx: *Ctx, handle: Handle) void {
    const slot = &ctx.walks.slots[handle.index];

    std.debug.assert(!slot.turn_open);
    std.debug.assert(ctx.walks.len == handle.index + 1);

    slot.turn.begin(ctx);
    slot.turn_open = true;
}

pub fn turn_end(ctx: *Ctx, handle: Handle) void {
    const slot = &ctx.walks.slots[handle.index];

    std.debug.assert(handle.index < ctx.walks.len);

    if (slot.turn_open) {
        slot.turn_open = false;
        slot.turn.end();
    }
}

/// Every walk above the first `mark` back to the memory it began in, innermost first:
/// what a piece of work does before it leaves its own memory.
pub fn leave_above(ctx: *Ctx, mark: u32) void {
    const stack = &ctx.walks;
    var index = stack.len;

    std.debug.assert(stack.len <= walks.depth_max);

    while (index > mark) {
        index -= 1;

        const slot = &stack.slots[index];

        if (slot.turn_open) {
            slot.turn.leave();
        }
    }
}

/// Every walk above the first `mark` given back, innermost first. Each is taken off the
/// stack before its memory goes, so its own pieces of work find nothing left to end.
pub fn end_above(ctx: *Ctx, mark: u32) void {
    const stack = &ctx.walks;

    std.debug.assert(stack.len <= walks.depth_max);

    leave_above(ctx, mark);

    while (stack.len > mark) {
        stack.len -= 1;

        const slot = &stack.slots[stack.len];

        if (slot.turn_open) {
            slot.turn_open = false;
            slot.turn.end();
        }

        if (slot.page_open) {
            slot.page_open = false;
            slot.page.end();
        }

        slot.number = 0;
    }
}
