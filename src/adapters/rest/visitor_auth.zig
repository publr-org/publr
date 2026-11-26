//! Visitors' own accounts on an app: `/api/auth/sign-up` and `/api/auth/reset`, each sending
//! a set-password link to the app's page for it (`user.sign_up`, `user.request_reset`).
//! Called from the site's own pages only; the body names the app the visitor is on.

const std = @import("std");
const registry = @import("../../server/registry.zig");
const visitors = @import("../../operations/user/visitors.zig");
const address = @import("../../model/app/address.zig");
const auth = @import("auth.zig");
const identity_module = @import("identity.zig");
const http = @import("../../lib/http.zig");
const sdk = @import("../../sdk.zig");
const Project = @import("../../server/project.zig").Project;

const Error = http.Error;
const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

pub fn sign_up(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const Body = struct {
        app: []const u8,
        user_type: []const u8,
        email: []const u8,
        display_name: []const u8,
        /// The language of the page asking (`pl`): the email's; the site's when left out.
        language: []const u8 = "",
    };

    return answer(Body, visitors.SignUp, request, response, ctx);
}

pub fn reset(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const Body = struct {
        app: []const u8,
        email: []const u8,
        language: []const u8 = "",
    };

    return answer(Body, visitors.RequestReset, request, response, ctx);
}

fn answer(
    comptime Body: type,
    comptime Operation: type,
    request: *Request,
    response: *Response,
    ctx: *Context,
) Error!void {
    std.debug.assert(@hasField(Body, "app"));
    std.debug.assert(Operation.name.len > 0);

    const project = Project.of(ctx);
    const identity = identity_module.identify(request, ctx.arena, project);

    if (!try identity_module.guard(request, response, project, &identity)) {
        return;
    }

    const body = auth.parse_body(Body, ctx.arena, request.body) orelse {
        return response.json(.bad_request, .{
            .@"error" = "invalid_body",
        });
    };
    var sdk_ctx = identity_module.request_context(project, request, ctx.arena, .anonymous);

    if (!try place(&sdk_ctx, project, request, body.app)) {
        return auth.respond_error(response, error.NotFound, &sdk_ctx);
    }

    if (language_code(body.language)) |code| {
        sdk_ctx.address_code = code;
    }

    var in: Operation.In = undefined;

    inline for (comptime std.meta.fieldNames(Operation.In)) |name| {
        @field(in, name) = @field(body, name);
    }

    const out = registry.SDK.dispatch(&sdk_ctx, Operation, in) catch |err| {
        return auth.respond_error(response, err, &sdk_ctx);
    };

    try response.json(.ok, out);
}

/// The call comes through the app named, at its address on this site.
fn place(
    sdk_ctx: *sdk.Ctx,
    project: *const Project,
    request: *Request,
    app: []const u8,
) error{OutOfMemory}!bool {
    std.debug.assert(project.apps.len <= 1 << 10);
    std.debug.assert(app.len <= 1 << 16);

    for (project.apps) |each| {
        if (!std.mem.eql(u8, each.spec.name, app)) {
            continue;
        }

        const host = request.header("host") orelse "";
        const origin = if (project.site_origin.len > 0)
            project.site_origin
        else
            try std.fmt.allocPrint(sdk_ctx.arena, "http://{s}", .{host});

        sdk_ctx.app = each.spec.name;
        sdk_ctx.app_plugins = each.spec.plugins;
        sdk_ctx.app_reach = each.spec.name;
        sdk_ctx.app_address = if (each.given)
            each.url
        else
            try address.app_address(sdk_ctx.arena, origin, each.spec.mount);

        return true;
    }

    return false;
}

/// A language code as pages write it (`pl`, `pt-br`); null for anything else.
fn language_code(text: []const u8) ?[]const u8 {
    std.debug.assert(text.len <= 1 << 16);

    if (text.len == 0 or text.len > 16) {
        return null;
    }

    for (text) |char| {
        if (!std.ascii.isLower(char) and char != '-') {
            return null;
        }
    }

    return text;
}

test "a page's language code, and nothing else" {
    try std.testing.expectEqualStrings("pt-br", language_code("pt-br").?);
    try std.testing.expect(language_code("") == null);
    try std.testing.expect(language_code("PL\n") == null);
}
