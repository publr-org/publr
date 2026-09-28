//! `<mount>/_islands/<key>`: one fragment per (component, props) a call site declared. A static
//! island is the file the build wrote, cacheable, cookieless and CORS-open; a dynamic one
//! is rendered per request, refuses cross-site fetches, is `no-store` and varies by cookie.
//! `<mount>/_islands/?keys=a,b,c` answers several dynamic fragments in one response.

const std = @import("std");
const http = @import("../../lib/http.zig");
const sdk = @import("../../sdk.zig");
const apps_adapter = @import("../apps.zig");
const context_module = @import("context.zig");
const pages = @import("pages.zig");
const delivery = @import("delivery.zig");
const middleware = @import("middleware.zig");
const edge = @import("edge.zig");
const build = @import("build.zig");
const Project = @import("../../server/project.zig").Project;
const identity_module = @import("../rest/identity.zig");
const App = @import("state.zig").App;
const Island = @import("../../template.zig").Island;

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;
const Context = context_module.Context;

pub const islands_prefix = context_module.islands_prefix;
pub const batch_keys_max: u32 = 32;

/// `<mount>/_islands/<key>` of the app `target` names, after the app's middleware.
pub fn island(
    project: *const Project,
    target: Project.Target,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) anyerror!void {
    std.debug.assert(std.mem.startsWith(u8, target.path, islands_prefix));
    std.debug.assert(ctx.user_data != null);

    const app = target.app;

    if (try middleware.answer(project, app, target.path, ctx.arena, request, response)) {
        return;
    }

    if (!app.build_ready) {
        return pages.unavailable(response);
    }

    if (app.program == null or request.method() != .get and request.method() != .head) {
        try apps_adapter.serve_as(response, app, .memory);

        return response.text(.not_found, "Not Found");
    }

    const key = target.path[islands_prefix.len..];

    if (key.len == 0) {
        if (http.Form.query_param(ctx.arena, request.query(), "keys")) |keys| {
            return batch(app, project, request, response, ctx, keys);
        }
    }

    const found = app.pages().find_island(key) orelse {
        // Bare `/_islands/` is the batch's path: a cache that ignores the query must never
        // keep a 404 there in place of the batches.
        try apps_adapter.serve_as(response, app, if (key.len == 0) .render else .memory);

        return response.text(.not_found, "Not Found");
    };

    const door = try delivery.door(project, ctx.arena, request, response, .island);

    if (door == .refused) {
        return;
    }

    if (door == .private) {
        return private_island(app, project, request, response, ctx, found);
    }

    if (found.dynamic) {
        return dynamic_island(app, project, request, response, ctx, found);
    }

    return static_island(app, project, key, request, response, ctx, found);
}

/// A public, static island: the built file when the last build wrote it, else rendered now.
fn static_island(
    app: *App,
    project: *const Project,
    key: []const u8,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
    found: *const Island,
) anyerror!void {
    std.debug.assert(!found.dynamic);
    std.debug.assert(app.build_ready);

    try response.set_header("Access-Control-Allow-Origin", "*");

    if (build.built_island(app, ctx.arena, key)) |html| {
        const cache: apps_adapter.Cache = .{ .max_age = found.max_age };
        const url = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ islands_prefix, key });

        try edge.tag(response, app, ctx.arena, url);

        return apps_adapter.serve_file(request, response, app, .ok, html, cache);
    }

    try apps_adapter.serve_as(response, app, .render);

    const html = try pages.render_fragment(ctx.arena, app, found, .{
        .arena = ctx.arena,
        .project = project,
        .app = app,
        .request = request,
    });

    try response.set_body(.ok, "text/html; charset=utf-8", html);
}

/// A dynamic island: rendered for this visitor, same-site only, never kept.
fn dynamic_island(
    app: *App,
    project: *const Project,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
    found: *const Island,
) anyerror!void {
    std.debug.assert(found.dynamic);
    std.debug.assert(ctx.user_data != null);

    if (cross_site(request)) {
        return response.text(.forbidden, "Forbidden");
    }

    try apps_adapter.serve(response, app, .render, .{ .max_age = found.max_age });
    try response.set_header("Vary", "Cookie");

    const identity = identity_module.identify(request, ctx.arena, project);
    const now_ms = sdk.context.wall_clock_ms(project.io);

    identity_module.repair_hint(project, request, response, ctx.arena, &identity, now_ms);

    const html = try pages.render_fragment(ctx.arena, app, found, .{
        .arena = ctx.arena,
        .project = project,
        .app = app,
        .request = request,
        .live = true,
        .caller = Context.visitor(project, app, ctx.arena, request),
    });

    return response.set_body(.ok, "text/html; charset=utf-8", html);
}

/// One `<template patchfor>` per key it recognises, the strictest policy of anything that
/// can be in it. Unknown keys are skipped.
fn batch(
    app: *App,
    project: *const Project,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
    keys: []const u8,
) anyerror!void {
    std.debug.assert(keys.len > 0);
    std.debug.assert(ctx.user_data != null);

    if (cross_site(request)) {
        return response.text(.forbidden, "Forbidden");
    }

    const door = try delivery.door(project, ctx.arena, request, response, .island);

    if (door == .refused) {
        return;
    }

    const caller = Context.visitor(project, app, ctx.arena, request);
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    var asked = std.mem.splitScalar(u8, keys, ',');
    var wanted: u32 = 0;

    while (asked.next()) |key| {
        if (key.len == 0) {
            continue;
        }

        wanted += 1;

        if (wanted > batch_keys_max) {
            break;
        }

        const found = app.pages().find_island(key) orelse continue;
        const built = if (found.dynamic) null else build.built_island(app, ctx.arena, key);
        const html = built orelse try pages.render_fragment(ctx.arena, app, found, .{
            .arena = ctx.arena,
            .project = project,
            .app = app,
            .request = request,
            .live = found.dynamic,
            .caller = if (found.dynamic) caller else .anonymous,
        });

        try out.writer.writeAll(html);
    }

    if (wanted == 0) {
        // Never kept: it shares its path, `/_islands/`, with every batch.
        try apps_adapter.serve_as(response, app, .render);

        return response.text(.not_found, "Not Found");
    }

    try apps_adapter.serve_as(response, app, .render);
    try response.set_header("Vary", "Cookie");
    try response.set_body(.ok, "text/html; charset=utf-8", out.written());

    if (door == .private) {
        try delivery.keep_private(response);
    }
}

/// An island a gate made private: rendered now for this visitor, never from the built file
/// a shared cache might hold, and kept private.
fn private_island(
    app: *App,
    project: *const Project,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
    found: *const Island,
) anyerror!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(found.key.len > 0);

    try apps_adapter.serve_as(response, app, .render);

    const html = try pages.render_fragment(ctx.arena, app, found, .{
        .arena = ctx.arena,
        .project = project,
        .app = app,
        .request = request,
        .live = found.dynamic,
        .caller = if (found.dynamic)
            Context.visitor(project, app, ctx.arena, request)
        else
            .anonymous,
    });

    try delivery.keep_private(response);
    try response.set_body(.ok, "text/html; charset=utf-8", html);
}

fn cross_site(request: *const Request) bool {
    std.debug.assert(request.path().len > 0);
    std.debug.assert(islands_prefix.len > 1);

    const from = request.header("sec-fetch-site") orelse return false;

    return std.mem.eql(u8, from, "cross-site");
}
