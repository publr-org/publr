//! The host functions an installed plugin's view draws through: `publr_frame` says which
//! frame the page is for, then `publr_render` draws each design-system component the view
//! reaches, natively, with that frame's request. One drawing per call into the plugin.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const admin = @import("../../adapters/admin.zig");
const HostApi = @import("../../sdk/plugin/context.zig").HostApi;
const invoke = @import("invoke.zig");

pub const base_len_max: u32 = 256;
pub const name_len_max: u32 = 64;

/// `publr_frame(base)`: the page is for the plugin frame under `base`; the components drawn
/// after it read the frame's request. Answers who is looking and the page, as JSON, for the
/// view's `ctx`.
pub fn publr_frame(env: *wasm.Env, base_ptr: u32, base_len: u32, result_ptr: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env);
    const ctx = invocation.ctx;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (base_len > base_len_max) {
        return wire.code_of(error.Invalid);
    }

    const base = if (base_len == 0)
        ""
    else
        invoke.copy_guest(env, ctx, base_ptr, base_len) orelse return wire.code_of(error.Invalid);

    const unsafe = std.mem.indexOfAny(u8, base, "\"<>&'") != null;

    if ((base.len > 0 and base[0] != '/') or unsafe) {
        return wire.code_of(error.Invalid);
    }

    if (invocation.drawing) |earlier| {
        earlier.deinit();
    }

    var host: HostApi = .{
        .inner = ctx,
    };
    const request = admin.chrome.in_plugin_frame(&host, base) catch {
        return wire.code_of(error.OutOfMemory);
    };

    invocation.drawing = admin.drawn.Drawing.start(ctx.arena, request) catch {
        return wire.code_of(error.OutOfMemory);
    };

    const view = std.json.Stringify.valueAlloc(ctx.arena, ctx.view, .{}) catch {
        return wire.code_of(error.OutOfMemory);
    };

    return invoke.reply(env, view, result_ptr);
}

/// `publr_render(name, props)`: one component drawn, its HTML answered; `NotFound` for one
/// an installed plugin may not draw, `Invalid` before `publr_frame` or for props not its.
pub fn publr_render(
    env: *wasm.Env,
    name_ptr: u32,
    name_len: u32,
    props_ptr: u32,
    props_len: u32,
    result_ptr: u32,
) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env);
    const ctx = invocation.ctx;
    const drawing = invocation.drawing orelse return wire.code_of(error.Invalid);

    std.debug.assert(drawing.request.admin.framed);

    if (name_len > name_len_max) {
        return wire.code_of(error.Invalid);
    }

    const name = invoke.copy_guest(env, ctx, name_ptr, name_len) orelse {
        return wire.code_of(error.Invalid);
    };
    const props = invoke.copy_guest(env, ctx, props_ptr, props_len) orelse {
        return wire.code_of(error.Invalid);
    };
    const html = admin.drawn.draw(drawing, ctx.arena, name, props) catch |err| {
        return wire.code_of(as_sdk(err));
    };

    if (html.len > 0) {
        return invoke.reply(env, html, result_ptr);
    }

    // A component that draws nothing answers nothing: no room is taken in the plugin.
    const empty: wire.Result = .{
        .ptr = 0,
        .len = 0,
    };

    if (!env.write(result_ptr, std.mem.asBytes(&empty))) {
        return wire.code_of(error.Invalid);
    }

    return wire.ok;
}

fn as_sdk(err: admin.drawn.Error) sdk.Error {
    std.debug.assert(@errorName(err).len > 0);

    return switch (err) {
        error.NotFound => error.NotFound,
        error.Invalid => error.Invalid,
        error.OutOfMemory => error.OutOfMemory,
    };
}
