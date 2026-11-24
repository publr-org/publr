//! A sandboxed plugin's memory. `std.heap.wasm_allocator` rounds every request up to a power
//! of two and never joins or splits what was freed, which takes four to seven times a growing
//! buffer's size; here what is asked is taken in whole pages, exactly as many as needed, from
//! one list of free runs (`guest_memory/runs.zig`). `heap` is the plugin's general allocator
//! and `Arena` one call's memory.

const std = @import("std");
const arena_module = @import("guest_memory/arena.zig");
const heap_module = @import("guest_memory/heap.zig");
const runs_module = @import("guest_memory/runs.zig");

/// The module's linear memory, which starts at address zero.
const Linear = struct {
    pub fn base_address(_: Linear) u64 {
        return 0;
    }

    pub fn pages(_: Linear) u32 {
        return @intCast(@wasmMemorySize(0));
    }

    pub fn grow(_: Linear, more: u32) bool {
        return @wasmMemoryGrow(0, more) != -1;
    }
};

// A wasm module is one instance behind a C ABI: its exports share the free pages between calls.
var free_runs: runs_module.Runs(Linear) = .{
    .memory = .{},
};

const heap_state: heap_module.Heap(Linear) = .{
    .runs = &free_runs,
    .small = std.heap.wasm_allocator,
};

pub const heap: std.mem.Allocator = heap_state.allocator();

pub const Arena = arena_module.Arena(Linear);

/// One call's memory, holding nothing yet.
pub fn arena() Arena {
    return .{
        .runs = &free_runs,
    };
}
