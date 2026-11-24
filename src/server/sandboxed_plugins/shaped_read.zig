//! What a plugin's call says about itself, copied out of its memory and checked before it
//! is used: its description, the unions beside its value, a text. Nothing here trusts a
//! length or an address: every one is bounded and read through the plugin's own memory.
const std = @import("std");
const wasm = @import("publr_wasm");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");

const Described = described_module.Described;
const Given = given_module.Given;

const gpa = std.heap.c_allocator;

/// How long an operation's name may be, and how many unions beside the block a value may
/// have.
pub const name_bytes_max: u32 = 256;
const table_entries_max: u32 = 1 << 18;

/// A description copied out of the plugin and checked.
pub fn description(
    env: *wasm.Env,
    arena: std.mem.Allocator,
    ptr: u32,
    len: u32,
) given_module.Error!Described {
    if (len == 0 or len > described_module.text_bytes_max) {
        return error.Invalid;
    }

    std.debug.assert(len <= described_module.text_bytes_max);

    return described_module.parse(arena, try copy(env, arena, ptr, len));
}

/// The side table's entries copied out of the plugin; what each points at is checked when
/// it is read.
pub fn table_of(
    env: *wasm.Env,
    arena: std.mem.Allocator,
    ptr: u32,
    count: u32,
) given_module.Error![]const shape_wire.Entry {
    if (count > table_entries_max) {
        return error.Invalid;
    }

    const table = arena.alloc(shape_wire.Entry, count) catch return error.OutOfMemory;

    std.debug.assert(table.len == count);

    if (count > 0 and !env.read(ptr, std.mem.sliceAsBytes(table))) {
        return error.Invalid;
    }

    return table;
}

pub fn copy(
    env: *wasm.Env,
    arena: std.mem.Allocator,
    ptr: u32,
    len: u32,
) given_module.Error![]const u8 {
    std.debug.assert(len > 0);
    std.debug.assert(len <= described_module.text_bytes_max);

    const copied = arena.alloc(u8, len) catch return error.OutOfMemory;

    // Read, never borrowed: in the browser a guest's memory is not the host's.
    if (!env.read(ptr, copied)) {
        return error.Invalid;
    }

    return copied;
}

/// A value a plugin handed over under a name with no answer (`shape_wire.Sent`), as the JSON
/// core keeps it as: an event's payload, a queued job's input.
pub const SentJson = struct {
    name: []const u8,
    json: []const u8,
    due_ms: i64,
};

/// The value at `sent_ptr` read where it lies and written as JSON, in `arena`.
pub fn sent_json(
    env: *wasm.Env,
    arena: std.mem.Allocator,
    sent_ptr: u32,
) given_module.Error!SentJson {
    var parts: shape_wire.Sent = undefined;
    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    const memory = working.allocator();

    if (!env.read(sent_ptr, std.mem.asBytes(&parts))) {
        return error.Invalid;
    }

    if (parts.name_len == 0 or parts.name_len > name_bytes_max) {
        return error.Invalid;
    }

    const name = try copy(env, arena, parts.name, parts.name_len);
    const described = try description(env, memory, parts.asked, parts.asked_len);
    var given: Given = .{
        .described = &described,
        .memory = .{
            .guest = env,
        },
        .arena = memory,
        .table = try table_of(env, memory, parts.table, parts.table_len),
    };
    const window = try given.window(Described.root, parts.root);
    const written = try given.json_of(Described.root, window, .null);

    std.debug.assert(written.len > 0);

    return .{
        .name = name,
        .json = arena.dupe(u8, written) catch return error.OutOfMemory,
        .due_ms = parts.due_ms,
    };
}
