//! `/_publr/toolbar?path=<page>`: what the toolbar a signed-in person sees on the site
//! offers for that page. The admin, always; the editor of the record the page renders, named
//! by its type ("Edit Post"), when the route reads one by its slug and the caller can
//! read it. Nobody signed in: nothing.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const content_type = @import("../../operations/content_type.zig");
const settings = @import("../../operations/settings.zig");
const registry = @import("../../app/registry.zig");
const engine = @import("../../theme.zig");
const build = @import("build.zig");
const Site = @import("../../app/site.zig").Site;
const Public = @import("state.zig").Public;

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;

pub const toolbar_path = "/_publr/toolbar";
pub const admin_path = "/admin";
pub const path_len_max: u32 = 1024;

const Answer = struct {
    signed_in: bool,
    name: []const u8 = "",
    admin: []const u8 = admin_path,
    /// The admin page that edits what this page shows; null when it shows no one record.
    edit: ?[]const u8 = null,
    /// What the edit link says: "Edit" and the record's type.
    edit_label: []const u8 = "",
};

const Edit = struct { url: []const u8, label: []const u8 };

pub fn toolbar(request: *Request, response: *Response, ctx: *HttpContext) anyerror!void {
    std.debug.assert(std.mem.eql(u8, request.path(), toolbar_path));
    std.debug.assert(ctx.user_data != null);

    const from = request.header("sec-fetch-site") orelse "";

    if (std.mem.eql(u8, from, "cross-site")) {
        return response.text(.forbidden, "Forbidden");
    }

    try response.set_header("Cache-Control", "no-store");
    try response.set_header("Vary", "Cookie");

    const site = Site.of(ctx);
    const identity = identity_module.identify(request, ctx.arena, site);

    if (identity.caller.user_id() == null) {
        return response.json(.ok, Answer{ .signed_in = false });
    }

    const path = http.Form.query_param(ctx.arena, request.query(), "path") orelse "/";
    var edit: ?Edit = null;

    if (site.public) |public| {
        edit = try edit_link(site, public, ctx.arena, identity, path);
    }

    return response.json(.ok, Answer{
        .signed_in = true,
        .name = if (identity.display_name.len > 0) identity.display_name else identity.email,
        .edit = if (edit) |found| found.url else null,
        .edit_label = if (edit) |found| found.label else "",
    });
}

/// The admin page for the record `path` renders, found the way the page finds it: the
/// route's `getEntry()` type and slug, read as the caller so the link is never to a record
/// they may not see.
fn edit_link(
    site: *const Site,
    public: *const Public,
    arena: std.mem.Allocator,
    identity: identity_module.Identity,
    path: []const u8,
) !?Edit {
    std.debug.assert(identity.caller.user_id() != null);

    if (path.len == 0 or path.len > path_len_max or path[0] != '/') {
        return null;
    }

    const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    const found = public.theme.match(trimmed) orelse return null;
    const template = &public.theme.templates[found.route.template];

    if (!template.compiled) {
        return null;
    }

    var sdk_ctx = identity_module.context(site, arena, identity.caller);

    if (homepage_of(template)) {
        return .{ .url = "/admin/settings", .label = try label_of(&sdk_ctx, settings.handle) };
    }

    const query = entry_query_of(template) orelse return null;
    const slug = query.slug orelse found.slug orelse return null;
    const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
        .type = query.type_id,
        .slug = slug,
        .limit = 1,
    }) catch return null;

    if (listed.records.len == 0) {
        return null;
    }

    return .{
        .url = try std.fmt.allocPrint(arena, "/admin/content/{s}", .{listed.records[0].id}),
        .label = try label_of(&sdk_ctx, query.type_id),
    };
}

/// "Edit " and the type's name as the admin shows it; its handle when it has none.
fn label_of(sdk_ctx: *sdk.Ctx, handle: []const u8) ![]const u8 {
    std.debug.assert(handle.len > 0);

    const row = content_type.find_raw(sdk_ctx, handle) catch null;
    const name = if (row) |found| found.def.name else handle;

    return std.fmt.allocPrint(sdk_ctx.arena, "Edit {s}", .{if (name.len > 0) name else handle});
}

fn entry_query_of(template: *const engine.Template) ?engine.ast.Decl.EntryQuery {
    std.debug.assert(template.compiled);
    std.debug.assert(build.entry_type_of(template) == null or template.decls.len > 0);

    for (template.decls) |decl| {
        switch (decl.value) {
            .entry => |query| return if (query.first) null else query,
            else => {},
        }
    }

    return null;
}

fn homepage_of(template: *const engine.Template) bool {
    std.debug.assert(template.compiled);

    for (template.decls) |decl| {
        if (decl.value == .context_entry) {
            return true;
        }
    }

    return false;
}
