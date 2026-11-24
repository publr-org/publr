//! An installed plugin's walks (`../walks.zig`): each page and each turn an arena of its own
//! over the module's free pages. The stack is the module's: a call that ends gives back the
//! walks its plugin left open (`end_above` with no context), its context gone by then.
const std = @import("std");
const guest_memory = @import("../guest_memory.zig");
const walks = @import("../walks.zig");
const SandboxApi = @import("../guest.zig").SandboxApi;

const Arena = guest_memory.Arena;
const Handle = walks.Handle;

const Part = struct {
    memory: Arena = undefined,
    /// The memory the call had before this part: what leaving it gives back.
    outer: std.mem.Allocator = undefined,
    open: bool = false,
    inside: bool = false,

    fn begin(part: *Part, api: *SandboxApi) void {
        std.debug.assert(!part.open);

        part.* = .{
            .memory = guest_memory.arena(),
            .outer = api.arena_allocator,
            .open = true,
            .inside = true,
        };
        api.arena_allocator = part.memory.allocator();
    }

    fn leave(part: *Part, api: *SandboxApi) void {
        if (!part.inside) {
            return;
        }

        // Parts nest: what began inside this one has been left.
        std.debug.assert(api.arena_allocator.ptr == @as(*anyopaque, &part.memory));

        part.inside = false;
        api.arena_allocator = part.outer;
    }

    /// Its memory given back; with no context, the call it was in has ended and with it
    /// what remembered reads in it.
    fn end(part: *Part, api: ?*SandboxApi) void {
        std.debug.assert(part.open or !part.inside);

        if (!part.open) {
            return;
        }

        if (api) |held| {
            part.leave(held);

            if (held.memo) |memo| {
                memo.drop(&part.memory);
            }
        }

        part.memory.poison();
        part.memory.deinit();
        part.open = false;
        part.inside = false;
    }
};

const Slot = struct {
    page: Part = .{},
    turn: Part = .{},
    number: u32 = 0,
};

const Stack = struct {
    slots: [walks.depth_max]Slot = @splat(.{}),
    len: u32 = 0,
    opened: u32 = 0,
};

// A wasm module is one instance behind a C ABI: its calls share one stack of walks.
var stack: Stack = .{};

/// How many walks are open: what a call or a scope remembers as it begins.
pub fn depth() u32 {
    std.debug.assert(stack.len <= walks.depth_max);

    return stack.len;
}

pub fn open() error{Invalid}!Handle {
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

pub fn alive(handle: Handle) bool {
    std.debug.assert(handle.index < walks.depth_max);

    return handle.index < stack.len and stack.slots[handle.index].number == handle.number;
}

pub fn page_begin(api: *SandboxApi, handle: Handle) void {
    const slot = &stack.slots[handle.index];

    std.debug.assert(!slot.turn.open);

    slot.page.end(api);
    slot.page.begin(api);
}

pub fn page_leave(api: *SandboxApi, handle: Handle) void {
    const slot = &stack.slots[handle.index];

    std.debug.assert(slot.page.open);

    slot.page.leave(api);
}

pub fn turn_begin(api: *SandboxApi, handle: Handle) void {
    const slot = &stack.slots[handle.index];

    std.debug.assert(stack.len == handle.index + 1);

    slot.turn.begin(api);
}

/// The turn given back, with every walk opened inside it.
pub fn turn_end(api: *SandboxApi, handle: Handle) void {
    std.debug.assert(handle.index < stack.len);

    end_above(api, handle.index + 1);
    stack.slots[handle.index].turn.end(api);
}

/// Every walk above the first `mark` back to the memory it began in, innermost first:
/// what a scope does before it leaves its own memory.
pub fn leave_above(api: *SandboxApi, mark: u32) void {
    var index = stack.len;

    std.debug.assert(stack.len <= walks.depth_max);

    while (index > mark) {
        index -= 1;
        stack.slots[index].turn.leave(api);
    }
}

/// Every walk above the first `mark` given back, innermost first.
pub fn end_above(api: ?*SandboxApi, mark: u32) void {
    std.debug.assert(stack.len <= walks.depth_max);

    if (api) |held| {
        leave_above(held, mark);
    }

    while (stack.len > mark) {
        stack.len -= 1;

        const slot = &stack.slots[stack.len];

        slot.turn.end(api);
        slot.page.end(api);
        slot.number = 0;
    }
}
