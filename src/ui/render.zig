//! Runs a generated view and sends it. `View` is one of the `views.*` namespaces
//! the build generates from `ui/**/*.ptsx`; `props` is its `Props`, checked at compile
//! time, so a wrong or missing prop is a compile error.
const std = @import("std");
const http = @import("../lib/http.zig");
const runtime = @import("runtime");
const request_module = @import("request");
pub const Runner = @import("expressions.zig").Runner;
const admin_expressions = @embedFile("admin_expressions");

const Response = http.Response;
const Error = http.Error;
const Status = http.Status;

pub const page_bytes_max: u32 = 4 << 20;
/// What a page's writer starts with: every admin page so far fits, the largest editor too.
pub const page_bytes_first: u32 = 1 << 20;

/// What a view reads as `Publr.request`: handed to the page's root, which hands it down.
pub const Request = request_module.Request;

/// What a view's `node` prop takes: markup that renders into the page's writer when the
/// view reaches it. A view nested in another streams through `rt.block` in the generated
/// code; markup this adapter rendered ahead of time goes in as `node`.
pub const Node = runtime.Node;

/// A view as a node for another view's `node` prop: rendered into the page's writer when
/// the page reaches it, never into a string of its own. The props live in the arena for
/// the render to read.
pub fn view(arena: std.mem.Allocator, comptime View: type, props: View.Props) Error!Node {
    std.debug.assert(@hasDecl(View, "render"));
    std.debug.assert(page_bytes_max > 0);

    const Capture = struct {
        props: View.Props,
    };
    const Body = struct {
        pub fn render(
            capture: Capture,
            writer: *std.Io.Writer,
            inner: std.mem.Allocator,
            request: ?*const anyopaque,
        ) anyerror!void {
            var handed = capture.props;

            // The page's request, from whichever of its components draws this node.
            handed.publr_request = request;
            try View.render(writer, inner, handed);
        }
    };
    const kept = arena.create(Capture) catch return error.OutOfMemory;

    kept.* = .{
        .props = props,
    };

    return runtime.viewed(kept, Body);
}

/// A node whose body runs only when the page reaches it: `Body.render(capture, writer,
/// arena, request)` with the capture kept in the arena and the page's request.
pub const lazy = runtime.viewed;
/// Markup written as it is: only for HTML already made safe (`lib/sanitize.zig`).
pub const raw = runtime.raw;

/// Several nodes as one, rendered one after another.
pub fn all(arena: std.mem.Allocator, nodes: []const Node) Error!Node {
    std.debug.assert(nodes.len <= 64);

    const Capture = struct {
        nodes: []const Node,
    };
    const Body = struct {
        pub fn render(
            capture: Capture,
            writer: *std.Io.Writer,
            inner: std.mem.Allocator,
            request: ?*const anyopaque,
        ) anyerror!void {
            for (capture.nodes) |node| {
                try node.render(writer, inner, .{
                    .request = request,
                });
            }
        }
    };
    const kept = arena.create(Capture) catch return error.OutOfMemory;

    kept.* = .{
        .nodes = nodes,
    };

    return runtime.viewed(kept, Body);
}

/// A request with nothing of a signed-in page but the engine for compiled expressions:
/// for a fragment, or an app's component, rendered with no page around it.
pub fn engine_request(runner: *const Runner) Request {
    std.debug.assert(runner.expressions.context == @as(*const anyopaque, runner));

    return .{
        .session = .{
            .name = "",
            .email = "",
            .csrf = "",
            .avatar = "",
        },
        .admin = .{
            .base = "",
            .path = "",
            .area = "",
            .can_structure = false,
            .can_settings = false,
            .top_bar = null,
            .sidebar = null,
        },
        .publr_expressions = &runner.expressions,
    };
}

/// A node as a string: the answer to a request for the fragment alone.
pub fn to_html(arena: std.mem.Allocator, node: Node) Error![]const u8 {
    std.debug.assert(page_bytes_max > 0);
    std.debug.assert(node.raw != null or node.render_fn != null);

    // A fragment has no page around it: its views get a request that carries the
    // engine for their compiled expressions and nothing of a signed-in page.
    const runner = Runner.create(arena, admin_expressions) catch return error.OutOfMemory;
    defer runner.deinit();

    const request = engine_request(runner);
    var out: std.Io.Writer.Allocating = .init(arena);

    node.render(&out.writer, arena, .{
        .request = &request,
    }) catch return error.OutOfMemory;

    return out.written();
}

/// A view rendered to a string, for a fragment answer or a body the adapter splices.
pub fn html(arena: std.mem.Allocator, comptime View: type, props: View.Props) Error![]const u8 {
    std.debug.assert(@hasDecl(View, "render"));
    std.debug.assert(page_bytes_max > 0);

    var out: std.Io.Writer.Allocating = .init(arena);
    const runner = Runner.create(arena, admin_expressions) catch return error.OutOfMemory;
    defer runner.deinit();
    var templates: runtime.Templates = .{
        .gpa = arena,
    };
    defer templates.deinit();

    var handed = props;

    if (props.publr_request) |given| {
        const with_engine = arena.create(Request) catch return error.OutOfMemory;

        with_engine.* = @as(*const Request, @ptrCast(@alignCast(given))).*;
        with_engine.publr_expressions = &runner.expressions;
        with_engine.publr_templates = &templates;
        runner.base = with_engine.admin.base;
        runner.catalogue = with_engine.publr_catalogue;
        handed.publr_request = with_engine;
    }

    View.render(&out.writer, arena, handed) catch return error.OutOfMemory;

    return out.written();
}

/// What every page is drawn by. A page fills one of these and sets no frame of its own:
/// the chrome, the bands, the gutters and the empty states are theirs.
pub const layouts = [_][]const u8{
    "IndexPage",
    "FormPage",
    "HubPage",
    "CardPage",
    "ListDetailPage",
    "FramePage",
    "WorkspacePage",
    "AroundPage",
    "PanelPage",
};

fn is_layout(comptime name: []const u8) bool {
    comptime {
        std.debug.assert(layouts.len == 9);

        for (layouts) |layout| {
            if (std.mem.eql(u8, layout, name)) {
                return true;
            }
        }

        return false;
    }
}

pub fn page(
    response: *Response,
    arena: std.mem.Allocator,
    request: *const Request,
    status: Status,
    comptime View: type,
    props: View.Props,
) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(@hasDecl(View, "render"));

    // Drawn where it is sent from: the page is never also held in the arena.
    if (response.body_room.len > 0) {
        var writer: std.Io.Writer = .fixed(response.body_room);

        draw(&writer, arena, request, View, props) catch |err| switch (err) {
            error.WriteFailed => return error.BodyTooLarge,
            else => return err,
        };

        return response.html(status, writer.buffered());
    }

    try response.html(status, try document(arena, request, View, props));
}

/// The page, doctype first, as `page` sends it: for a page shown elsewhere, a plugin's in
/// its frame.
pub fn document(
    arena: std.mem.Allocator,
    request: *const Request,
    comptime View: type,
    props: View.Props,
) Error![]const u8 {
    std.debug.assert(@hasDecl(View, "render"));

    comptime {
        if (!is_layout(View.root_component)) {
            @compileError("a page is drawn by one of the layouts (IndexPage, FormPage, " ++
                "HubPage, CardPage, ListDetailPage, FramePage, WorkspacePage, AroundPage, " ++
                "PanelPage); " ++
                "this one's root is \"" ++
                View.root_component ++ "\"");
        }
    }

    // Room for a whole page up front: grown a step at a time, every outgrown buffer would
    // stay in the request's arena until the request ends (2-3 times the page in all).
    var out = std.Io.Writer.Allocating.initCapacity(arena, page_bytes_first) catch {
        return error.OutOfMemory;
    };

    draw(&out.writer, arena, request, View, props) catch return error.OutOfMemory;

    std.debug.assert(out.written().len <= page_bytes_max);

    return out.written();
}

/// The page into `writer`, doctype first.
fn draw(
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    request: *const Request,
    comptime View: type,
    props: View.Props,
) (Error || error{WriteFailed})!void {
    std.debug.assert(@hasDecl(View, "render"));

    var handed = props;
    const runner = Runner.create(arena, admin_expressions) catch return error.OutOfMemory;
    defer runner.deinit();

    var with_engine = request.*;
    var templates: runtime.Templates = .{
        .gpa = arena,
    };
    defer templates.deinit();

    with_engine.publr_expressions = &runner.expressions;
    with_engine.publr_templates = &templates;
    runner.base = request.admin.base;
    runner.catalogue = request.publr_catalogue;
    handed.publr_request = &with_engine;

    // JSX has no doctype; every page starts with one here.
    try writer.writeAll("<!doctype html>\n");
    View.render(writer, arena, handed) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => return error.OutOfMemory,
    };
}
