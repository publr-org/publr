//! What a plugin reads of its own grants while it runs: whether it holds a permission key
//! and with which flags (`ctx.grant`), and the domains on a grant, as an administrator
//! left them.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const permission_define = @import("../../sdk/plugin/permission_define.zig");
const invoke = @import("invoke.zig");
const host_calls = @import("host_calls.zig");

const invocation_of = invoke.invocation_of;
const reply = host_calls.reply;

/// Whether the plugin holds a permission key, and its flags as granted now, as bits
/// (`Grant.bits`): what `ctx.grant` reads.
pub fn publr_granted(env: *wasm.Env, key_ptr: u32, key_len: u32) callconv(.c) u32 {
    const invocation = invocation_of(env) orelse return 0;
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
pub fn publr_grant_domains(
    env: *wasm.Env,
    key_ptr: u32,
    key_len: u32,
    result_ptr: u32,
) callconv(.c) u32 {
    const invocation = invocation_of(env) orelse {
        return wire.code_of(error.Unavailable);
    };
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
