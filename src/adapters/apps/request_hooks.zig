//! The plugins' request hooks around one page: asked on the system's context, their headers
//! set, a redirect or refusal answered in the page's place, what they chose kept on the
//! target's place, checked against the site's dimensions.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const identity_module = @import("../rest/identity.zig");
const site_dimensions = @import("../../operations/dimensions.zig");
const model_dimension = @import("../../model/dimension.zig");
const Project = @import("../../server/project.zig").Project;
const request_data = @import("../../sdk/request_data.zig");
const registry = @import("../../server/registry.zig");
const visitor = @import("visitor.zig");

const Request = http.Request;
const Response = http.Response;
const PageRequest = sdk.page_request.PageRequest;

/// True when a hook answered in the page's place.
pub fn run(
    project: *const Project,
    target: *Project.Target,
    request: *Request,
    response: *Response,
    arena: std.mem.Allocator,
) !bool {
    std.debug.assert(target.path.len > 0);
    std.debug.assert(project.request_hooks.len <= sdk.page_request.hooks_max);

    if (try door(project, target, request, response, arena)) {
        return true;
    }

    if (project.request_hooks.len == 0) {
        return false;
    }

    var ctx = identity_module.context(project, arena, .system);
    var page: PageRequest = .{
        .path_text = target.path,
        .query_text = request.query(),
        .header_of = header_of,
        .source = request,
    };

    sdk.page_request.run_all(project.request_hooks, &ctx, &page);

    for (page.headers[0..page.headers_len]) |header| {
        try response.set_header(header.name, header.value);
    }

    switch (page.ending) {
        .next => {},
        .redirect => |redirect| {
            try response.set_header("Cache-Control", "no-store");
            try response.redirect(@fromBackingInt(@intCast(redirect.status)), redirect.to);

            return true;
        },
        .refuse => |status| {
            try response.set_header("Cache-Control", "no-store");
            try response.text(@fromBackingInt(@intCast(status)), "This page is not available.");

            return true;
        },
    }

    target.place.chosen = try chosen_of(&ctx, page.chosen_pairs());

    return false;
}

/// What plugins read at the door: a path under a prefix one answers runs its operation and
/// sends the visitor where it says; a landing bringing query parameters plugins read is kept
/// for the visitor. True when the visitor was sent elsewhere.
fn door(
    project: *const Project,
    target: *const Project.Target,
    request: *Request,
    response: *Response,
    arena: std.mem.Allocator,
) !bool {
    std.debug.assert(target.path.len > 0);
    std.debug.assert(project.connection.transaction_depth == 0);

    var ctx = identity_module.context(project, arena, .system);

    ctx.address = sdk.limits.address_of(arena, request.peer(), request.header("x-forwarded-for"));

    const referrer = request.header("referer") orelse "";

    if (try request_data.answering(&ctx, target.path)) |found| {
        const visitor_id = try visitor.ensure(project, request, response, arena);

        try request_data.record(&ctx, visitor_id, target.path, request.query(), referrer);

        return redirect_by(&ctx, found, visitor_id, target.path, response);
    }

    if (request.query().len == 0 or !try reads_queries(&ctx)) {
        return false;
    }

    const visitor_id = try visitor.ensure(project, request, response, arena);

    request_data.record(&ctx, visitor_id, target.path, request.query(), referrer) catch |err| {
        std.log.warn("visit not kept: {t}", .{err});
    };

    return false;
}

fn reads_queries(ctx: *sdk.Ctx) !bool {
    std.debug.assert(ctx.now_ms >= 0);

    for (try request_data.declared(ctx)) |one| {
        if (one.may_read and one.reads.query.len > 0) {
            return true;
        }
    }

    return false;
}

/// The plugin's operation answering a prefix, run as the plugin for the visitor: where it
/// sends them, a path on the site. One that fails, or names no path, leaves the page as is.
fn redirect_by(
    ctx: *sdk.Ctx,
    found: request_data.Answering,
    visitor_id: []const u8,
    path: []const u8,
    response: *Response,
) !bool {
    std.debug.assert(found.operation.len > 0);
    std.debug.assert(path.len > 0);

    const Answer = struct {
        to: []const u8 = "",
        status: u16 = 302,
    };

    ctx.plugin = found.plugin;
    ctx.visitor = visitor_id;

    const input = try std.json.Stringify.valueAlloc(ctx.arena, .{
        .path = path,
        .rest = found.rest,
    }, .{});
    const output = registry.SDK.call_json(ctx, found.operation, input) catch |err| {
        std.log.warn("{s} did not answer {s}: {t}", .{ found.operation, path, err });
        return false;
    };
    const answer = std.json.parseFromSliceLeaky(Answer, ctx.arena, output, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    const local = answer.to.len > 0 and answer.to[0] == '/' and
        (answer.to.len == 1 or (answer.to[1] != '/' and answer.to[1] != '\\'));
    const status: u16 = switch (answer.status) {
        301, 302, 303, 307, 308 => answer.status,
        else => 302,
    };

    if (!local) {
        return false;
    }

    try response.set_header("Cache-Control", "no-store");
    try response.redirect(@fromBackingInt(@intCast(status)), answer.to);

    return true;
}

fn header_of(source: *const anyopaque, name: []const u8) ?[]const u8 {
    const request: *const Request = @ptrCast(@alignCast(source));

    std.debug.assert(name.len > 0);

    return request.header(name);
}

/// What the hooks chose that the site has: each a dimension other than the one with pages
/// of its own (the address chooses that), at one of its codes; the main values left out.
fn chosen_of(
    ctx: *sdk.Ctx,
    chosen: []const model_dimension.Pair,
) ![]const model_dimension.Pair {
    std.debug.assert(chosen.len <= model_dimension.dimensions_max);

    var out: std.ArrayList(model_dimension.Pair) = .empty;

    for (chosen) |pair| {
        const dimension = site_dimensions.find(ctx, pair.dimension) orelse continue;

        if (dimension.addresses or pair.code.len == 0 or !model_dimension.valid_code(pair.code)) {
            continue;
        }

        const values = site_dimensions.values_of(ctx, dimension) catch continue;
        const known = for (values) |value| {
            if (!value.main and std.mem.eql(u8, value.code, pair.code)) {
                break true;
            }
        } else false;

        if (known) {
            try out.append(ctx.arena, .{
                .dimension = try ctx.arena.dupe(u8, pair.dimension),
                .code = try ctx.arena.dupe(u8, pair.code),
            });
        }
    }

    return out.items;
}
