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
const Loaded = @import("loaded.zig").Loaded;
const HostApi = @import("../../sdk/plugin/context.zig").HostApi;
const drawing = @import("drawing.zig");
const drawn = @import("../../ui/drawn.zig");

pub const imports = [_]wasm.Import{
    .{
        .name = "publr_call",
        .signature = "(iiiii)i",
        .function = &publr_call,
    },
    .{
        .name = "publr_emit",
        .signature = "(iiii)",
        .function = &publr_emit,
    },
    .{
        .name = "publr_log",
        .signature = "(ii)",
        .function = &publr_log,
    },
    .{
        .name = "publr_fail",
        .signature = "(iiii)",
        .function = &publr_fail,
    },
    .{
        .name = "publr_granted",
        .signature = "(ii)i",
        .function = &publr_granted,
    },
    .{
        .name = "publr_grant_domains",
        .signature = "(iii)i",
        .function = &publr_grant_domains,
    },
    .{
        .name = "publr_log_at",
        .signature = "(iii)",
        .function = &publr_log_at,
    },
    .{
        .name = "publr_refuse",
        .signature = "(iiiii)",
        .function = &publr_refuse,
    },
    .{
        .name = "publr_problem",
        .signature = "(iiii)",
        .function = &publr_problem,
    },
    .{
        .name = "publr_enqueue",
        .signature = "(ii)i",
        .function = &publr_enqueue,
    },
    .{
        .name = "publr_frame",
        .signature = "(ii)i",
        .function = &drawing.publr_frame,
    },
    .{
        .name = "publr_render",
        .signature = "(iiiii)i",
        .function = &drawing.publr_render,
    },
};

/// What a host function finds through the call's user data.
pub const Invocation = struct {
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    calls_left: u32,
    output_bytes_max: u32,
    /// What the plugin's view draws with, from its `publr_frame` on.
    drawing: ?*drawn.Drawing = null,
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
    std.debug.assert(entry < loaded.manifest.operations.len + loaded.manifest.hooks.len +
        loaded.manifest.jobs.len);

    const envelope = try envelope_of(ctx, input, shape);
    const saved = ctx.caller;
    const running = ctx.plugin;

    ctx.plugin = loaded.name();
    defer ctx.plugin = running;

    ctx.caller = .{
        .plugin = .{
            .name = loaded.name(),
            .on_behalf_of = saved.user_id(),
            .access = access,
            .roles = saved.roles() orelse if (saved == .plugin) saved.plugin.roles else null,
        },
    };
    defer ctx.caller = saved;

    var invocation: Invocation = .{
        .loaded = loaded,
        .ctx = ctx,
        .calls_left = loaded.limits.calls,
        .output_bytes_max = loaded.limits.output_kib << 10,
    };
    defer if (invocation.drawing) |held| {
        held.deinit();
    };

    return run(&invocation, entry, envelope) catch |err| switch (err) {
        error.Load, error.Instantiate, error.Trap, error.Exhausted => {
            loaded.drop_instance();
            return error.Unavailable;
        },
        else => |other| other,
    };
}

const RunError = sdk.Error || wasm.Error;

fn run(invocation: *Invocation, entry: u32, envelope: []const u8) RunError![]const u8 {
    const loaded = invocation.loaded;
    const instance = try loaded.ensure_instance();
    var problem: wasm.Problem = .{};
    const budget = loaded.instructions_max();
    const options: wasm.Instance.CallOptions = .{
        .user_data = invocation,
    };

    std.debug.assert(envelope.len > 0);
    std.debug.assert(loaded.result_offset != 0);

    const input_offset = try write_guest(instance, envelope, &problem);
    const status = call_guest(instance, "publr_invoke", &.{
        entry,
        input_offset,
        @intCast(envelope.len),
        loaded.result_offset,
    }, budget, &problem, options) catch |err| {
        std.log.warn("plugin {s}: {s}", .{ loaded.name(), problem.text() });
        return err;
    };

    const input_len: u32 = @intCast(envelope.len);
    const input = [_]u32{ input_offset, input_len };

    _ = try call_guest(instance, "publr_free", &input, budget, &problem, options);

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
    var cell: [wire.result_bytes]u8 = undefined;

    if (!instance.read(loaded.result_offset, &cell)) {
        return error.Trap;
    }

    const result = std.mem.bytesToValue(wire.Result, &cell);

    std.debug.assert(invocation.output_bytes_max > 0);

    if (result.len == 0) {
        return "{}";
    }

    if (result.len > invocation.output_bytes_max) {
        return error.Invalid;
    }

    const copy = invocation.ctx.arena.alloc(u8, result.len) catch return error.OutOfMemory;

    if (!instance.read(result.ptr, copy)) {
        return error.Trap;
    }

    _ = try call_guest(instance, "publr_free", &.{ result.ptr, result.len }, 100_000, problem, .{});

    return copy;
}

/// Copies `bytes` into memory the guest allocates, and answers where.
fn write_guest(instance: *wasm.Instance, bytes: []const u8, problem: *wasm.Problem) RunError!u32 {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(bytes.len <= std.math.maxInt(u32));

    const len: u32 = @intCast(bytes.len);
    const offset = try call_guest(instance, "publr_alloc", &.{len}, 100_000, problem, .{});

    if (offset == 0) {
        return error.Trap;
    }

    if (!instance.write(offset, bytes)) {
        return error.Trap;
    }

    return offset;
}

/// A call into the guest. The module lacking the export (the sandbox's own `NotFound`)
/// means the plugin cannot be run: `Unavailable`, never the SDK's `NotFound`, which is what a
/// plugin's own operation answers for something it does not have.
fn call_guest(
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

fn envelope_of(ctx: *sdk.Ctx, input: []const u8, shape: Shape) sdk.Error![]const u8 {
    std.debug.assert(input.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const on_behalf_of = try sdk.stringify(ctx.arena, ctx.caller.user_id());
    const visitor = try sdk.stringify(ctx.arena, ctx.visitor);
    const caller = try sdk.stringify(ctx.arena, caller_of(ctx));
    const head = "{{\"now_ms\":{d},\"on_behalf_of\":{s},\"visitor\":{s},\"caller\":{s},";

    if (shape == .spread) {
        std.debug.assert(input[0] == '{');

        return std.fmt.allocPrint(ctx.arena, head ++ "{s}", .{
            ctx.now_ms,
            on_behalf_of,
            visitor,
            caller,
            input[1..],
        }) catch error.OutOfMemory;
    }

    return std.fmt.allocPrint(ctx.arena, head ++ "\"in\":{s}}}", .{
        ctx.now_ms,
        on_behalf_of,
        visitor,
        caller,
        input,
    }) catch error.OutOfMemory;
}

/// The caller as a compiled-in plugin's `ctx.caller()` sees it.
fn caller_of(ctx: *sdk.Ctx) wire.Caller {
    std.debug.assert(ctx.now_ms >= 0);

    const host: HostApi = .{
        .inner = ctx,
    };
    const view = host.caller();

    std.debug.assert(view.visitor.len == ctx.visitor.len);

    return .{
        .from = caller_view.kind_of(view.from),
        .plugin = caller_view.plugin_of(view.from),
        .referer = view.referer,
        .signed_in = view.signed_in(),
        .roles = ctx.caller.roles() orelse &.{},
        .granted = view.granted(),
    };
}

pub fn invocation_of(env: *wasm.Env) *Invocation {
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

    if (remote_off(invocation.loaded, ctx, name)) {
        return wire.code_of(error.Unavailable);
    }

    const output = registry.SDK.call_json(ctx, name, input) catch |err| {
        // A refusal goes back with its name, for the plugin's `ctx.failure()`.
        if (err == error.Failed) if (ctx.failure) |failure| {
            if (reply(env, failure.name, result_ptr) != wire.ok) {
                return wire.code_of(error.OutOfMemory);
            }
        };

        return wire.code_of(err);
    };

    return reply(env, output, result_ptr);
}

/// A remote operation the plugin lists whose plugin is not there or does not fit: off.
fn remote_off(loaded: *const Loaded, ctx: *const sdk.Ctx, name: []const u8) bool {
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

pub fn reply(env: *wasm.Env, output: []const u8, result_ptr: u32) u32 {
    std.debug.assert(output.len > 0);
    std.debug.assert(output.len <= std.math.maxInt(u32));

    var problem: wasm.Problem = .{};
    const offset = env.call("publr_alloc", &.{@intCast(output.len)}, &problem) catch {
        return wire.code_of(error.OutOfMemory);
    };
    const result: wire.Result = .{
        .ptr = offset,
        .len = @intCast(output.len),
    };

    if (!env.write(offset, output)) {
        return wire.code_of(error.OutOfMemory);
    }

    if (!env.write(result_ptr, std.mem.asBytes(&result))) {
        return wire.code_of(error.Invalid);
    }

    return wire.ok;
}

/// A plugin's call into Publr, at most: an outbound request with a conversation's pictures.
const call_bytes_max: u32 = 9 << 20;

pub fn copy_guest(env: *wasm.Env, ctx: *sdk.Ctx, ptr: u32, len: u32) ?[]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (len == 0 or len > call_bytes_max) {
        return null;
    }

    const copy = ctx.arena.alloc(u8, len) catch return null;

    return if (env.read(ptr, copy)) copy else null;
}

/// `ctx.enqueue` in an installed plugin: one of its own jobs, never a repeating one, queued
/// in the caller's write.
fn publr_enqueue(env: *wasm.Env, ptr: u32, len: u32) callconv(.c) u32 {
    const invocation = invocation_of(env);
    const ctx = invocation.ctx;
    const loaded = invocation.loaded;
    const text = copy_guest(env, ctx, ptr, len) orelse return wire.code_of(error.Invalid);
    const asked = std.json.parseFromSliceLeaky(struct {
        name: []const u8,
        in: std.json.Value,
        due_ms: i64,
    }, ctx.arena, text, .{
        .ignore_unknown_fields = true,
    }) catch return wire.code_of(error.Invalid);

    std.debug.assert(loaded.name().len > 0);

    if (!queues(loaded.manifest, asked.name)) {
        return wire.code_of(error.Denied);
    }

    const input = std.json.Stringify.valueAlloc(ctx.arena, asked.in, .{}) catch {
        return wire.code_of(error.OutOfMemory);
    };

    if (input.len > job_queue.input_bytes_max) {
        return wire.code_of(error.Invalid);
    }

    job_queue.push(ctx.db, .{
        .plugin = loaded.name(),
        .name = asked.name,
        .input = input,
        .due_at_ms = @max(asked.due_ms, ctx.now_ms),
        .now_ms = ctx.now_ms,
    }) catch return wire.code_of(error.Unavailable);

    return wire.ok;
}

/// Whether the manifest declares `name` as a job code queues (not a repeating one).
fn queues(manifest: model.sandboxed_plugin.Manifest, name: []const u8) bool {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.jobs.len <= 256);

    for (manifest.jobs) |job| {
        if (std.mem.eql(u8, job.name, name)) {
            return job.every.len == 0;
        }
    }

    return false;
}

fn publr_emit(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    payload_ptr: u32,
    payload_len: u32,
) callconv(.c) void {
    const invocation = invocation_of(env);
    const ctx = invocation.ctx;
    const name = copy_guest(env, ctx, name_ptr, name_len) orelse return;
    const payload = if (payload_len == 0)
        "{}"
    else
        copy_guest(env, ctx, payload_ptr, payload_len) orelse return;
    const plugin = invocation.loaded.name();

    std.debug.assert(name.len > 0);
    std.debug.assert(plugin.len > 0);

    // A plugin emits only its own events: `<plugin>.<event>`.
    const own = name.len > plugin.len + 1 and std.mem.startsWith(u8, name, plugin) and
        name[plugin.len] == '.';

    if (!own) {
        log_line(invocation, .warn, "an event not under the plugin's name was not emitted");
        return;
    }

    if (ctx.parent != null) {
        ctx.emit_json(name, payload, true);
    }
}

fn publr_log(env: *wasm.Env, line_ptr: u32, line_len: u32) callconv(.c) void {
    const invocation = invocation_of(env);
    var buffer: [1024]u8 = undefined;
    const line = buffer[0..@min(line_len, buffer.len)];

    if (!env.read(line_ptr, line)) {
        return;
    }

    std.debug.assert(invocation.loaded.name().len > 0);
    log_line(invocation, .info, line);
}

/// A line the plugin logged: on the call's lines, else the server's output.
fn log_line(invocation: *Invocation, level: sdk.trail.Level, line: []const u8) void {
    const name = invocation.loaded.name();

    std.debug.assert(name.len > 0);

    if (invocation.ctx.lines) |lines| {
        lines.add(.{
            .plugin = name,
            .level = level,
            .text = line,
        });

        return;
    }

    switch (level) {
        .info => std.log.info("plugin {s}: {s}", .{ name, line }),
        .warn => std.log.warn("plugin {s}: {s}", .{ name, line }),
        .err => std.log.err("plugin {s}: {s}", .{ name, line }),
    }
}

/// Whether the plugin holds a permission key, and its flags as granted now, as bits
/// (`Grant.bits`): what `ctx.grant` reads.
fn publr_granted(env: *wasm.Env, key_ptr: u32, key_len: u32) callconv(.c) u32 {
    const invocation = invocation_of(env);
    var buffer: [64]u8 = undefined;
    const key = buffer[0..@min(key_len, buffer.len)];

    if (!env.read(key_ptr, key)) {
        return 0;
    }

    const caller = invocation.ctx.caller;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (caller != .plugin) {
        return 0;
    }

    const access = caller.plugin.access orelse return 0;
    const held = access.held_of(key) orelse return 0;
    const granted: permission_define.Grant = .{
        .on = true,
        .drafts = held.drafts,
        .private = held.private,
        .internal = held.internal,
        .publish = held.publish,
    };

    return granted.bits();
}

/// The domains on the plugin's grant for a key (`http.fetch`) as granted now, one per line:
/// what `ctx.grant`'s `.domains` reads. Nothing when it holds no such grant.
fn publr_grant_domains(
    env: *wasm.Env,
    key_ptr: u32,
    key_len: u32,
    result_ptr: u32,
) callconv(.c) u32 {
    const invocation = invocation_of(env);
    var buffer: [64]u8 = undefined;
    const key = buffer[0..@min(key_len, buffer.len)];

    std.debug.assert(invocation.loaded.name().len > 0);

    if (!env.read(key_ptr, key)) {
        return wire.code_of(error.Invalid);
    }

    const none: wire.Result = .{
        .ptr = 0,
        .len = 0,
    };
    const domains = granted_domains(invocation.ctx.caller, key);

    if (domains.len == 0) {
        const written = env.write(result_ptr, std.mem.asBytes(&none));

        return if (written) wire.ok else wire.code_of(error.Invalid);
    }

    const text = std.mem.join(invocation.ctx.arena, "\n", domains) catch {
        return wire.code_of(error.OutOfMemory);
    };

    return reply(env, text, result_ptr);
}

/// The domains `caller`, a plugin, holds on `key`; none for anyone else.
fn granted_domains(caller: sdk.Caller, key: []const u8) []const []const u8 {
    std.debug.assert(key.len > 0);

    if (caller != .plugin) {
        return &.{};
    }

    const access = caller.plugin.access orelse return &.{};
    const held = access.held_of(key) orelse return &.{};

    return held.domains;
}

/// A line with its level: `ctx.log(.warn, ...)`.
fn publr_log_at(env: *wasm.Env, level: u32, line_ptr: u32, line_len: u32) callconv(.c) void {
    const invocation = invocation_of(env);
    var buffer: [1024]u8 = undefined;
    const line = buffer[0..@min(line_len, buffer.len)];

    if (!env.read(line_ptr, line)) {
        return;
    }

    std.debug.assert(invocation.loaded.name().len > 0);
    log_line(invocation, switch (level) {
        0 => .info,
        1 => .warn,
        else => .err,
    }, line);
}

/// A refusal with the status its operation's `Fails:` gives it (4xx, never 401 or 429).
fn publr_refuse(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    message_ptr: u32,
    message_len: u32,
    status: u32,
) callconv(.c) void {
    const invocation = invocation_of(env);
    const kept_status: u16 = if (status >= 400 and status <= 499 and status != 401 and
        status != 429) @intCast(status) else 409;

    std.debug.assert(invocation.loaded.name().len > 0);

    publr_fail(env, name_ptr, name_len, message_ptr, message_len);

    if (invocation.ctx.failure) |*failure| {
        failure.status = kept_status;
    }
}

/// One problem `.validate` found, kept beside the others until the call ends `Invalid`.
fn publr_problem(
    env: *wasm.Env,
    field_ptr: u32,
    field_len: u32,
    message_ptr: u32,
    message_len: u32,
) callconv(.c) void {
    const invocation = invocation_of(env);
    const ctx = invocation.ctx;
    const held = ctx.problems;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (held.len >= sdk.operation.problems_max or field_len == 0 or message_len == 0) {
        return;
    }

    const field = copy_guest(env, ctx, field_ptr, @min(field_len, 64)) orelse return;
    const message_len_kept = @min(message_len, sdk.operation.failure_message_len_max);
    const message = copy_guest(env, ctx, message_ptr, message_len_kept) orelse return;
    const grown = ctx.arena.alloc(sdk.operation.Problem, held.len + 1) catch return;

    @memcpy(grown[0..held.len], held);
    grown[held.len] = .{
        .field = field,
        .message = message,
    };
    ctx.problems = grown;

    std.debug.assert(ctx.problems.len == held.len + 1);
}

/// The plugin refusing its call in its own words: kept as the call's failure, which the
/// error it returns next turns into the answer.
fn publr_fail(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    message_ptr: u32,
    message_len: u32,
) callconv(.c) void {
    const invocation = invocation_of(env);
    const ctx = invocation.ctx;
    const name = copy_guest(env, ctx, name_ptr, @min(name_len, 64)) orelse return;
    const message = if (message_len == 0)
        ""
    else
        copy_guest(env, ctx, message_ptr, @min(message_len, 1024)) orelse return;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (name.len > 0) {
        ctx.failure = .{
            .name = name,
            .status = 409,
            .message = message,
        };
    }
}
