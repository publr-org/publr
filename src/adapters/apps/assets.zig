//! `<mount>/_app/<path>`: an app's public files from disk, its generated client code from
//! memory, and its compiled stylesheet. Only generated assets carry an immutable fingerprint.

const std = @import("std");
const http = @import("../../lib/http.zig");
const apps_adapter = @import("../apps.zig");
const context_module = @import("context.zig");
const state = @import("state.zig");
const media = @import("media.zig");

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;

pub const prefix = context_module.assets_prefix;
pub const immutable_max_age: u32 = 365 * 24 * 60 * 60;

/// `inside` is the path inside the app, `/_app/...`.
pub fn serve(
    app: *const state.App,
    inside: []const u8,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) anyerror!void {
    std.debug.assert(std.mem.startsWith(u8, inside, prefix));
    std.debug.assert(ctx.user_data != null);

    if (request.method() != .get and request.method() != .head) {
        return response.text(.not_found, "Not Found");
    }

    const path = inside[prefix.len..];
    const stylesheet = std.mem.eql(u8, path, context_module.stylesheet);

    if (path.len == 0) {
        return response.text(.not_found, "Not Found");
    }

    if (!stylesheet and app.asset(path) == null) {
        return serve_public(app, path, request, response, ctx);
    }

    const token = http.Form.query_param(ctx.arena, request.query(), "v");
    const max_age: u32 = if (app.fingerprinted(token)) immutable_max_age else 0;

    try apps_adapter.serve(response, app, .memory, .{ .max_age = max_age });

    if (stylesheet) {
        return response.set_body(.ok, "text/css; charset=utf-8", app.css);
    }

    const data = app.asset(path) orelse return response.text(.not_found, "Not Found");

    try response.set_body(.ok, http.static.content_type(path), data);
}

/// Passthrough files have no generated fingerprint or content-hash cache: the copy the
/// build made, or the app's own `public/` when there is none (or under `--dev`).
fn serve_public(
    app: *const state.App,
    path: []const u8,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(app.options.output_dir.len > 0);

    if (@import("builtin").target.cpu.arch == .wasm32) {
        return response.text(.not_found, "Not Found");
    }

    const root = if (app.output != null and !app.options.dev)
        try std.fmt.allocPrint(ctx.arena, "{s}/{s}/_app", .{
            app.options.output_dir,
            app.spec.name,
        })
    else
        try app.public_dir(ctx.arena);

    if (request.header("Range") != null) {
        return media.serve(request, response, ctx, app, root, path);
    }

    const slashed = try std.fmt.allocPrint(ctx.arena, "/{s}", .{path});
    const result = try http.static.serve_file(
        root,
        slashed,
        response,
        ctx.arena,
        ctx.options.response_bytes_max,
    );

    switch (result) {
        .served => try apps_adapter.serve(response, app, .file, .{}),
        .not_found => try response.text(.not_found, "Not Found"),
        .too_large => try response.text(.internal_server_error, "file exceeds response cap"),
    }
}
