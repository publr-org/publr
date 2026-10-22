//! `<mount>/_actions/app.<plugin>.<verb>`: an app's pages call any operation a plugin made
//! with `publr.operation.define`, as the visitor, with the app's own `ctx.app` and
//! `.plugins` fence. Credentials and `.authorize` decide who gets through: without
//! `.untrusted_callers` only a signed-in person it lets in, an administrator being just a
//! signed-in person here. Only `.untrusted_callers` operations answer other sites' pages,
//! without cookies. An island posts JSON (with `Publr-Request: 1`); a plain `<form>` posts
//! its fields and is sent back with a 303 to its `redirect` field, or to the page it came
//! from. Core's own operations are exposed on their own.

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
const framed = @import("framed.zig");
const Project = @import("../../server/project.zig").Project;
const Target = Project.Target;

const Request = http.Request;
const Response = http.Response;
const Form = http.Form;

/// Where an app's pages call: `<mount>/_actions/app.<plugin>.<verb>`, the operation's name in
/// the address so core knows it before reading a byte of the body.
pub const actions_prefix = "/_actions/";
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
    std.debug.assert(ctx.user_data != null);

    std.debug.assert(std.mem.startsWith(u8, target.path, actions_prefix));

    const action = action_of(project, target.path[actions_prefix.len..]);
    const name = if (action) |found| found.name else null;

    // Another site's page asks first (OPTIONS) and calls without cookies, as an anonymous
    // visitor: only an operation for untrusted callers says yes.
    if (request.method() == .options) {
        const found = action orelse return not_found(response);

        return preflight(response, found.untrusted);
    }

    if (request.method() != .post) {
        return rest_auth.refuse(
            response,
            .method_not_allowed,
            "MethodNotAllowed",
            "Use POST: this operation changes something.",
        );
    }

    // The administrator's frame posts from an opaque origin, as a visitor (`framed.zig`).
    const same = identity.origin_of(request) == .same or framed.from_frame(request);
    const content_type = request.header("content-type") orelse "";
    const as_form = std.mem.startsWith(u8, content_type, "application/x-www-form-urlencoded");

    if (!as_form and !std.mem.eql(u8, request.header(request_header) orelse "", "1")) {
        return rest_auth.refuse(
            response,
            .forbidden,
            "Forbidden",
            "Send the Publr-Request: 1 header.",
        );
    }

    const found = name orelse return not_found(response);

    try response.set_header("Access-Control-Allow-Origin", "*");

    if (request.body.len > body_bytes_max) {
        return rest_auth.refuse(
            response,
            .payload_too_large,
            "TooBig",
            "This is too big.",
        );
    }

    const app = target.app;
    // From another site: nobody signed in, whatever cookies came, and the visitor the page
    // names; from the app's own pages: the request's own.
    const caller: sdk.Caller = if (same)
        context.identify(project, app, ctx.arena, request).caller
    else
        .anonymous;
    var sdk_ctx = identity.request_context(project, request, ctx.arena, caller);

    sdk_ctx.app = app.spec.name;
    sdk_ctx.app_plugins = app.spec.plugins;
    sdk_ctx.app_reach = app.spec.name;
    sdk_ctx.visitor = if (same)
        try visitor.ensure(project, request, response, ctx.arena)
    else
        visitor.of_header(request);

    if (!same and as_form) {
        return rest_auth.refuse(
            response,
            .unsupported_media_type,
            "UnsupportedMediaType",
            "Send JSON from another site.",
        );
    }

    if (!as_form) {
        const input = if (request.body.len == 0) "{}" else request.body;
        const output = registry.SDK.call_json(&sdk_ctx, found, input) catch |err| {
            return rest_auth.respond_error(response, err, &sdk_ctx);
        };

        try rest_auth.rate_headers(response, &sdk_ctx);

        return response.set_body(.ok, "application/json", output);
    }

    return form_call(&sdk_ctx, found, request, response, target);
}

fn not_found(response: *Response) anyerror!void {
    std.debug.assert(actions_prefix.len > 0);

    return rest_auth.refuse(
        response,
        .not_found,
        "NotFound",
        "No operation has this name here.",
    );
}

const Action = struct {
    name: []const u8,
    untrusted: bool,
};

/// `app.cart.add`: the operation `cart.add` when cart makes it with `publr.operation.define`;
/// null for anything else.
fn action_of(project: *const Project, rest: []const u8) ?Action {
    std.debug.assert(rest.len <= 4096);
    std.debug.assert(actions_prefix.len > 0);

    if (!std.mem.startsWith(u8, rest, "app.")) {
        return null;
    }

    const own = rest["app.".len..];
    const dot = std.mem.indexOfScalar(u8, own, '.') orelse return null;

    if (!word(own[0..dot]) or !word(own[dot + 1 ..])) {
        return null;
    }

    inline for (registry.SDK.operations) |Operation| {
        const defined = comptime @hasDecl(Operation, "untrusted_callers");

        if (defined and std.mem.eql(u8, Operation.name, own)) {
            return .{
                .name = own,
                .untrusted = Operation.untrusted_callers,
            };
        }
    }

    const installed = project.sandboxed_plugins orelse return null;
    const found = installed.find(own) orelse return null;
    const untrusted = found.untrusted_callers orelse return null;

    return .{
        .name = own,
        .untrusted = untrusted,
    };
}

/// The answer to another site's page asking whether it may call: yes, without cookies,
/// for an operation for untrusted callers only.
fn preflight(response: *Response, public: bool) anyerror!void {
    std.debug.assert(request_header.len > 0);

    if (!public) {
        return rest_auth.refuse(
            response,
            .forbidden,
            "Forbidden",
            "Only operations for untrusted callers answer other sites.",
        );
    }

    try response.set_header("Access-Control-Allow-Origin", "*");
    try response.set_header("Access-Control-Allow-Methods", "POST");
    try response.set_header(
        "Access-Control-Allow-Headers",
        "content-type, " ++ request_header ++ ", " ++ visitor.header_name,
    );
    try response.set_header("Access-Control-Max-Age", "86400");

    return response.text(.no_content, "");
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
        return rest_auth.refuse(
            response,
            .bad_request,
            "Invalid",
            "The form could not be read.",
        );
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
        if (comptime @hasDecl(Operation, "untrusted_callers")) {
            if (std.mem.eql(u8, Operation.name, name)) {
                const in = cli.parse_in(Operation.In, arena, args.items, &problem, .{}) catch {
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

test "addresses: a plugin and a verb, each a word; a redirect only to the site" {
    try std.testing.expect(word("cart"));
    try std.testing.expect(word("add_line"));
    try std.testing.expect(!word("Cart"));
    try std.testing.expect(!word(".."));
    try std.testing.expect(!word(""));
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

    _ = try registry.SDK.call_json(&first, "greeter.wave", "{}");
    const again = try registry.SDK.call_json(&first, "greeter.wave", "{}");
    try std.testing.expect(std.mem.indexOf(u8, again, "\"waves\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, again, "aaaaaaaaaaaaaaaaaaaaaaaa") != null);

    var second = first;
    second.visitor = "bbbbbbbbbbbbbbbbbbbbbbbb";
    const other = try registry.SDK.call_json(&second, "greeter.wave", "{}");
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
    const refused_in_words = registry.SDK.call_json(&nobody, "greeter.wave", "{}");
    try std.testing.expectError(error.Failed, refused_in_words);
    try std.testing.expectEqualStrings("NoVisitor", nobody.failure.?.name);
    try std.testing.expect(std.mem.indexOf(u8, nobody.failure.?.message, "no visitor") != null);

    var fenced = first;
    fenced.app_plugins = &.{"sampler"};
    const refused = registry.SDK.call_json(&fenced, "greeter.wave", "{}");
    try std.testing.expect(std.meta.isError(refused));
}

test "untrusted callers: an installed operation says so itself; the rest never are" {
    const internal = @import("../../operations/internal.zig");
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var anyone = project.ctx(.anonymous);
    anyone.app = "www";
    anyone.app_plugins = &.{"greeter"};
    anyone.visitor = "0123456789abcdef01234567";

    const installed = anyone.sandboxed_plugins.?;
    try std.testing.expect(installed.find("greeter.hail").?.untrusted_callers.?);
    try std.testing.expect(installed.find("greeter.wave").?.untrusted_callers.?);
    try std.testing.expect(installed.find("greeter.count").?.untrusted_callers == null);

    // Called as the visitor a page elsewhere names.
    const hailed = try registry.SDK.call_json(&anyone, "greeter.hail", "{}");
    try std.testing.expect(std.mem.indexOf(u8, hailed, "0123456789abcdef01234567") != null);
}
