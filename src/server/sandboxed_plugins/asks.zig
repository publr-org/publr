//! What a plugin asks of the host beside calling operations, the same as a compiled-in one
//! asks of its ctx: whether a call would be let in (`ctx.may`), what the last refusal says
//! to people (`ctx.failure_message`), and calls made as the plugin alone, with no person
//! behind them (`ctx.as_plugin`). Each is a host function of its own, so a plugin built
//! before them, which imports none, loads as it did.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const invoke = @import("invoke.zig");
const shaped_call = @import("shaped_call.zig");
const host_calls = @import("host_calls.zig");

const name_bytes_max: u32 = 256;

/// The plugin's caller with nobody behind it for one call: its grants decide, no account's
/// roles narrow them, nothing it makes names a maker. Put back by `end`.
const Alone = struct {
    ctx: *sdk.Ctx,
    saved: sdk.Caller,

    fn begin(ctx: *sdk.Ctx) Alone {
        std.debug.assert(ctx.now_ms >= 0);

        const alone: Alone = .{
            .ctx = ctx,
            .saved = ctx.caller,
        };

        if (ctx.caller == .plugin) {
            ctx.caller.plugin.on_behalf_of = null;
            ctx.caller.plugin.roles = null;
            ctx.caller.plugin.for_person = false;
        }

        return alone;
    }

    fn end(alone: Alone) void {
        std.debug.assert(alone.ctx.now_ms >= 0);

        alone.ctx.caller = alone.saved;
    }
};

/// `publr_call_alone(call, sizes)`: `publr_call_shaped` made as the plugin alone.
pub fn publr_call_alone(env: *wasm.Env, call_ptr: u32, sizes_ptr: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse return wire.code_of(error.Unavailable);
    const alone = Alone.begin(invocation.ctx);
    defer alone.end();

    std.debug.assert(invocation.loaded.name().len > 0);

    return shaped_call.publr_call_shaped(env, call_ptr, sizes_ptr);
}

/// `publr_may(name, len, alone)`: 1 when a call of the operation `name` would be let in, as
/// the plugin calls now (`alone`: as `publr_call_alone` calls), 0 otherwise or when there is
/// no such operation.
pub fn publr_may(env: *wasm.Env, name_ptr: u32, name_len: u32, alone: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse return 0;
    var buffer: [name_bytes_max]u8 = undefined;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (name_len == 0 or name_len > buffer.len) {
        return 0;
    }

    const name = buffer[0..name_len];

    if (!env.read(name_ptr, name)) {
        return 0;
    }

    const ctx = invocation.ctx;

    if (alone == 0) {
        return @intFromBool(registry.SDK.may_named(ctx, name));
    }

    const acting = Alone.begin(ctx);
    defer acting.end();

    return @intFromBool(registry.SDK.may_named(ctx, name));
}

/// `publr_failure_message(result)`: what the refusal the plugin's last call came back with
/// says to people, written into room the plugin makes; nothing when there was none.
pub fn publr_failure_message(env: *wasm.Env, result_ptr: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse return wire.code_of(error.Unavailable);
    const message = if (invocation.ctx.failure) |failure| failure.message else "";

    std.debug.assert(invocation.loaded.name().len > 0);

    if (message.len == 0) {
        const none: wire.Result = .{
            .ptr = 0,
            .len = 0,
        };
        const written = env.write(result_ptr, std.mem.asBytes(&none));

        return if (written) wire.ok else wire.code_of(error.Invalid);
    }

    return host_calls.reply(env, message, result_ptr);
}
