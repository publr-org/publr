//! A plugin's page from its own PTSX view: `publr.views.render(ctx, in.base, Views.SamplerLog,
//! props)` answers the page's HTML, doctype first, the same either way the plugin runs.
//! Compiled in, the view and every component it reaches draw in the process. Installed, the
//! view runs in the plugin and each component of the design system it reaches is drawn by
//! the host (`publr_render`), so no plugin carries the design system.
const std = @import("std");
const guest = @import("guest.zig");
const wire = @import("wire.zig");
const view_wire = @import("view_wire.zig");

const Error = @import("../../sdk.zig").Error;

/// The plugin's views, by name: the admin's generated set compiled in, the plugin's own
/// installed.
pub const all = if (guest.mode == .native)
    @import("../../adapters/admin.zig").views
else
    @import("plugin_views");

extern "env" fn publr_frame(base_ptr: [*]const u8, base_len: u32) u32;
extern "env" fn publr_render(
    name_ptr: [*]const u8,
    name_len: u32,
    props_ptr: [*]const u8,
    props_len: u32,
    result: *wire.Result,
) u32;

/// The page `View` draws with `props`, in the plugin frame under `base`, doctype first.
pub fn render(
    ctx: anytype,
    base: []const u8,
    comptime View: type,
    props: View.Props,
) Error![]const u8 {
    std.debug.assert(base.len == 0 or base[0] == '/');
    comptime std.debug.assert(@hasDecl(View, "render"));

    if (comptime guest.mode == .native) {
        const admin = @import("../../adapters/admin.zig");
        const request = admin.chrome.in_plugin_frame(ctx, base) catch return error.OutOfMemory;

        return admin.render.document(ctx.arena(), request, View, props) catch error.OutOfMemory;
    }

    const status = publr_frame(base.ptr, @intCast(base.len));

    if (status != wire.ok) {
        return wire.error_of(status);
    }

    var out: std.Io.Writer.Allocating = .init(ctx.arena());

    // JSX has no doctype; every page starts with one, as compiled in.
    out.writer.writeAll("<!doctype html>\n") catch return error.OutOfMemory;
    View.render(&out.writer, ctx.arena(), props) catch |err| return as_error(err);

    return out.written();
}

/// A stand-in's `render`: `name` drawn by the host with `props`, its node props drawn here
/// first.
pub fn draw(
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    comptime name: []const u8,
    comptime Props: type,
    props: Props,
) !void {
    comptime std.debug.assert(guest.mode == .sandboxed);
    std.debug.assert(name.len > 0);

    const text = try view_wire.encode(arena, Props, props, Nodes{
        .arena = arena,
    });
    var result: wire.Result = .{
        .ptr = 0,
        .len = 0,
    };
    const status = publr_render(name.ptr, name.len, text.ptr, @intCast(text.len), &result);

    if (status != wire.ok) {
        return wire.error_of(status);
    }

    const html = guest.take(result);
    defer std.heap.wasm_allocator.free(html);

    try writer.writeAll(html);
}

/// Draws a node prop where the view runs, for the wire.
const Nodes = struct {
    arena: std.mem.Allocator,

    pub fn node(nodes: Nodes, given: anytype) view_wire.Error![]const u8 {
        std.debug.assert(given.raw != null or given.render_fn != null);

        var out: std.Io.Writer.Allocating = .init(nodes.arena);

        given.render(&out.writer, nodes.arena, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WriteFailed,
        };

        return out.written();
    }
};

fn as_error(err: anyerror) Error {
    std.debug.assert(@errorName(err).len > 0);

    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Denied => error.Denied,
        error.NotFound => error.NotFound,
        else => error.Invalid,
    };
}
