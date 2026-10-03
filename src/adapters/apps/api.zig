//! `<mount>/_api/<plugin>/<verb>`: an app's pages call `app.<plugin>.<verb>`, as the
//! visitor, with the app's own `ctx.app` and `.plugins` fence. An island posts JSON (with
//! `Publr-Request: 1`); a plain `<form>` posts its fields and is sent back with a 303 to its
//! `redirect` field, or to the page it came from. Only `app.*` operations: what a site may
//! do is what plugins mark safe for its users; core features are exposed on their own.

const std = @import("std");
const http = @import("../../lib/http.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const identity = @import("../rest/identity.zig");
const rest_auth = @import("../rest/auth.zig");
const cli = @import("../cli.zig");
const sandboxed_cli = @import("../cli/sandboxed_plugins.zig");
const context = @import("context.zig");
const visitor = @import("visitor.zig");
const Project = @import("../../server/project.zig").Project;
const Target = Project.Target;

const Request = http.Request;
const Response = http.Response;
const Form = http.Form;

pub const prefix = "/_api/";
pub const body_bytes_max: u32 = 1 << 20;
/// The header a fetch from the app's own pages sends: a page on another site cannot send
/// it without the browser asking first.
pub const request_header = "publr-request";

pub fn call(
    project: *const Project,
    target: Target,
    request: *Request,
    response: *Response,
    ctx: *http.Context,
) anyerror!void {
    std.debug.assert(std.mem.startsWith(u8, target.path, prefix));
    std.debug.assert(ctx.user_data != null);

    if (request.method() != .post) {
        return response.json(.method_not_allowed, .{ .@"error" = "use POST" });
    }

    if (identity.origin_of(request) != .same) {
        return response.json(.forbidden, .{ .@"error" = "cross_origin" });
    }

    const name = operation_of(ctx.arena, target.path[prefix.len..]) orelse {
        return response.json(.not_found, .{ .@"error" = "not_found" });
    };
    const content_type = request.header("content-type") orelse "";
    const as_form = std.mem.startsWith(u8, content_type, "application/x-www-form-urlencoded");

    if (!as_form and !std.mem.eql(u8, request.header(request_header) orelse "", "1")) {
        return response.json(.forbidden, .{ .@"error" = "publr_request_header_missing" });
    }

    if (request.body.len > body_bytes_max) {
        return response.json(.payload_too_large, .{ .@"error" = "too_large" });
    }

    const app = target.app;
    var sdk_ctx = identity.context(project, ctx.arena, context.identify(
        project,
        app,
        ctx.arena,
        request,
    ).caller);

    sdk_ctx.app = app.spec.name;
    sdk_ctx.app_plugins = app.spec.plugins;
    sdk_ctx.visitor = try visitor.ensure(project, request, response, ctx.arena);

    if (!as_form) {
        const input = if (request.body.len == 0) "{}" else request.body;
        const output = registry.SDK.call_json(&sdk_ctx, name, input) catch |err| {
            return rest_auth.respond_error(response, err, &sdk_ctx);
        };

        return response.set_body(.ok, "application/json", output);
    }

    return form_call(&sdk_ctx, name, request, response, target);
}

/// `cart/add` is `app.cart.add`; anything else names no operation an app may call.
fn operation_of(arena: std.mem.Allocator, rest: []const u8) ?[]const u8 {
    std.debug.assert(rest.len <= 4096);

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const plugin = rest[0..slash];
    const verb = rest[slash + 1 ..];

    if (!word(plugin) or !word(verb)) {
        return null;
    }

    return std.fmt.allocPrint(arena, "app.{s}.{s}", .{ plugin, verb }) catch null;
}

fn word(text: []const u8) bool {
    std.debug.assert(text.len <= 4096);

    if (text.len == 0 or text.len > 64) {
        return false;
    }

    for (text) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '_') {
            return false;
        }
    }

    return true;
}

/// A form's fields as the operation's flags, the way the CLI reads them; then a 303 back,
/// with `?error=<name>` when it was refused.
fn form_call(
    sdk_ctx: *sdk.Ctx,
    name: []const u8,
    request: *Request,
    response: *Response,
    target: Target,
) anyerror!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(request.body.len <= body_bytes_max);

    const arena = sdk_ctx.arena;
    const form = Form.parse(arena, request.body) orelse {
        return response.json(.bad_request, .{ .@"error" = "invalid_form" });
    };
    const back = back_of(&form, request, target);
    const input = try input_of(sdk_ctx, name, &form) orelse {
        return response.redirect(.see_other, try with_error(arena, back, "Invalid"));
    };

    _ = registry.SDK.call_json(sdk_ctx, name, input) catch |err| {
        // A plugin's refusal in its own words carries its own name: `?error=NotEnoughStock`.
        const own = if (err == error.Failed) sdk_ctx.failure else null;
        const shown = if (own) |failure| failure.name else @errorName(err);

        return response.redirect(.see_other, try with_error(arena, back, shown));
    };

    return response.redirect(.see_other, back);
}

/// The form's fields as JSON for the operation called `name`, parsed by its declared input;
/// null when they do not fit it.
fn input_of(sdk_ctx: *sdk.Ctx, name: []const u8, form: *const Form) !?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= Form.pairs_max);

    const arena = sdk_ctx.arena;
    var args: std.ArrayList([]const u8) = .empty;

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, "redirect")) {
            continue;
        }

        try args.append(arena, try std.fmt.allocPrint(arena, "--{s}", .{pair.name}));
        try args.append(arena, pair.value);
    }

    var problem: cli.Problem = .{};

    inline for (registry.SDK.operations) |Operation| {
        if (comptime std.mem.startsWith(u8, Operation.name, "app.")) {
            if (std.mem.eql(u8, Operation.name, name)) {
                const in = cli.parse_in(Operation.In, arena, args.items, &problem, null) catch {
                    return null;
                };

                return try sdk.stringify(arena, in);
            }
        }
    }

    const sandboxed = sdk_ctx.sandboxed_plugins orelse return null;
    const found = sandboxed.find(name) orelse return null;

    return sandboxed_cli.parse(arena, found, args.items, &problem) catch null;
}

/// Where a form goes after: its `redirect` field when it is a path on this site, else the
/// page it was posted from, else the app's home.
fn back_of(form: *const Form, request: *Request, target: Target) []const u8 {
    std.debug.assert(form.len <= Form.pairs_max);
    std.debug.assert(target.path.len > 0);

    if (form.text("redirect")) |path| {
        if (local(path)) {
            return path;
        }
    }

    const referer = request.header("referer") orelse "";
    const host = request.header("host") orelse "";

    if (std.mem.indexOf(u8, referer, host)) |at| {
        if (host.len > 0) {
            const path = referer[at + host.len ..];

            if (local(path)) {
                return path;
            }
        }
    }

    return home_of(target);
}

/// The app's own home: its mount's path, or `/` on its subdomain.
fn home_of(target: Target) []const u8 {
    std.debug.assert(target.path.len > 0);

    return switch (target.app.spec.mount) {
        .path => |path| if (path.len > 0) path else "/",
        .subdomain => "/",
    };
}

fn local(path: []const u8) bool {
    std.debug.assert(path.len <= 1 << 16);

    if (path.len == 0 or path[0] != '/') {
        return false;
    }

    return path.len == 1 or (path[1] != '/' and path[1] != '\\');
}

fn with_error(arena: std.mem.Allocator, back: []const u8, name: []const u8) ![]const u8 {
    std.debug.assert(back.len > 0);
    std.debug.assert(name.len > 0);

    const joiner: []const u8 = if (std.mem.indexOfScalar(u8, back, '?') == null) "?" else "&";

    return std.fmt.allocPrint(arena, "{s}{s}error={s}", .{ back, joiner, name });
}

test "paths: `<plugin>/<verb>` is `app.<plugin>.<verb>`, nothing else names an operation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("app.cart.add", operation_of(arena, "cart/add").?);
    try std.testing.expect(operation_of(arena, "cart") == null);
    try std.testing.expect(operation_of(arena, "cart/add/more") == null);
    try std.testing.expect(operation_of(arena, "Cart/add") == null);
    try std.testing.expect(operation_of(arena, "../record/save") == null);
    try std.testing.expect(local("/shop/cart"));
    try std.testing.expect(!local("//evil.example"));
    try std.testing.expect(!local("https://evil.example/"));
}

test "a visitor's call: in the sandbox as that visitor, kept for the app, fenced by it" {
    const internal = @import("../../operations/internal.zig");
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var first = project.ctx(.anonymous);
    first.app = "www";
    first.app_plugins = &.{"greeter"};
    first.visitor = "aaaaaaaaaaaaaaaaaaaaaaaa";

    _ = try registry.SDK.call_json(&first, "app.greeter.wave", "{}");
    const again = try registry.SDK.call_json(&first, "app.greeter.wave", "{}");
    try std.testing.expect(std.mem.indexOf(u8, again, "\"waves\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, again, "aaaaaaaaaaaaaaaaaaaaaaaa") != null);

    var second = first;
    second.visitor = "bbbbbbbbbbbbbbbbbbbbbbbb";
    const other = try registry.SDK.call_json(&second, "app.greeter.wave", "{}");
    try std.testing.expect(std.mem.indexOf(u8, other, "\"waves\":1") != null);

    var system = project.ctx(.system);
    const kept = try registry.SDK.dispatch(&system, internal.Find, .{
        .plugin = "greeter",
        .kind = "visit",
        .app = "www",
    });
    try std.testing.expectEqual(@as(usize, 3), kept.records.len);

    var nobody = project.ctx(.anonymous);
    nobody.app = "www";
    nobody.app_plugins = &.{"greeter"};
    const refused_in_words = registry.SDK.call_json(&nobody, "app.greeter.wave", "{}");
    try std.testing.expectError(error.Failed, refused_in_words);
    try std.testing.expectEqualStrings("NoVisitor", nobody.failure.?.name);
    try std.testing.expect(std.mem.indexOf(u8, nobody.failure.?.message, "no visitor") != null);

    var fenced = first;
    fenced.app_plugins = &.{"sampler"};
    const refused = registry.SDK.call_json(&fenced, "app.greeter.wave", "{}");
    try std.testing.expect(std.meta.isError(refused));
}
