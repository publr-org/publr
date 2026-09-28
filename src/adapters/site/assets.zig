//! `/theme/<path>`: public files from disk, generated client code from memory, and
//! the compiled stylesheet. Only generated assets carry an immutable fingerprint.

const std = @import("std");
const http = @import("../../lib/http.zig");
const site_adapter = @import("../site.zig");
const state = @import("state.zig");
const media = @import("media.zig");
const Site = @import("../../app/site.zig").Site;

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;

pub const prefix = "/theme/";
pub const immutable_max_age: u32 = 365 * 24 * 60 * 60;

pub fn serve(request: *Request, response: *Response, ctx: *HttpContext) anyerror!void {
    std.debug.assert(std.mem.startsWith(u8, request.path(), prefix));
    std.debug.assert(ctx.user_data != null);

    const site = Site.of(ctx);
    const public = site.public orelse return response.text(.not_found, "Not Found");
    const path = request.path()[prefix.len..];

    if (!std.mem.eql(u8, path, "theme.css") and public.asset(path) == null) {
        return serve_public(request, response, ctx, public);
    }

    const token = http.Form.query_param(ctx.arena, request.query(), "v");
    const max_age: u32 = if (public.fingerprinted(token)) immutable_max_age else 0;

    try site_adapter.serve(response, public, .memory, .{ .max_age = max_age });

    if (std.mem.eql(u8, path, "theme.css")) {
        return response.set_body(.ok, "text/css; charset=utf-8", public.css);
    }

    const data = public.asset(path) orelse return response.text(.not_found, "Not Found");

    try response.set_body(.ok, http.static.content_type(path), data);
}

/// Passthrough files have no generated fingerprint or content-hash cache.
fn serve_public(
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
    public: *const state.Public,
) !void {
    std.debug.assert(std.mem.startsWith(u8, request.path(), prefix));
    std.debug.assert(public.options.output_dir.len > 0);

    if (@import("builtin").target.cpu.arch == .wasm32) {
        return response.text(.not_found, "Not Found");
    }

    const root = if (public.output != null and !public.options.dev)
        try std.fmt.allocPrint(ctx.arena, "{s}/theme", .{public.options.output_dir})
    else
        state.public_dir;

    if (request.header("Range") != null) {
        return media.serve(request, response, ctx, public, root);
    }

    const result = try http.static.serve_file(
        root,
        request.path()[prefix.len - 1 ..],
        response,
        ctx.arena,
        ctx.options.response_bytes_max,
    );

    switch (result) {
        .served => try site_adapter.serve(response, public, .file, .{}),
        .not_found => try response.text(.not_found, "Not Found"),
        .too_large => try response.text(.internal_server_error, "file exceeds response cap"),
    }
}
