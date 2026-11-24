//! An answer on its way into a plugin, and one on its way out. What core answers a plugin's
//! call is laid out at address 0 and waits here for the room the plugin makes for it
//! (`publr_shaped_take`); what a plugin's entry answers is copied whole out of its memory
//! while it is still there (`publr_answer`).
const std = @import("std");
const wasm = @import("publr_wasm");
const wire = @import("../../sdk/plugin/wire.zig");
const invoke = @import("invoke.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const laid_module = @import("laid.zig");
const laid_typed = @import("laid_typed.zig");
const held_module = @import("held.zig");
const shaped_read = @import("shaped_read.zig");

const Described = described_module.Described;
const Given = given_module.Given;
const Laid = laid_module.Laid;

const description = shaped_read.description;
const table_of = shaped_read.table_of;

/// What holds an answer between the call and the plugin taking it.
const gpa = std.heap.c_allocator;

/// An answer laid out at address 0, held in the server's memory until the plugin takes it.
pub const Pending = struct {
    laid: Laid,

    pub fn deinit(pending: *Pending) void {
        std.debug.assert(pending.laid.block.items.len > 0);

        pending.laid.deinit(gpa);
        pending.* = undefined;
    }
};

/// `publr_shaped_take(block, table)`: the waiting answer written at `block`, its side table
/// at `table`, each address in it moved there.
pub fn publr_shaped_take(env: *wasm.Env, block_ptr: u32, table_ptr: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse return wire.code_of(error.Unavailable);
    var pending = invocation.pending orelse return wire.code_of(error.Invalid);

    std.debug.assert(pending.laid.block.items.len > 0);

    invocation.pending = null;
    defer pending.deinit();

    if (block_ptr == 0) {
        return wire.code_of(error.Invalid);
    }

    pending.laid.place(block_ptr);

    const table_bytes = std.mem.sliceAsBytes(pending.laid.table.items);

    if (!env.write(block_ptr, pending.laid.block.items)) {
        return wire.code_of(error.Invalid);
    }

    if (table_bytes.len > 0 and !env.write(table_ptr, table_bytes)) {
        return wire.code_of(error.Invalid);
    }

    return wire.ok;
}

/// The laid-out answer kept past this call; one left untaken is dropped.
pub fn hold(invocation: *invoke.Invocation, laid: *Laid) void {
    std.debug.assert(laid.block.items.len > 0);

    if (invocation.pending) |*left| {
        left.deinit();
    }

    invocation.pending = .{
        .laid = laid.*,
    };
    laid.* = .{};
}

/// One of core's own values laid out as the plugin describes it (the description is at
/// `wanted_ptr` in its memory) and held for `publr_shaped_take`; `sizes_ptr` gets what it
/// takes: what core tells a plugin outside an operation's answer.
pub fn hold_typed(
    comptime Shape: type,
    env: *wasm.Env,
    value: *const Shape,
    wanted: wire.Result,
    sizes_ptr: u32,
) u32 {
    const invocation = invoke.invocation_of(env) orelse return wire.code_of(error.Unavailable);
    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    const memory = working.allocator();
    const described = description(env, memory, wanted.ptr, wanted.len) catch |err| {
        return wire.code_of(err);
    };
    var laid: Laid = .{};
    var layout: laid_module.Layout = .{
        .gpa = gpa,
        .scratch = memory,
        .described = &described,
        .laid = &laid,
    };

    std.debug.assert(invocation.loaded.name().len > 0);

    layout.begin() catch return wire.code_of(error.OutOfMemory);
    laid_typed.lay(Shape, &layout, Described.root, value, 0) catch |err| {
        laid.deinit(gpa);

        return wire.code_of(err);
    };
    hold(invocation, &laid);

    return sizes(env, invocation, sizes_ptr);
}

/// A refusal's name, waiting as the answer's block.
pub fn hold_text(invocation: *invoke.Invocation, text: []const u8) error{OutOfMemory}!void {
    var laid: Laid = .{};
    errdefer laid.deinit(gpa);

    std.debug.assert(text.len > 0);

    try laid.block.appendSlice(gpa, text);
    hold(invocation, &laid);
}

pub fn sizes(env: *wasm.Env, invocation: *invoke.Invocation, sizes_ptr: u32) u32 {
    const pending = invocation.pending orelse return wire.code_of(error.Invalid);
    const told: [2]u32 = .{
        @intCast(pending.laid.block.items.len),
        @intCast(pending.laid.table.items.len),
    };

    std.debug.assert(pending.laid.block.items.len > 0);

    if (!env.write(sizes_ptr, std.mem.asBytes(&told))) {
        return wire.code_of(error.Invalid);
    }

    return wire.ok;
}

/// `publr_answer(description, len, root, table, count)`: an entry's answer, read out of the
/// plugin's own layout while it is still there, kept for the caller.
pub fn publr_answer(
    env: *wasm.Env,
    description_ptr: u32,
    description_len: u32,
    root: u32,
    table_ptr: u32,
    table_len: u32,
) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse return wire.code_of(error.Unavailable);
    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    const memory = working.allocator();
    const described = description(env, memory, description_ptr, description_len) catch |err| {
        return wire.code_of(err);
    };
    const table = table_of(env, memory, table_ptr, table_len) catch |err| {
        return wire.code_of(err);
    };
    var given: Given = .{
        .described = &described,
        .memory = .{
            .guest = env,
        },
        .arena = memory,
        .table = table,
    };

    std.debug.assert(invocation.output_bytes_max > 0);

    // Copied whole while it is still there: the plugin's memory may be working memory given
    // back before its caller reads the answer.
    const piece = held_module.keep(gpa, memory, &given, root) catch |err| {
        return wire.code_of(err);
    };

    if (held_module.value_bytes(piece) > invocation.output_bytes_max) {
        gpa.free(piece);

        return wire.code_of(error.Invalid);
    }

    if (invocation.answer) |left| {
        gpa.free(left);
    }

    invocation.answer = piece;

    return wire.ok;
}
