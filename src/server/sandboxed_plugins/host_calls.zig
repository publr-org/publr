//! The host functions a plugin calls beside its calls into operations: queueing a job,
//! emitting an event, logging, refusing in its own words, reading what it is granted, and
//! the two ways bytes pass for them (a copy out of the plugin's memory, an answer written
//! into room the plugin makes). Each finds its call through the instance's user data.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const model = @import("../../model.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const job_queue = @import("../../store/job_queue.zig");
const invoke = @import("invoke.zig");
const shaped_call = @import("shaped_call.zig");

const Invocation = invoke.Invocation;
const invocation_of = invoke.invocation_of;
const counted = @import("counted.zig");

pub fn reply(env: *wasm.Env, output: []const u8, result_ptr: u32) u32 {
    std.debug.assert(output.len > 0);
    std.debug.assert(output.len <= std.math.maxInt(u32));

    var problem: wasm.Problem = .{};
    const offset = env.call("publr_alloc", &.{@intCast(output.len)}, &problem) catch {
        return wire.code_of(error.OutOfMemory);
    };

    // The guest's allocator answers 0 when its memory is full: writing there would overwrite
    // the bottom of its stack.
    if (offset == 0) {
        return wire.code_of(error.OutOfMemory);
    }

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

/// A refusal's words copied out of the plugin into the memory that lasts the whole call:
/// they travel up through calls whose working memory is given back as each ends, and are
/// few (`problems_max`), so keeping them there costs nothing worth giving back.
fn copy_said(env: *wasm.Env, ctx: *sdk.Ctx, ptr: u32, len: u32) ?[]const u8 {
    const memory = ctx.call_memory orelse ctx.arena;

    std.debug.assert(ctx.now_ms >= 0);

    if (len == 0 or len > call_bytes_max) {
        return null;
    }

    const copy = memory.alloc(u8, len) catch return null;

    return if (env.read(ptr, copy)) copy else null;
}

/// `ctx.enqueue` in an installed plugin: one of its own jobs, never a repeating one, queued
/// in the caller's write.
pub fn publr_enqueue(env: *wasm.Env, sent_ptr: u32) callconv(.c) u32 {
    const invocation = invocation_of(env) orelse {
        return wire.code_of(error.Unavailable);
    };
    const ctx = invocation.ctx;
    const loaded = invocation.loaded;
    // The queue keeps a job's input as JSON: written once, here, from where it lies.
    const asked = shaped_call.sent_json(env, ctx.arena, sent_ptr) catch |err| {
        return wire.code_of(err);
    };
    const input = asked.json;

    std.debug.assert(loaded.name().len > 0);

    if (!queues(loaded.manifest, asked.name)) {
        return wire.code_of(error.Denied);
    }

    if (input.len > job_queue.input_bytes_max) {
        return wire.code_of(error.Invalid);
    }

    job_queue.push(ctx.db, .{
        .plugin = loaded.name(),
        .name = asked.name,
        .input = input,
        .due_at_ms = @max(asked.due_ms, ctx.now_ms),
        .now_ms = ctx.now_ms,
        .language = ctx.language_queued(),
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

pub fn publr_emit(env: *wasm.Env, sent_ptr: u32) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
    const ctx = invocation.ctx;
    // An event is kept and queued as JSON: written once, here, from where its payload lies.
    const handed = shaped_call.sent_json(env, ctx.arena, sent_ptr) catch return;
    const name = handed.name;
    const payload = handed.json;
    const plugin = invocation.loaded.name();

    std.debug.assert(name.len > 0);
    std.debug.assert(plugin.len > 0);

    // A plugin emits its own events, `<plugin>.<event>`, and those a key it holds lets it
    // (`messaging.send`: `messaging.email`).
    const own = name.len > plugin.len + 1 and std.mem.startsWith(u8, name, plugin) and
        name[plugin.len] == '.';
    const key = model.permission.key_for_event(name);
    const let = if (key) |needed| invocation.loaded.holds(needed) else false;

    if (!own and !let) {
        log_line(invocation, .warn, "an event the plugin may not emit was not emitted");

        // A message without its key fails the write, as compiled in.
        if (key != null) {
            ctx.event_refusal = ctx.event_refusal orelse error.Denied;
        }

        return;
    }

    // An email carrying the site's media: only from a plugin that reads media, or its own
    // made files.
    const messaging = @import("../../sdk/messaging.zig");

    const reads_media = invocation.loaded.holds("media.read");

    const others_media = messaging.carries_media(ctx.arena, name, payload) and
        !messaging.carries_own_files_only(ctx, invocation.loaded.name(), payload);

    if (others_media and !reads_media) {
        log_line(invocation, .warn, "an email carrying media needs media.read");
        ctx.event_refusal = ctx.event_refusal orelse error.Denied;

        return;
    }

    // A message names the plugin that sent it.
    const sent = messaging.signed(ctx.arena, name, payload, plugin) catch {
        ctx.event_refusal = ctx.event_refusal orelse error.OutOfMemory;

        return;
    };

    if (ctx.parent == null) {
        return registry.SDK.emit_alone(ctx, name, sent);
    }

    ctx.emit_json(name, sent, true);
}

pub fn publr_log(env: *wasm.Env, line_ptr: u32, line_len: u32) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
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

/// A queued run failed for the last time: what it wrote is undone before its `on_failure`
/// runs, whose writes are kept.
pub fn publr_undo(env: *wasm.Env) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
    const ctx = invocation.ctx;
    const write = ctx.job_write orelse return;

    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(invocation.loaded.name().len > 0);

    write.undo(ctx) catch |err| {
        log_line(invocation, .warn, "the failed run's writes could not be undone");
        ctx.event_refusal = ctx.event_refusal orelse err;
    };
}

/// A line with its level: `ctx.log(.warn, ...)`.
pub fn publr_log_at(env: *wasm.Env, level: u32, line_ptr: u32, line_len: u32) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
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

/// One of the plugin's SDK collections grew past the largest it told of in the request: its
/// name and what it holds, in KiB. Kept for an out-of-memory failure and the half-limit line.
pub fn publr_held(env: *wasm.Env, name_ptr: u32, name_len: u32, kib: u32) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
    var buffer: [counted.name_bytes_max]u8 = undefined;
    const name = buffer[0..@min(name_len, buffer.len)];

    if (!env.read(name_ptr, name)) {
        return;
    }

    std.debug.assert(invocation.loaded.name().len > 0);

    invocation.loaded.largest.note(name, kib);
}

/// A refusal with the status its operation's `Fails:` gives it (4xx, never 401 or 429).
pub fn publr_refuse(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    message_ptr: u32,
    message_len: u32,
    status: u32,
) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
    const kept_status: u16 = if (status >= 400 and status <= 499 and status != 401 and
        status != 429) @intCast(status) else 409;

    std.debug.assert(invocation.loaded.name().len > 0);

    publr_fail(env, name_ptr, name_len, message_ptr, message_len);

    if (invocation.ctx.failure) |*failure| {
        failure.status = kept_status;
    }
}

/// One problem `.validate` found, kept beside the others until the call ends `Invalid`.
pub fn publr_problem(
    env: *wasm.Env,
    field_ptr: u32,
    field_len: u32,
    message_ptr: u32,
    message_len: u32,
) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
    const ctx = invocation.ctx;
    const held = ctx.problems;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (held.len >= sdk.operation.problems_max or field_len == 0 or message_len == 0) {
        return;
    }

    const field = copy_said(env, ctx, field_ptr, @min(field_len, 64)) orelse return;
    const message_len_kept = @min(message_len, sdk.operation.failure_message_len_max);
    const message = copy_said(env, ctx, message_ptr, message_len_kept) orelse return;
    const memory = ctx.call_memory orelse ctx.arena;
    const grown = memory.alloc(sdk.operation.Problem, held.len + 1) catch return;

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
pub fn publr_fail(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    message_ptr: u32,
    message_len: u32,
) callconv(.c) void {
    const invocation = invocation_of(env) orelse return;
    const ctx = invocation.ctx;
    const name = copy_said(env, ctx, name_ptr, @min(name_len, 64)) orelse return;
    const message = if (message_len == 0)
        ""
    else
        copy_said(env, ctx, message_ptr, @min(message_len, 1024)) orelse return;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (name.len > 0) {
        ctx.failure = .{
            .name = name,
            .status = 409,
            .message = message,
        };
    }
}
