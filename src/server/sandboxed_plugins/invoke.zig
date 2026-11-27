//! One call into a plugin, and the host functions it may make while it runs. The plugin
//! runs as itself: its calls are dispatched as a plugin caller holding its grants, narrowed
//! to the roles of the account it acts for, within its limits.
const std = @import("std");
const permission_define = @import("../../sdk/plugin/permission_define.zig");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const caller_view = @import("../../sdk/plugin/caller_view.zig");
const job_queue = @import("../../store/job_queue.zig");
const model = @import("../../model.zig");
pub const Loaded = @import("loaded.zig").Loaded;
const HostApi = @import("../../sdk/plugin/context.zig").HostApi;
const shaped_call = @import("shaped_call.zig");
const shaped_entry = @import("shaped_entry.zig");
const said_memory = @import("said_memory.zig");
const drawn = @import("../../ui/drawn.zig");
const call_json = @import("../../sdk/call_json.zig");
const held_module = @import("held.zig");
const batched = @import("batched.zig");
const acting_module = @import("acting.zig");

const Acting = acting_module.Acting;
const head_of = acting_module.head_of;

pub const imports = @import("host_imports.zig").imports;

/// What a host function finds through the call's user data.
pub const Invocation = struct {
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    calls_left: u32,
    output_bytes_max: u32,
    /// What the plugin's view draws with, from its `publr_frame` on.
    drawing: ?*drawn.Drawing = null,
    /// An answer laid out in the plugin's own structs, waiting for the room it makes.
    pending: ?shaped_call.Pending = null,
    /// An entry's answer the plugin handed back in its own layout, kept whole (`held.zig`).
    answer: ?[]u8 = null,
    /// Set while the entry runs over many items in one call (`batched.zig`).
    batch: ?*batched.Batch = null,

    /// What the call left with the host, given back.
    fn deinit(invocation: *Invocation) void {
        std.debug.assert(invocation.output_bytes_max > 0);
        std.debug.assert(invocation.batch == null);

        if (invocation.drawing) |held| {
            held.deinit();
        }

        if (invocation.pending) |*left| {
            left.deinit();
        }

        if (invocation.answer) |left| {
            std.heap.c_allocator.free(left);
        }
    }
};

const Passed = sdk.sandboxed_plugins.Passed;

/// What an entry is run with: its own input, and what only some entries read beside it.
pub const Parts = struct {
    in: Passed,
    /// The operation's answer, for an `after` hook.
    out: ?Passed = null,
    /// Whether a queued job runs its last attempt.
    last: bool = false,
};

pub const Head = acting_module.Head;

/// Runs entry `entry` with `input` (the entry's own JSON) as the plugin, and answers its
/// output as JSON in the context's arena: for what core itself hands over and reads as JSON.
pub fn invoke(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    input: []const u8,
) sdk.Error![]const u8 {
    const answered = try invoke_passed(loaded, ctx, access, entry, .{
        .in = .{
            .json = input,
        },
    });

    std.debug.assert(input.len > 0);

    return json_of(ctx.arena, answered, .answer);
}

/// `passed` as JSON text: as it is when it is JSON already, else written in `arena`.
pub fn json_of(
    arena: std.mem.Allocator,
    passed: Passed,
    form: sdk.sandboxed_plugins.Form,
) sdk.Error![]const u8 {
    std.debug.assert(passed.bytes().len > 0);

    return switch (passed) {
        .json => |text| text,
        .laid => |piece| held_module.json_of(arena, piece, switch (form) {
            .request => .request,
            .answer => .answer,
        }),
    };
}

/// Runs entry `entry` as the plugin with its input as it comes: JSON text, or as another
/// plugin handed it over, which then reaches this one with no JSON in between.
pub fn invoke_passed(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    parts: Parts,
) sdk.Error!Passed {
    std.debug.assert(parts.in.bytes().len > 0);

    // Who is calling is read before the plugin becomes the caller.
    const head = head_of(ctx, parts.last);
    const acting = Acting.begin(loaded, ctx, access, entry);
    defer acting.end();

    var invocation: Invocation = .{
        .loaded = loaded,
        .ctx = ctx,
        .calls_left = loaded.limits.calls,
        .output_bytes_max = loaded.limits.output_kib << 10,
    };
    defer invocation.deinit();

    // An instance a call spoiled takes no other while that call still runs on it.
    if (loaded.spoiled) {
        return error.Unavailable;
    }

    loaded.enter();
    defer loaded.leave();

    // A trap or an exhausted budget spoils the instance: what its memory holds is not
    // trusted again, and the outermost call's end drops it. (Its memory full spoils it where
    // that is found, `shaped_entry.zig`; an `OutOfMemory` it answers after giving its own
    // call's memory back, or passes on from core, does not.)
    return run(&invocation, entry, &head, parts) catch |err| switch (err) {
        error.Load, error.Instantiate, error.Trap, error.Exhausted => {
            loaded.spoil();

            return error.Unavailable;
        },
        error.OutOfMemory => {
            said_memory.out_of_memory(loaded, ctx, entry);

            return error.OutOfMemory;
        },
        else => |other| other,
    };
}

/// Runs entry `entry`, a hook, once for each of `parts`, `outcomes` taking how each ended:
/// in one call into the plugin's module where it takes batches, else one call an item.
pub fn invoke_many(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    parts: []const Parts,
    outcomes: []sdk.sandboxed_plugins.Outcome,
) sdk.Error!void {
    std.debug.assert(parts.len == outcomes.len);
    std.debug.assert(parts.len <= batched.items_max);

    if (parts.len > 1 and try many_at_once(loaded, ctx, access, entry, parts, outcomes)) {
        return;
    }

    for (parts, outcomes) |one, *outcome| {
        ctx.failure = null;

        if (invoke_passed(loaded, ctx, access, entry, one)) |answered| {
            outcome.* = .{
                .passed = answered,
            };
        } else |err| {
            const failure = ctx.failure;

            ctx.failure = null;
            outcome.* = .{
                .failed = err,
                .message = if (failure) |own| own.message else "",
            };
        }
    }
}

/// The batch run in one call into the module; false when it could not be (a module built
/// before batches, an input its layout cannot hold): nothing ran, and each item is run alone.
fn many_at_once(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    parts: []const Parts,
    outcomes: []sdk.sandboxed_plugins.Outcome,
) sdk.Error!bool {
    std.debug.assert(parts.len > 1);

    const head = head_of(ctx, false);
    const acting = Acting.begin(loaded, ctx, access, entry);
    defer acting.end();

    var invocation: Invocation = .{
        .loaded = loaded,
        .ctx = ctx,
        .calls_left = loaded.limits.calls,
        .output_bytes_max = loaded.limits.output_kib << 10,
    };
    defer invocation.deinit();

    if (loaded.spoiled) {
        return false;
    }

    loaded.enter();
    defer loaded.leave();

    const instance = loaded.ensure_instance() catch return false;

    batched.run(&invocation, instance, entry, &head, parts, outcomes) catch |err| {
        if (err == error.OutOfMemory) {
            said_memory.out_of_memory(loaded, ctx, entry);

            return error.OutOfMemory;
        }

        return false;
    };

    return true;
}

pub const RunError = sdk.Error || wasm.Error;

fn run(invocation: *Invocation, entry: u32, head: *const Head, parts: Parts) RunError!Passed {
    const loaded = invocation.loaded;
    const instance = try loaded.ensure_instance();
    const budget = loaded.instructions_max();

    std.debug.assert(parts.in.bytes().len > 0);
    std.debug.assert(loaded.result_offset != 0);

    // Every entry takes its input laid out as the plugin describes it, and hands its answer
    // back the same way: no text is written for the plugin or read from it.
    return shaped_entry.run(invocation, instance, entry, head, parts, budget);
}

/// A call into the guest. The module lacking the export (the sandbox's own `NotFound`)
/// means the plugin cannot be run: `Unavailable`, never the SDK's `NotFound`, which is what a
/// plugin's own operation answers for something it does not have.
pub fn call_guest(
    instance: *wasm.Instance,
    name: [:0]const u8,
    params: []const u32,
    instructions_max: u31,
    problem: *wasm.Problem,
    options: wasm.Instance.CallOptions,
) RunError!u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(instructions_max > 0);

    const answer = instance.call(name, params, instructions_max, problem, options);

    return answer catch |err| switch (err) {
        error.NotFound => error.Unavailable,
        else => |other| other,
    };
}

/// The call a host function is answering; null when the guest reaches the host outside one
/// (from its allocator, while the server writes into its memory): the host function then
/// answers its failure, never the server's own.
pub fn invocation_of(env: *wasm.Env) ?*Invocation {
    const data = env.user_data() orelse return null;

    return @ptrCast(@alignCast(data));
}

/// A remote operation the plugin lists whose plugin is not there or does not fit: off.
pub fn remote_off(loaded: *const Loaded, ctx: *const sdk.Ctx, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(loaded.manifest.remotes.len <= model.plugin_contracts.findings_max);

    const sandboxed = ctx.sandboxed_plugins orelse return false;

    for (loaded.manifest.remotes) |used| {
        if (used.kind == .operation and std.mem.eql(u8, used.name, name)) {
            return sandboxed.remote_off(loaded.name(), name);
        }
    }

    return false;
}
