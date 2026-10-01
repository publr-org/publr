//! `<mount>/_app/<path>`: an app's generated client code and its compiled stylesheet, from
//! memory, immutable when fingerprinted. Public files are at their own paths (`public.zig`).

const std = @import("std");
const http = @import("../../lib/http.zig");
const apps_adapter = @import("../apps.zig");
const context_module = @import("context.zig");
const state = @import("state.zig");

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
        return response.text(.not_found, "Not Found");
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
