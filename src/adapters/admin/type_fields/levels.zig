//! The levels over a content type's fields: the kind picker and the field forms. Each is
//! a page of its own (a deep link draws the type's page with that one level over the
//! list; the stack is the page's script's, built from the way the editor came) and, asked
//! for with `Publr-Fragment: panel`, the panel alone, for the script to slide in; the
//! script names the level it slides over in `Publr-Below`, which the panel's Back reads.
const std = @import("std");
const spaces = @import("../schema_space.zig");
const admin = @import("../../admin.zig");
const model = @import("../../../model.zig");
const type_pages = @import("../types.zig");
const columns = @import("columns.zig");

const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const print = type_pages.print;

/// One level: the page it shows and its panel.
pub const Level = struct { url: []const u8, title: []const u8, panel: admin.render.Node };

/// Whether the request asks for the panel alone, for the page's script.
pub fn wants_panel(session: *const Session) bool {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.request.header("host") != null);

    const wanted = session.request.header("publr-fragment") orelse return false;

    return std.mem.eql(u8, wanted, "panel");
}

/// What the script says is under the level it asks for: the title its Back should carry.
/// Empty when the level is the first, or the request is a page load.
pub fn below(session: *const Session) []const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.request.header("host") != null);

    const title = session.request.header("publr-below") orelse return "";

    return title[0..@min(title.len, model.field.label_len_max)];
}

/// A write that went through, answered to the page's script: nothing to draw, go to `next`.
pub fn answer_moved(session: *Session, next: []const u8) Error!void {
    std.debug.assert(next.len > 0);
    std.debug.assert(wants_panel(session));

    session.response.set_header("Publr-Location", next) catch return error.OutOfMemory;

    try session.response.set_body(.ok, "text/html; charset=utf-8", "");
}

/// The level as the request wants it: the panel alone, or the type's page with the level
/// over the list.
pub fn answer(session: *Session, handle: []const u8, def: Def, level: Level) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(level.url.len > 0);

    if (wants_panel(session)) {
        const html = try admin.render.to_html(session.arena, level.panel);

        const accept = session.request.header("accept") orelse "";
        try session.response.set_header("Vary", "Accept, Publr-Fragment, Publr-Below");
        try session.response.set_header("Cache-Control", "private, no-store");

        if (std.mem.eql(u8, accept, "application/json")) {
            return session.response.json(.ok, .{ .html = html, .title = level.title });
        }

        return session.response.set_body(.ok, "text/html; charset=utf-8", html);
    }

    try page(session, handle, def, level);
}

/// The type's page: the fields, the preview, and the level a deep link starts with.
pub fn page(session: *Session, handle: []const u8, def: Def, top: ?Level) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(top == null or top.?.url.len > 0);

    const arena = session.arena;
    const type_href = try spaces.hub(session, handle);
    const fragment = session.request.header("publr-fragment") orelse "";

    if (std.mem.eql(u8, fragment, "columns")) {
        const list = try columns.list_node(session, handle, def);
        const preview = try columns.preview_node(session, def);
        try session.response.set_header("Cache-Control", "private, no-cache");
        try session.response.set_header("Vary", "Accept, Publr-Fragment");

        return session.response.json(.ok, .{
            .list = try admin.render.to_html(arena, list),
            .preview = try admin.render.to_html(arena, preview),
        });
    }

    const levels: ?admin.render.Node = if (top) |level|
        try admin.render.view(arena, views.TypeLevel, .{
            .url = level.url,
            .title = level.title,
            .back_href = type_href,
            .children = level.panel,
        })
    else
        null;

    const parents = try arena.alloc(views.TypeFields.ParentsItem, 2);

    parents[0] = .{ .label = "Structure", .href = "/admin/structure" };
    parents[1] = .{ .label = spaces.of(session).title(), .href = spaces.of(session).base() };

    try admin.screen(session, .ok, views.TypeFields, .{
        .title = def.name,
        .parents = parents,
        .type_href = type_href,
        .list = try columns.list_node(session, handle, def),
        .levels = levels,
        .open = top != null,
        .preview = try columns.preview_node(session, def),
    });
}

test {
    std.testing.refAllDecls(@This());
}
