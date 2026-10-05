//! Runs a generated view and sends it. `View` is one of the `views.*` namespaces
//! the build generates from `ui/**/*.ptsx`; `props` is its `Props`, checked at compile
//! time, so a wrong or missing prop is a compile error.
const std = @import("std");
const http = @import("../lib/http.zig");
const runtime = @import("runtime");
const request_module = @import("request");

const Response = http.Response;
const Error = http.Error;
const Status = http.Status;

pub const page_bytes_max: u32 = 4 << 20;

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

    const Capture = struct { props: View.Props };
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

    kept.* = .{ .props = props };

    return runtime.viewed(kept, Body);
}

/// A node whose body runs only when the page reaches it: `Body.render(capture, writer,
/// arena, request)` with the capture kept in the arena and the page's request.
pub const lazy = runtime.viewed;

/// Several nodes as one, rendered one after another.
pub fn all(arena: std.mem.Allocator, nodes: []const Node) Error!Node {
    std.debug.assert(nodes.len <= 64);

    const Capture = struct { nodes: []const Node };
    const Body = struct {
        pub fn render(
            capture: Capture,
            writer: *std.Io.Writer,
            inner: std.mem.Allocator,
            request: ?*const anyopaque,
        ) anyerror!void {
            for (capture.nodes) |node| {
                try node.render_with(writer, inner, request);
            }
        }
    };
    const kept = arena.create(Capture) catch return error.OutOfMemory;

    kept.* = .{ .nodes = nodes };

    return runtime.viewed(kept, Body);
}

/// A node as a string: the answer to a request for the fragment alone.
pub fn to_html(arena: std.mem.Allocator, node: Node) Error![]const u8 {
    std.debug.assert(page_bytes_max > 0);
    std.debug.assert(node.raw != null or node.render_fn != null);

    return runtime.render_to_string(arena, node) catch error.OutOfMemory;
}

/// A view rendered to a string, for a fragment answer or a body the adapter splices.
pub fn html(arena: std.mem.Allocator, comptime View: type, props: View.Props) Error![]const u8 {
    std.debug.assert(@hasDecl(View, "render"));
    std.debug.assert(page_bytes_max > 0);

    var out: std.Io.Writer.Allocating = .init(arena);

    View.render(&out.writer, arena, props) catch return error.OutOfMemory;

    return out.written();
}

/// What every page is drawn by. A page fills one of these and sets no frame of its own:
/// the chrome, the bands, the gutters and the empty states are theirs.
pub const layouts = [_][]const u8{ "IndexPage", "FormPage", "HubPage", "CardPage" };

fn is_layout(comptime name: []const u8) bool {
    comptime {
        std.debug.assert(layouts.len == 4);

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

    comptime {
        if (!is_layout(View.root_component)) {
            @compileError("a page is drawn by one of the layouts (IndexPage, FormPage, " ++
                "HubPage, CardPage); this one's root is \"" ++ View.root_component ++ "\"");
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var handed = props;

    handed.publr_request = request;

    // JSX has no doctype; every page starts with one here.
    out.writer.writeAll("<!doctype html>\n") catch return error.OutOfMemory;
    View.render(&out.writer, arena, handed) catch return error.OutOfMemory;

    std.debug.assert(out.written().len <= page_bytes_max);

    try response.html(status, out.written());
}
