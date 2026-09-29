//! One call into a plugin, and the host functions it may make while it runs. The plugin
//! runs as itself: its calls are dispatched as a plugin caller holding its grants, narrowed
//! to the roles of the account it acts for, within its limits.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const Loaded = @import("loaded.zig").Loaded;

pub const imports = [_]wasm.Import{
    .{ .name = "publr_call", .signature = "(iiiii)i", .function = &publr_call },
    .{ .name = "publr_notice", .signature = "(iiii)", .function = &publr_notice },
    .{ .name = "publr_log", .signature = "(ii)", .function = &publr_log },
};

/// What a host function finds through the call's user data.
const Invocation = struct {
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    calls_left: u32,
    output_bytes_max: u32,
};

/// How the entry's input sits in the envelope: as its `in`, or (an `after` hook's `in` and
/// `out`) spread beside the envelope's own fields.
const Shape = enum { wrap, spread };

/// Runs entry `entry` with `input` (the entry's own JSON) as the plugin, and answers its
/// output copied into the context's arena.
pub fn invoke(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    input: []const u8,
) sdk.Error![]const u8 {
    return invoke_shaped(loaded, ctx, access, entry, input, .wrap);
}

/// Runs an `after` hook: `both` is `{"in":...,"out":...}`.
pub fn invoke_spread(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    both: []const u8,
) sdk.Error![]const u8 {
    return invoke_shaped(loaded, ctx, access, entry, both, .spread);
}

fn invoke_shaped(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    input: []const u8,
    shape: Shape,
) sdk.Error![]const u8 {
    std.debug.assert(input.len > 0);
    std.debug.assert(entry < loaded.manifest.operations.len + loaded.manifest.hooks.len);

    const envelope = try envelope_of(ctx, input, shape);
    const saved = ctx.caller;

    ctx.caller = .{ .plugin = .{
        .name = loaded.name(),
        .capabilities = &.{},
        .on_behalf_of = saved.user_id(),
        .access = access,
        .roles = saved.roles() orelse if (saved == .plugin) saved.plugin.roles else null,
    } };
    defer ctx.caller = saved;

    var invocation: Invocation = .{
        .loaded = loaded,
        .ctx = ctx,
        .calls_left = loaded.limits.calls,
        .output_bytes_max = loaded.limits.output_kib << 10,
    };

    return run(&invocation, entry, envelope) catch |err| switch (err) {
        error.Load, error.Instantiate, error.Trap, error.Exhausted => {
            loaded.drop_instance();
            return error.Unavailable;
        },
        error.NotFound => error.Unavailable,
        else => |other| other,
    };
}

const RunError = sdk.Error || wasm.Error;

fn run(invocation: *Invocation, entry: u32, envelope: []const u8) RunError![]const u8 {
    const loaded = invocation.loaded;
    const instance = try loaded.ensure_instance();
    var problem: wasm.Problem = .{};
    const budget: wasm.Instance.CallOptions = .{
        .instructions_max = loaded.instructions_max(),
        .user_data = invocation,
    };

    std.debug.assert(envelope.len > 0);
    std.debug.assert(loaded.result_offset != 0);

    const input_offset = try write_guest(instance, envelope, &problem);
    const status = instance.call("publr_invoke", &.{
        entry,
        input_offset,
        @intCast(envelope.len),
        loaded.result_offset,
    }, budget, &problem) catch |err| {
        std.log.warn("plugin {s}: {s}", .{ loaded.name(), problem.text() });
        return err;
    };

    const input_len: u32 = @intCast(envelope.len);

    _ = try instance.call("publr_free", &.{ input_offset, input_len }, budget, &problem);

    if (status != wire.ok) {
        return wire.error_of(status);
    }

    return read_result(invocation, instance, &problem);
}

fn read_result(
    invocation: *Invocation,
    instance: *wasm.Instance,
    problem: *wasm.Problem,
) RunError![]const u8 {
    const loaded = invocation.loaded;
    const cell = instance.bytes(loaded.result_offset, wire.result_bytes) orelse return error.Trap;
    const result = std.mem.bytesToValue(wire.Result, cell);

    std.debug.assert(cell.len == wire.result_bytes);
    std.debug.assert(invocation.output_bytes_max > 0);

    if (result.len == 0) {
        return "{}";
    }

    if (result.len > invocation.output_bytes_max) {
        return error.Invalid;
    }

    const output = instance.bytes(result.ptr, result.len) orelse return error.Trap;
    const copy = invocation.ctx.arena.dupe(u8, output) catch return error.OutOfMemory;

    _ = try instance.call("publr_free", &.{ result.ptr, result.len }, .{
        .instructions_max = 100_000,
    }, problem);

    return copy;
}

/// Copies `bytes` into memory the guest allocates, and answers where.
fn write_guest(instance: *wasm.Instance, bytes: []const u8, problem: *wasm.Problem) wasm.Error!u32 {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(bytes.len <= std.math.maxInt(u32));

    const offset = try instance.call("publr_alloc", &.{@intCast(bytes.len)}, .{
        .instructions_max = 100_000,
    }, problem);

    if (offset == 0) {
        return error.Trap;
    }

    const target = instance.bytes(offset, @intCast(bytes.len)) orelse return error.Trap;

    @memcpy(target, bytes);

    return offset;
}

fn envelope_of(ctx: *const sdk.Ctx, input: []const u8, shape: Shape) sdk.Error![]const u8 {
    std.debug.assert(input.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const on_behalf_of = try sdk.stringify(ctx.arena, ctx.caller.user_id());
    const head = "{{\"now_ms\":{d},\"on_behalf_of\":{s},";

    if (shape == .spread) {
        std.debug.assert(input[0] == '{');

        return std.fmt.allocPrint(ctx.arena, head ++ "{s}", .{
            ctx.now_ms,
            on_behalf_of,
            input[1..],
        }) catch error.OutOfMemory;
    }

    return std.fmt.allocPrint(ctx.arena, head ++ "\"in\":{s}}}", .{
        ctx.now_ms,
        on_behalf_of,
        input,
    }) catch error.OutOfMemory;
}

fn invocation_of(env: *wasm.Env) *Invocation {
    const data = env.user_data() orelse unreachable;

    return @ptrCast(@alignCast(data));
}

fn publr_call(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    input_ptr: u32,
    input_len: u32,
    result_ptr: u32,
) callconv(.c) u32 {
    const invocation = invocation_of(env);
    const ctx = invocation.ctx;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (invocation.calls_left == 0) {
        return wire.code_of(error.Throttled);
    }

    invocation.calls_left -= 1;

    // The guest's memory can move while the call runs (a nested call may grow it): every
    // slice of it is copied out first, and looked up again after.
    const name = copy_guest(env, ctx, name_ptr, name_len) orelse return wire.code_of(error.Invalid);
    const input = copy_guest(env, ctx, input_ptr, input_len) orelse {
        return wire.code_of(error.Invalid);
    };
    const output = registry.SDK.call_json(ctx, name, input) catch |err| return wire.code_of(err);

    return reply(env, output, result_ptr);
}

fn reply(env: *wasm.Env, output: []const u8, result_ptr: u32) u32 {
    std.debug.assert(output.len > 0);
    std.debug.assert(output.len <= std.math.maxInt(u32));

    var problem: wasm.Problem = .{};
    const offset = env.call("publr_alloc", &.{@intCast(output.len)}, &problem) catch {
        return wire.code_of(error.OutOfMemory);
    };
    const target = env.bytes(offset, @intCast(output.len)) orelse {
        return wire.code_of(error.OutOfMemory);
    };
    const cell = env.bytes(result_ptr, wire.result_bytes) orelse return wire.code_of(error.Invalid);
    const result: wire.Result = .{ .ptr = offset, .len = @intCast(output.len) };

    @memcpy(target, output);
    @memcpy(cell, std.mem.asBytes(&result));

    return wire.ok;
}

fn copy_guest(env: *wasm.Env, ctx: *sdk.Ctx, ptr: u32, len: u32) ?[]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (len == 0 or len > sdk.in_bytes_max * 16) {
        return null;
    }

    const bytes = env.bytes(ptr, len) orelse return null;

    return ctx.arena.dupe(u8, bytes) catch null;
}

fn publr_notice(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    subject_ptr: u32,
    subject_len: u32,
) callconv(.c) void {
    const invocation = invocation_of(env);
    const ctx = invocation.ctx;
    const name = copy_guest(env, ctx, name_ptr, name_len) orelse return;
    const subject = if (subject_len == 0)
        ""
    else
        copy_guest(env, ctx, subject_ptr, subject_len) orelse return;

    std.debug.assert(name.len > 0);

    if (ctx.parent != null) {
        ctx.notice(name, subject);
    }
}

fn publr_log(env: *wasm.Env, line_ptr: u32, line_len: u32) callconv(.c) void {
    const invocation = invocation_of(env);
    const line = env.bytes(line_ptr, @min(line_len, 1024)) orelse return;

    std.debug.assert(invocation.loaded.name().len > 0);
    std.log.info("plugin {s}: {s}", .{ invocation.loaded.name(), line });
}
