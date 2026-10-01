//! Runs a generated view and sends it. `View` is one of the `views.*` namespaces
//! the build generates from `ui/**/*.ptsx`; `props` is its `Props`, checked at compile
//! time, so a wrong or missing prop is a compile error.
const std = @import("std");
const http = @import("../lib/http.zig");
const runtime = @import("runtime");

const Response = http.Response;
const Error = http.Error;
const Status = http.Status;

pub const page_bytes_max: u32 = 4 << 20;

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
        ) anyerror!void {
            try View.render(writer, inner, capture.props);
        }
    };
    const kept = arena.create(Capture) catch return error.OutOfMemory;

    kept.* = .{ .props = props };

    return runtime.block(kept, Body);
}

/// Several nodes as one, rendered one after another.
pub fn all(arena: std.mem.Allocator, nodes: []const Node) Error!Node {
    std.debug.assert(nodes.len <= 64);

    const Capture = struct { nodes: []const Node };
    const Body = struct {
        pub fn render(
            capture: Capture,
            writer: *std.Io.Writer,
            inner: std.mem.Allocator,
        ) anyerror!void {
            for (capture.nodes) |node| {
                try node.render(writer, inner);
            }
        }
    };
    const kept = arena.create(Capture) catch return error.OutOfMemory;

    kept.* = .{ .nodes = nodes };

    return runtime.block(kept, Body);
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

pub fn page(
    response: *Response,
    arena: std.mem.Allocator,
    status: Status,
    comptime View: type,
    props: View.Props,
) Error!void {
    std.debug.assert(response.body.len == 0);
    std.debug.assert(@hasDecl(View, "render"));

    var out: std.Io.Writer.Allocating = .init(arena);

    // JSX has no doctype; every page starts with one here.
    out.writer.writeAll("<!doctype html>\n") catch return error.OutOfMemory;
    View.render(&out.writer, arena, props) catch return error.OutOfMemory;

    std.debug.assert(out.written().len <= page_bytes_max);

    try response.html(status, out.written());
}
