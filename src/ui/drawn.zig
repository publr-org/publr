//! What the host draws for an installed plugin's view: one design-system component, or one
//! of the admin's layouts and components, by name, its props off the wire. The view runs in
//! the plugin; each component it reaches is drawn here, natively, with the frame's request,
//! so the plugin carries none of them and its page reads like a compiled-in one.
const std = @import("std");
const runtime = @import("runtime");
const views = @import("views");
const render = @import("render.zig");
const view_wire = @import("../sdk/plugin/view_wire.zig");

const admin_expressions = @embedFile("admin_expressions");

pub const Error = error{ NotFound, Invalid, OutOfMemory };

/// What every component of one call into the plugin draws with: the frame's request, one
/// engine for its compiled expressions and one set of templates, made on the first.
pub const Drawing = struct {
    request: render.Request,
    runner: *render.Runner,
    templates: runtime.Templates,

    pub fn start(arena: std.mem.Allocator, frame: *const render.Request) Error!*Drawing {
        std.debug.assert(frame.admin.framed);

        const drawing = try arena.create(Drawing);

        drawing.* = .{
            .request = frame.*,
            .runner = try render.Runner.create(arena, admin_expressions),
            .templates = .{
                .gpa = arena,
            },
        };
        drawing.request.publr_expressions = &drawing.runner.expressions;
        drawing.request.publr_templates = &drawing.templates;
        drawing.runner.base = frame.admin.base;
        drawing.runner.catalogue = frame.publr_catalogue;

        return drawing;
    }

    pub fn deinit(drawing: *Drawing) void {
        std.debug.assert(drawing.request.publr_expressions != null);

        drawing.templates.deinit();
        drawing.runner.deinit();
    }
};

/// Whether an installed plugin's view may have `name` drawn.
pub fn callable(name: []const u8) bool {
    std.debug.assert(views.callable.names.len > 0);

    for (views.callable.names) |listed| {
        if (std.mem.eql(u8, listed, name)) {
            return true;
        }
    }

    return false;
}

/// `name` drawn with the props the wire carries; `NotFound` for a name the plugin may not
/// draw, `Invalid` for props that are not its.
pub fn draw(
    drawing: *Drawing,
    arena: std.mem.Allocator,
    name: []const u8,
    props: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(drawing.request.publr_expressions != null);

    inline for (views.callable.names) |listed| {
        if (std.mem.eql(u8, listed, name)) {
            return draw_one(@field(views, listed), drawing, arena, props);
        }
    }

    return error.NotFound;
}

fn draw_one(
    comptime View: type,
    drawing: *Drawing,
    arena: std.mem.Allocator,
    text: []const u8,
) Error![]const u8 {
    std.debug.assert(text.len > 0);

    var props = view_wire.decode(arena, View.Props, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Invalid,
    };
    var out: std.Io.Writer.Allocating = .init(arena);

    props.publr_request = &drawing.request;
    View.render(&out.writer, arena, props) catch return error.OutOfMemory;

    std.debug.assert(out.written().len <= render.page_bytes_max);

    return out.written();
}

test "a component drawn off the wire is the same markup as drawn in the process" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const runner = try render.Runner.create(arena, admin_expressions);
    defer runner.deinit();
    var frame = render.engine_request(runner);

    frame.admin.framed = true;

    const drawing = try Drawing.start(arena, &frame);
    defer drawing.deinit();

    const wired = try draw(drawing, arena, "Status", "{\"tone\":\"success\"," ++
        "\"children\":\"Noted\"}");
    var out: std.Io.Writer.Allocating = .init(arena);

    try views.Status.render(&out.writer, arena, .{
        .tone = .success,
        .children = runtime.raw("Noted"),
        .publr_request = &drawing.request,
    });
    try std.testing.expectEqualStrings(out.written(), wired);
    try std.testing.expect(std.mem.indexOf(u8, wired, "Noted") != null);
    try std.testing.expect(callable("IndexPage"));
    try std.testing.expect(!callable("Content"));
    try std.testing.expectError(error.NotFound, draw(drawing, arena, "Content", "{}"));
    try std.testing.expectError(error.Invalid, draw(drawing, arena, "Status", "[]"));
}
