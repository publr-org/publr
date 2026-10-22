//! Pinning a page to the person's rail, and taking it off, from the pin at the end of its
//! sidebar row; back to the page they were on.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const rail = @import("../../operations/rail.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;

pub const routes_count: u32 = 2;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.post("/admin/rail/pin", &pin);
    router.post("/admin/rail/unpin", &unpin);
}

pub fn pin(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    try change(request, response, ctx, true);
}

pub fn unpin(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    try change(request, response, ctx, false);
}

fn change(request: *Request, response: *Response, ctx: *Context, pinning: bool) Error!void {
    std.debug.assert(request.method() == .post);

    var post = try admin.accept(request, response, ctx, "/admin") orelse return;
    const session = &post.session;
    const back = back_of(post.form.get("back") orelse "");
    const plugin = post.form.get("plugin") orelse "";
    const page = post.form.get("page") orelse "";

    std.debug.assert(back.len > 0);

    const everyone = std.mem.eql(u8, post.form.get("for_everyone") orelse "", "1");
    const done = if (pinning)
        registry.SDK.dispatch(&session.ctx, rail.Pin, .{
            .plugin = plugin,
            .page = page,
            .for_everyone = everyone,
        })
    else
        registry.SDK.dispatch(&session.ctx, rail.Unpin, .{
            .plugin = plugin,
            .page = page,
            .for_everyone = everyone,
        });

    _ = done catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back);
}

/// Where to go back to: a page of the admin, or the overview.
fn back_of(asked: []const u8) []const u8 {
    std.debug.assert(asked.len <= 64 << 10);

    const inside = std.mem.startsWith(u8, asked, "/admin") and
        std.mem.indexOf(u8, asked, "//") == null and
        std.mem.indexOfAny(u8, asked, "\r\n\\") == null;

    return if (inside and asked.len <= 2048) asked else "/admin";
}

test "back to a page of the admin, never elsewhere" {
    try std.testing.expectEqualStrings("/admin/trash", back_of("/admin/trash"));
    try std.testing.expectEqualStrings("/admin", back_of("https://evil.example"));
    try std.testing.expectEqualStrings("/admin", back_of("/admin//evil.example"));
    try std.testing.expectEqualStrings("/admin", back_of(""));
}
