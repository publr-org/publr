//! One of a plugin's hooks run once for many items in one call into its module: where core
//! fires the same hook for every record of a bulk write, the plugin is entered once and
//! runs the hook for each envelope in turn (`publr_invoke_batch`), telling the host how
//! each ended (`publr_item`) before the next begins. A module built before batches has no
//! such export: its hook is run item by item.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const invoke = @import("invoke.zig");
const laid_module = @import("laid.zig");
const shaped_entry = @import("shaped_entry.zig");

const Passed = sdk.sandboxed_plugins.Passed;
const Outcome = sdk.sandboxed_plugins.Outcome;

const gpa = std.heap.c_allocator;

/// The most items one call into a module runs: a longer batch is run in parts.
pub const items_max: u32 = 256;

/// What the host keeps of a batch while it runs.
pub const Batch = struct {
    ended: []Ended,

    /// How one item ended, as the plugin said: its status, the answer it handed back (the
    /// host's own copy, freed by whoever reads it) and its refusal's words.
    pub const Ended = struct {
        said: bool = false,
        status: u32 = 0,
        answer: ?[]u8 = null,
        message: []const u8 = "",
    };
};

/// `publr_item(index, status)`: the run of envelope `index` of the batch ended with `status`.
/// What it answered and the words of its refusal are set beside it; the next run starts with
/// neither. An index outside the batch, or said twice, is ignored.
pub fn publr_item(env: *wasm.Env, index: u32, status: u32) callconv(.c) void {
    const invocation = invoke.invocation_of(env) orelse return;
    const batch = invocation.batch orelse return;
    const ctx = invocation.ctx;

    std.debug.assert(batch.ended.len <= items_max);

    if (index >= batch.ended.len or batch.ended[index].said) {
        return;
    }

    const failure = ctx.failure;

    batch.ended[index] = .{
        .said = true,
        .status = status,
        .answer = invocation.answer,
        .message = if (failure) |own| own.message else problems_said(ctx),
    };
    invocation.answer = null;
    ctx.failure = null;
    // The problems one item's `.validate` found are that item's: the next starts with none.
    ctx.problems = &.{};
}

/// The problems the item's run found (`problems.add`), as its refusal's words: each
/// `field: message`, one after the other. Empty when it found none.
fn problems_said(ctx: *sdk.Ctx) []const u8 {
    std.debug.assert(ctx.problems.len <= sdk.operation.problems_max);

    if (ctx.problems.len == 0) {
        return "";
    }

    var said: std.ArrayList(u8) = .empty;

    for (ctx.problems, 0..) |problem, place| {
        const text = std.fmt.allocPrint(ctx.arena, "{s}{s}: {s}", .{
            if (place > 0) "; " else "",
            problem.field,
            problem.message,
        }) catch return "";

        said.appendSlice(ctx.arena, text) catch return "";
    }

    return said.items;
}

/// Runs entry `entry` once for each of `parts` in one call into the module, `outcomes`
/// taking how each ended. A trap or an exhausted budget ends the call: the items it did not
/// reach end `Unavailable`.
pub fn run(
    invocation: *invoke.Invocation,
    instance: *wasm.Instance,
    entry: u32,
    head: *const invoke.Head,
    parts: []const invoke.Parts,
    outcomes: []Outcome,
) invoke.RunError!void {
    const loaded = invocation.loaded;

    std.debug.assert(parts.len > 0 and parts.len <= items_max);
    std.debug.assert(parts.len == outcomes.len);

    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    const memory = working.allocator();
    const ended = try memory.alloc(Batch.Ended, parts.len);
    var batch: Batch = .{
        .ended = ended,
    };

    @memset(ended, .{});
    defer for (ended) |one| {
        if (one.answer) |left| {
            gpa.free(left);
        }
    };

    const laid = try memory.alloc(laid_module.Laid, parts.len);

    for (parts, laid) |one, *envelope| {
        envelope.* = .{};
        try shaped_entry.lay(loaded, instance, memory, entry, head, one, envelope);
    }

    invocation.batch = &batch;
    defer invocation.batch = null;

    const called = call(invocation, instance, entry, laid);

    for (ended, outcomes) |*one, *outcome| {
        outcome.* = try outcome_of(invocation.ctx, one, called);
    }

    // No such export: the module was built before batches. Nothing ran.
    if (called == error.NotFound) {
        return error.NotFound;
    }
}

/// How an item ended, for its caller: its answer in the call's memory, or its error and the
/// words it refused with.
fn outcome_of(ctx: *sdk.Ctx, ended: *const Batch.Ended, called: wasm.Error!void) sdk.Error!Outcome {
    std.debug.assert(ended.said or ended.answer == null);

    if (!ended.said) {
        called catch |err| {
            return .{
                .failed = if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable,
            };
        };

        return .{
            .failed = error.Unavailable,
        };
    }

    if (ended.status != wire.ok) {
        return .{
            .failed = wire.error_of(ended.status),
            .message = try ctx.arena.dupe(u8, ended.message),
        };
    }

    const answered = ended.answer orelse return .{
        .passed = .{
            .json = "{}",
        },
    };

    return .{
        .passed = .{
            .laid = try ctx.arena.dupe(u8, answered),
        },
    };
}

/// The envelopes written into the module's memory, one after the other, then where each
/// lies; the entry run over them in one call, on the budget of as many calls.
fn call(
    invocation: *invoke.Invocation,
    instance: *wasm.Instance,
    entry: u32,
    laid: []laid_module.Laid,
) wasm.Error!void {
    const loaded = invocation.loaded;
    var problem: wasm.Problem = .{};
    var total: u64 = laid.len * @sizeOf(shape_wire.Item) + 16;

    std.debug.assert(laid.len > 0 and laid.len <= items_max);

    for (laid) |*one| {
        total += one.block.items.len + one.table.items.len * @sizeOf(shape_wire.Entry) + 16;
    }

    if (total > laid_module.block_bytes_max) {
        return error.OutOfMemory;
    }

    const sized: u32 = @intCast(total);
    const raw = try instance.call("publr_alloc", &.{sized}, shaped_entry.steps, &problem, .{});

    // No room left in the plugin's memory for the batch: the next call gets a fresh instance.
    if (raw == 0) {
        loaded.spoil();

        return error.OutOfMemory;
    }

    defer if (!loaded.spoiled) {
        shaped_entry.free(instance, raw, sized);
    };

    var items: [items_max]shape_wire.Item = undefined;
    var at: u32 = std.mem.alignForward(u32, raw, 16);

    for (laid, items[0..laid.len]) |*one, *item| {
        const block_len: u32 = @intCast(one.block.items.len);
        const table = std.mem.sliceAsBytes(one.table.items);

        one.place(at);
        item.* = .{
            .block = at,
            .table = at + block_len,
            .count = @intCast(one.table.items.len),
        };

        if (!instance.write(at, one.block.items) or !instance.write(at + block_len, table)) {
            return error.Trap;
        }

        at = std.mem.alignForward(u32, at + block_len + @as(u32, @intCast(table.len)), 16);
    }

    if (!instance.write(at, std.mem.sliceAsBytes(items[0..laid.len]))) {
        return error.Trap;
    }

    // As many items as there were calls before: the budget of as many.
    const budget = @as(u64, loaded.instructions_max()) * laid.len;
    const count: u32 = @intCast(laid.len);

    const calls = @as(u64, loaded.limits.calls) * count;

    invocation.calls_left = @intCast(@min(calls, std.math.maxInt(u32)));

    _ = instance.call("publr_invoke_batch", &.{ entry, at, count }, @intCast(
        @min(budget, std.math.maxInt(u31)),
    ), &problem, .{
        .user_data = invocation,
    }) catch |err| {
        if (err == error.Trap or err == error.Exhausted) {
            std.log.warn("plugin {s}: {s}", .{ loaded.name(), problem.text() });
            loaded.spoil();
        }

        return err;
    };
}
