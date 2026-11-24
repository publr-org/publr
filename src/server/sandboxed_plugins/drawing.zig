//! The host functions an installed plugin's view draws through: `publr_frame` says which
//! frame the page is for and who is looking, then `publr_draw` (`drawing_page.zig`) draws
//! the whole page the view described, natively, with that frame's request. One drawing per
//! call into the plugin.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const admin = @import("../../adapters/admin.zig");
const HostApi = @import("../../sdk/plugin/context.zig").HostApi;
const invoke = @import("invoke.zig");
const host_calls = @import("host_calls.zig");
const shaped_call = @import("shaped_call.zig");
const runtime = @import("runtime");

pub const base_len_max: u32 = 256;

/// `publr_frame(base, wanted, sizes)`: the page is for the plugin frame under `base`; the
/// components drawn after it read the frame's request. Who is looking and the page, for the
/// view's `ctx`, are laid out as the plugin describes at `wanted` and wait for
/// `publr_shaped_take`.
pub fn publr_frame(
    env: *wasm.Env,
    base_ptr: u32,
    base_len: u32,
    wanted_ptr: u32,
    sizes_ptr: u32,
) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse {
        return wire.code_of(error.Unavailable);
    };
    const ctx = invocation.ctx;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (base_len > base_len_max) {
        return wire.code_of(error.Invalid);
    }

    const copied = if (base_len == 0) "" else host_calls.copy_guest(env, ctx, base_ptr, base_len);
    const base = copied orelse return wire.code_of(error.Invalid);

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

    // What a drawing keeps (its expressions' engine, the templates written) lasts the call.
    invocation.drawing = admin.drawn.Drawing.start(ctx.lasting orelse ctx.arena, request) catch {
        return wire.code_of(error.OutOfMemory);
    };

    var wanted: wire.Result = undefined;

    if (!env.read(wanted_ptr, std.mem.asBytes(&wanted))) {
        return wire.code_of(error.Invalid);
    }

    // Who is looking and at what, laid out as the plugin's own struct.
    const frame = Frame.of(ctx.arena, ctx.view);

    return shaped_call.hold_typed(Frame, env, &frame, wanted, sizes_ptr);
}

/// What a view is told (`sdk.context.View`), with what an editor's value reads as when it
/// is kept as text holding JSON: the plugin reads no text.
const Frame = struct {
    person: sdk.context.View.Person,
    page: sdk.context.View.Page,
    editor: ?Editor,

    const Editor = struct {
        value: std.json.Value,
        parsed: ?std.json.Value,
        problems: []const []const u8,
        options: sdk.context.View.Options,
    };

    fn of(arena: std.mem.Allocator, view: sdk.context.View) Frame {
        const editor = view.editor orelse return .{
            .person = view.person,
            .page = view.page,
            .editor = null,
        };
        const held = editor.value;

        std.debug.assert(held != .number_string);

        return .{
            .person = view.person,
            .page = view.page,
            .editor = .{
                .value = held,
                .parsed = if (held == .string)
                    std.json.parseFromSliceLeaky(std.json.Value, arena, held.string, .{}) catch null
                else
                    null,
                .problems = editor.problems,
                .options = editor.options,
            },
        };
    }
};

/// One message a view or a call asks for: its context, id and plural.
const Asked = struct {
    context: []const u8 = "",
    id: []const u8,
    plural: []const u8 = "",
    count: ?f64 = null,
};

/// The most one text of a message asked for may take.
pub const asked_len_max: u32 = 16 << 10;

/// `publr_translate(asked)`: one message of the plugin's view in the language of whoever is
/// looking, from the catalogue a compiled-in view reads; nothing for English or a message
/// no language pack has. `asked` is a `wire.Message`: where each text lies in the plugin.
pub fn publr_translate(env: *wasm.Env, asked_ptr: u32, result_ptr: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse {
        return wire.code_of(error.Unavailable);
    };
    const ctx = invocation.ctx;
    var parts: wire.Message = undefined;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (!env.read(asked_ptr, std.mem.asBytes(&parts))) {
        return wire.code_of(error.Invalid);
    }

    const message: Asked = .{
        .context = asked_text(env, ctx, parts.context, parts.context_len, true) orelse {
            return wire.code_of(error.Invalid);
        },
        .id = asked_text(env, ctx, parts.id, parts.id_len, false) orelse {
            return wire.code_of(error.Invalid);
        },
        .plural = asked_text(env, ctx, parts.plural, parts.plural_len, true) orelse {
            return wire.code_of(error.Invalid);
        },
        .count = if (parts.counted != 0) parts.count else null,
    };
    const pointer = ctx.language.translator orelse {
        return said_in_call(env, ctx, message, result_ptr);
    };
    const translator: *const runtime.Translator = @ptrCast(@alignCast(pointer));
    const found = translator.lookup(
        translator.context,
        message.context,
        message.id,
        message.plural,
        message.count,
    ) orelse return wire.code_of(error.NotFound);

    return host_calls.reply(env, found, result_ptr);
}

/// One text of a message, copied out of the plugin: inside its memory, UTF-8, bounded.
fn asked_text(env: *wasm.Env, ctx: *sdk.Ctx, ptr: u32, len: u32, may_be_empty: bool) ?[]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (len == 0) {
        return if (may_be_empty) "" else null;
    }

    if (len > asked_len_max) {
        return null;
    }

    const copied = host_calls.copy_guest(env, ctx, ptr, len) orelse return null;

    return if (std.unicode.utf8ValidateSlice(copied)) copied else null;
}

/// Outside a render (a call, a job, an `on` hook): the message in the call's language, from
/// the catalogues a compiled-in plugin's `ctx.t` reads; nothing for English or a message no
/// language pack has.
fn said_in_call(
    env: *wasm.Env,
    ctx: *sdk.Ctx,
    message: Asked,
    result_ptr: u32,
) u32 {
    const locale = ctx.speaks();

    std.debug.assert(message.id.len > 0);

    if (locale.len == 0 or ctx.translations == null) {
        return wire.code_of(error.NotFound);
    }

    const said = ctx.say(locale, .{
        .context = message.context,
        .id = message.id,
        .plural = if (message.count == null) "" else message.plural,
        .count = message.count,
    }) catch return wire.code_of(error.OutOfMemory);
    const many = message.plural.len > 0 and (message.count orelse 1) != 1;
    const source = if (many) message.plural else message.id;

    if (std.mem.eql(u8, said, source)) {
        return wire.code_of(error.NotFound);
    }

    return host_calls.reply(env, said, result_ptr);
}
