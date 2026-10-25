//! The plugins' request hooks around one page: asked on the system's context, their headers
//! set, a redirect or refusal answered in the page's place, what they chose kept on the
//! target's place, checked against the site's dimensions.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const identity_module = @import("../rest/identity.zig");
const variants = @import("../../operations/variants.zig");
const model_dimension = @import("../../model/dimension.zig");
const Project = @import("../../server/project.zig").Project;

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
            try response.redirect(@enumFromInt(redirect.status), redirect.to);

            return true;
        },
        .refuse => |status| {
            try response.set_header("Cache-Control", "no-store");
            try response.text(@enumFromInt(status), "This page is not available.");

            return true;
        },
    }

    target.place.chosen = try chosen_of(&ctx, page.chosen_pairs());

    return false;
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
        const dimension = variants.find(ctx, pair.dimension) orelse continue;

        if (dimension.addresses or pair.code.len == 0 or !model_dimension.valid_code(pair.code)) {
            continue;
        }

        const values = variants.values_of(ctx, dimension) catch continue;
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
