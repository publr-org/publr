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

extern "env" fn publr_frame(base_ptr: [*]const u8, base_len: u32, result: *wire.Result) u32;
extern "env" fn publr_render(
    name_ptr: [*]const u8,
    name_len: u32,
    props_ptr: [*]const u8,
    props_len: u32,
    result: *wire.Result,
) u32;

/// The page `View` draws with `props`, in the plugin frame under `base`, doctype first. A
/// view declaring `ctx` gets it with its props: who is looking and the page. A number prop
/// takes an integer as it is.
pub fn render(
    ctx: anytype,
    base: []const u8,
    comptime View: type,
    props: anytype,
) Error![]const u8 {
    std.debug.assert(base.len == 0 or base[0] == '/');
    comptime std.debug.assert(@hasDecl(View, "render"));

    if (comptime guest.mode == .native) {
        const admin = @import("../../adapters/admin.zig");
        const request = admin.chrome.in_plugin_frame(ctx, base) catch return error.OutOfMemory;
        const full = props_of(View.Props, props, ctx.inner.view);

        return admin.render.document(ctx.arena(), request, View, full) catch error.OutOfMemory;
    }

    var result: wire.Result = .{
        .ptr = 0,
        .len = 0,
    };
    const status = publr_frame(base.ptr, @intCast(base.len), &result);

    if (status != wire.ok) {
        return wire.error_of(status);
    }

    const told = guest.take(result);
    defer std.heap.wasm_allocator.free(told);

    const looking = std.json.parseFromSliceLeaky(Looking, ctx.arena(), told, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.Invalid;
    var out: std.Io.Writer.Allocating = .init(ctx.arena());

    // JSX has no doctype; every page starts with one, as compiled in.
    out.writer.writeAll("<!doctype html>\n") catch return error.OutOfMemory;
    View.render(&out.writer, ctx.arena(), props_of(View.Props, props, looking)) catch |err| {
        return as_error(err);
    };

    return out.written();
}

const Looking = @import("../context.zig").View;

/// `props` as the view's `Props`: each prop from `props`, an integer where a number is asked
/// taken as it is, else its default; `ctx` from `looking`.
fn props_of(comptime Props: type, props: anytype, looking: Looking) Props {
    const Given = @TypeOf(props);
    var full: Props = undefined;

    inline for (@typeInfo(Props).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "ctx")) {
            @field(full, field.name) = ctx_of(field.type, looking);
        } else if (@hasField(Given, field.name)) {
            @field(full, field.name) = number_or(field.type, @field(props, field.name));
        } else if (comptime field.defaultValue() != null) {
            @field(full, field.name) = comptime field.defaultValue().?;
        } else {
            @compileError("the view's prop ." ++ field.name ++ " is not given");
        }
    }

    inline for (@typeInfo(Given).@"struct".fields) |field| {
        if (!@hasField(Props, field.name)) {
            @compileError("the view has no prop ." ++ field.name);
        }
    }

    return full;
}

/// `value` as a prop of type `Prop`: an integer for a number converted.
fn number_or(comptime Prop: type, value: anytype) Prop {
    const number = Prop == f64 or Prop == ?f64;

    comptime std.debug.assert(@typeInfo(Prop) != .void);

    if (comptime number and @typeInfo(@TypeOf(value)) == .int) {
        return @floatFromInt(value);
    }

    return value;
}

/// The view's `ctx` as it declares it: `person` and `page` filled from `looking`; what only
/// the browser has (`query`, `call`, `navigate`) is null here.
fn ctx_of(comptime Ctx: type, looking: Looking) Ctx {
    var out: Ctx = undefined;

    inline for (@typeInfo(Ctx).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "person")) {
            @field(out, field.name) = part_of(field.type, looking.person);
        } else if (comptime std.mem.eql(u8, field.name, "page")) {
            @field(out, field.name) = part_of(field.type, looking.page);
        } else if (comptime @typeInfo(field.type) == .optional) {
            @field(out, field.name) = null;
        } else {
            @compileError("a view's ctx has person, page, query, call and navigate, not ." ++
                field.name);
        }
    }

    return out;
}

fn part_of(comptime Part: type, from: anytype) Part {
    var out: Part = undefined;

    comptime std.debug.assert(@typeInfo(Part) == .@"struct");

    inline for (@typeInfo(Part).@"struct".fields) |field| {
        @field(out, field.name) = @field(from, field.name);
    }

    return out;
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

test "a view's props take an integer count as it is, and its ctx is who is looking" {
    const Props = struct {
        total: f64,
        title: []const u8 = "Notes",
        ctx: struct {
            person: struct {
                name: []const u8,
            },
            page: struct {
                path: []const u8,
                query: []const u8,
            },
            query: ?[]const u8,
        },
    };
    const count: u32 = 3;
    const full = props_of(Props, .{
        .total = count,
    }, .{
        .person = .{
            .name = "Ann",
            .email = "ann@example.com",
        },
        .page = .{
            .path = "log",
            .query = "week=2",
        },
    });

    try std.testing.expectEqual(@as(f64, 3), full.total);
    try std.testing.expectEqualStrings("Notes", full.title);
    try std.testing.expectEqualStrings("Ann", full.ctx.person.name);
    try std.testing.expectEqualStrings("week=2", full.ctx.page.query);
    try std.testing.expect(full.ctx.query == null);
}
