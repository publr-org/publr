//! One of a plugin's entries (an operation, a hook, a modifier) run with its envelope laid
//! out in the plugin's own layout, which the plugin describes (`publr_shape`); its answer
//! comes back through `publr_answer` (`shaped_call.zig`). What another plugin handed over is
//! moved into this one's layout as it is (`transfer.zig`), with no JSON in between; what
//! core holds as JSON (from the outer edge, from storage) is read once.
const std = @import("std");
const wasm = @import("publr_wasm");
const wire = @import("../../sdk/plugin/wire.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const invoke = @import("invoke.zig");
const described_module = @import("described.zig");
const laid_module = @import("laid.zig");
const laid_typed = @import("laid_typed.zig");
const given_typed = @import("given_typed.zig");
const held_module = @import("held.zig");
const transfer = @import("transfer.zig");

const Passed = @import("../../sdk/sandboxed_plugins.zig").Passed;

const gpa = std.heap.c_allocator;

/// How many instructions the module's own small exports (its allocator, its descriptions) may
/// take, as for its result cell.
pub const steps: u31 = 100_000;

/// Runs entry `entry` with its envelope laid out in the plugin's own layout, which the
/// plugin says (`publr_shape`). A plugin that does not say, or whose layout cannot hold what
/// the entry is given, is not run.
pub fn run(
    invocation: *invoke.Invocation,
    instance: *wasm.Instance,
    entry: u32,
    head: *const invoke.Head,
    parts: invoke.Parts,
    budget: u31,
) invoke.RunError!Passed {
    const ctx = invocation.ctx;
    const loaded = invocation.loaded;
    var problem: wasm.Problem = .{};

    std.debug.assert(parts.in.bytes().len > 0);

    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    var laid: laid_module.Laid = .{};

    try lay(loaded, instance, working.allocator(), entry, head, parts, &laid);

    const block_len: u32 = @intCast(laid.block.items.len);
    const table_bytes: u32 = @intCast(laid.table.items.len * @sizeOf(shape_wire.Entry));
    const total = block_len + table_bytes + 16;
    const raw = try invoke.call_guest(instance, "publr_alloc", &.{total}, steps, &problem, .{});

    // No room left in the plugin's memory for what the entry is given: the next call gets
    // a fresh instance.
    if (raw == 0) {
        loaded.spoil();

        return error.OutOfMemory;
    }

    // An instance its call spoiled runs nothing more, not even its allocator.
    defer if (!loaded.spoiled) {
        free(instance, raw, total);
    };

    const base: u32 = std.mem.alignForward(u32, raw, 16);
    const table_at = base + block_len;

    laid.place(base);

    const written = instance.write(base, laid.block.items) and
        instance.write(table_at, std.mem.sliceAsBytes(laid.table.items));

    if (!written) {
        return error.Trap;
    }

    if (invocation.answer) |left| {
        gpa.free(left);
        invocation.answer = null;
    }

    const status = invoke.call_guest(instance, "publr_invoke_shaped", &.{
        entry,
        base,
        table_at,
        @intCast(laid.table.items.len),
    }, budget, &problem, .{
        .user_data = invocation,
    }) catch |err| {
        std.log.warn("plugin {s}: {s}", .{ loaded.name(), problem.text() });

        if (err == error.Trap or err == error.Exhausted) {
            loaded.spoil();
        }

        return err;
    };

    if (status != wire.ok) {
        return wire.error_of(status);
    }

    const answered = invocation.answer orelse return .{
        .json = "{}",
    };

    defer {
        gpa.free(answered);
        invocation.answer = null;
    }

    return .{
        .laid = ctx.arena.dupe(u8, answered) catch return error.OutOfMemory,
    };
}

/// Entry `entry`'s envelope for `parts` built in `memory`, in the plugin's own layout, not
/// yet placed in its memory.
pub fn lay(
    loaded: *invoke.Loaded,
    instance: *wasm.Instance,
    memory: std.mem.Allocator,
    entry: u32,
    head: *const invoke.Head,
    parts: invoke.Parts,
    laid: *laid_module.Laid,
) invoke.RunError!void {
    const described = try described_kept(loaded, instance, entry);
    var layout: laid_module.Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = described,
        .laid = laid,
    };

    std.debug.assert(parts.in.bytes().len > 0);
    std.debug.assert(laid.block.items.len == 0);

    try build(&layout, head, parts);
}

/// The envelope built in the plugin's layout: each field it describes, in its order, from
/// what the call is (`head`), what the entry is given (`in`) and, for an `after` hook, what
/// the operation answered (`out`).
fn build(
    layout: *laid_module.Layout,
    head: *const invoke.Head,
    parts: invoke.Parts,
) laid_module.Error!void {
    const described = layout.described;
    const root = described_module.Described.root;

    if (described.nodes[root].kind != .object) {
        return error.Invalid;
    }

    try layout.begin();

    for (described.fields_of(root)) |field| {
        const at = field.offset;

        if (std.mem.eql(u8, field.name, "in")) {
            try place(layout, field.node, at, parts.in);
        } else if (std.mem.eql(u8, field.name, "out") and parts.out != null) {
            try place(layout, field.node, at, parts.out.?);
        } else if (given_typed.index_of(invoke.Head, field.name, 0)) |index| {
            inline for (@typeInfo(invoke.Head).@"struct".field_names, 0..) |name, own| {
                if (index == own) {
                    const Field = @FieldType(invoke.Head, name);

                    try laid_typed.lay(Field, layout, field.node, &@field(head.*, name), at);
                }
            }
        } else {
            try layout.left_out(field, at);
        }
    }
}

/// `passed` built at `at` as `node` says: moved from the layout another plugin handed it
/// over in, or read from JSON.
fn place(
    layout: *laid_module.Layout,
    node: u32,
    at: u32,
    passed: Passed,
) laid_module.Error!void {
    const scratch = layout.scratch;

    std.debug.assert(passed.bytes().len > 0);

    switch (passed) {
        .json => |text| {
            const tree = std.json.parseFromSliceLeaky(std.json.Value, scratch, text, .{}) catch {
                return error.Invalid;
            };

            try layout.write(node, tree, at);
        },
        .laid => |piece| {
            const held = try held_module.open(scratch, piece);
            var reading = held.given(scratch);
            const window = try held.window(&reading);

            try transfer.move(layout, node, at, &reading, described_module.Described.root, window);
        },
    }
}

/// How the plugin lays entry `entry`'s envelope out, read from its module the first time
/// the entry runs and kept beside it: the module says the same every time.
pub fn described_kept(
    loaded: *invoke.Loaded,
    instance: *wasm.Instance,
    entry: u32,
) invoke.RunError!*const described_module.Described {
    const manifest = &loaded.manifest;
    const entries = manifest.operations.len + manifest.hooks.len + manifest.jobs.len +
        manifest.location_rules.len * 2 + manifest.field_kinds.len * 3 +
        manifest.dimensions.len;
    const kept = loaded.arena_state.allocator();

    std.debug.assert(entry < entries);
    std.debug.assert(loaded.described.len == 0 or loaded.described.len == entries);

    if (loaded.described.len == 0) {
        loaded.described = try kept.alloc(?described_module.Described, entries);
        @memset(loaded.described, null);
    }

    if (loaded.described[entry] == null) {
        loaded.described[entry] = described_of(instance, kept, loaded.result_offset, entry) orelse {
            return error.Unavailable;
        };
    }

    return &loaded.described[entry].?;
}

/// How the plugin lays entry `entry`'s envelope out, read and checked; null for a plugin
/// that does not say, or whose description is not one.
fn described_of(
    instance: *wasm.Instance,
    arena: std.mem.Allocator,
    result_offset: u32,
    entry: u32,
) ?described_module.Described {
    var problem: wasm.Problem = .{};
    const asked = [_]u32{ entry, 0, result_offset };
    const status = invoke.call_guest(instance, "publr_shape", &asked, steps, &problem, .{}) catch {
        return null;
    };
    var cell: [wire.result_bytes]u8 = undefined;

    std.debug.assert(result_offset != 0);

    if (status != wire.ok or !instance.read(result_offset, &cell)) {
        return null;
    }

    const result = std.mem.bytesToValue(wire.Result, &cell);

    if (result.len == 0 or result.len > described_module.text_bytes_max) {
        return null;
    }

    const copied = arena.alloc(u8, result.len) catch return null;

    if (!instance.read(result.ptr, copied)) {
        return null;
    }

    return described_module.parse(arena, copied) catch null;
}

/// The room the envelope took, given back; a guest that cannot take it back is logged.
pub fn free(instance: *wasm.Instance, raw: u32, total: u32) void {
    var problem: wasm.Problem = .{};

    std.debug.assert(raw != 0);
    std.debug.assert(total > 0);

    const given = [_]u32{ raw, total };

    _ = invoke.call_guest(instance, "publr_free", &given, steps, &problem, .{}) catch |err| {
        std.log.warn("plugin: the envelope was not given back: {t}", .{err});
    };
}
