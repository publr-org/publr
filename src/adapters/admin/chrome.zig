//! What every admin page reads as `Publr.request`: who is signed in, the rail sections
//! they may open, the plugins' top bar items, which area the address is in and that area's
//! sidebar. Filled once per page from the session; the views never forward it.
const std = @import("std");
const avatar = @import("avatar.zig");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const types = @import("../../operations/content_type.zig");
const users = @import("../../operations/user.zig");
const top_bar = @import("top_bar.zig");
const nav = @import("nav.zig");
const settings_nav = @import("settings_nav.zig");

const Session = admin.Session;
const Request = admin.render.Request;
const Node = admin.render.Node;

/// How a page stands in its sidebar when the address alone does not say.
pub const Options = struct {
    /// The saved view and filters a content page shows.
    content: nav.Current = .{},
    /// The address whose Settings entry is lit, for a page that belongs under another's
    /// entry: merging a branch is part of Environments.
    settings_path: ?[]const u8 = null,
};

pub const Area = enum { overview, content, media, settings };

/// The rail section of an address: the overview, the content and its records, and the
/// rest (settings, structure, plugins' pages) under Settings.
pub fn area_of(path: []const u8) Area {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] == '/');

    if (std.mem.eql(u8, path, "/admin") or std.mem.eql(u8, path, "/admin/")) {
        return .overview;
    }

    if (under(path, "/admin/content")) {
        return .content;
    }

    if (under(path, "/admin/media")) {
        return .media;
    }

    return .settings;
}

/// `path` is `prefix` or below it, segment by segment.
pub fn under(path: []const u8, prefix: []const u8) bool {
    std.debug.assert(prefix.len > 0);
    std.debug.assert(prefix[prefix.len - 1] != '/');

    if (!std.mem.startsWith(u8, path, prefix)) {
        return false;
    }

    return path.len == prefix.len or path[prefix.len] == '/';
}

/// The request of the pages before sign-in, which draw no chrome.
pub const signed_out: Request = .{
    .session = .{ .name = "", .email = "", .csrf = "", .avatar = "" },
    .admin = .{
        .base = "",
        .path = "/admin",
        .area = "",
        .can_structure = false,
        .can_settings = false,
        .top_bar = null,
        .sidebar = null,
    },
};

/// `signed_out` for a project served under `base`.
pub fn signed_out_at(arena: std.mem.Allocator, base: []const u8) admin.Error!*const Request {
    const request = try arena.create(Request);

    request.* = signed_out;
    request.admin.base = base;

    std.debug.assert(request.session.email.len == 0);

    return request;
}

/// The request of a signed-in page, or of a page before sign-in (no session, no rail).
pub fn request_of(session: *const Session, options: Options) admin.Error!*const Request {
    const path = session.request.path();
    const request = try session.arena.create(Request);

    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] == '/');

    if (!session.signed_in()) {
        request.* = signed_out;
        request.admin.base = session.project.base;
        request.admin.path = path;

        return request;
    }

    const area = area_of(path);

    request.* = .{
        .session = .{
            .name = session.identity.display_name,
            .email = session.identity.email,
            .csrf = session.csrf_token(),
            .avatar = try avatar.address_of(session.arena, session.identity.email),
        },
        .admin = .{
            .base = session.project.base,
            .path = path,
            .area = @tagName(area),
            .can_structure = registry.SDK.may(&session.ctx, types.Create),
            .can_settings = registry.SDK.may(&session.ctx, users.List),
            .top_bar = top_bar.of(session),
            .sidebar = try sidebar_of(session, area, options, path),
        },
    };

    return request;
}

/// The area's sidebar as a node that does its work only when the chrome draws it: a page
/// in focus never lists the types for a sidebar it does not show.
fn sidebar_of(
    session: *const Session,
    area: Area,
    options: Options,
    path: []const u8,
) admin.Error!?Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(path.len > 0);

    // The sidebars list through operations, which need a context they may write to; the
    // page's session is borrowed, so the node keeps a copy of its own.
    const listing = try session.arena.create(Session);

    listing.* = session.*;

    switch (area) {
        .overview, .media => return null,
        .content => {
            const kept = try session.arena.create(ContentSidebar);

            kept.* = .{ .session = listing, .current = options.content };

            return admin.render.lazy(kept, ContentSidebar);
        },
        .settings => {
            const kept = try session.arena.create(SettingsSidebar);

            kept.* = .{ .session = listing, .path = options.settings_path orelse path };

            return admin.render.lazy(kept, SettingsSidebar);
        },
    }
}

const ContentSidebar = struct {
    session: *Session,
    current: nav.Current,

    pub fn render(
        sidebar: ContentSidebar,
        writer: *std.Io.Writer,
        arena: std.mem.Allocator,
        request: ?*const anyopaque,
    ) anyerror!void {
        std.debug.assert(sidebar.session.signed_in());

        const node = try nav.nav_content(sidebar.session, sidebar.current);

        try node.render_with(writer, arena, request);
    }
};

const SettingsSidebar = struct {
    session: *Session,
    path: []const u8,

    pub fn render(
        sidebar: SettingsSidebar,
        writer: *std.Io.Writer,
        arena: std.mem.Allocator,
        request: ?*const anyopaque,
    ) anyerror!void {
        std.debug.assert(sidebar.session.signed_in());
        std.debug.assert(sidebar.path.len > 0);

        const node = try settings_nav.node(sidebar.session, sidebar.path);

        try node.render_with(writer, arena, request);
    }
};

test "area_of: the overview, the content, and everything else under Settings" {
    try std.testing.expectEqual(Area.overview, area_of("/admin"));
    try std.testing.expectEqual(Area.content, area_of("/admin/content"));
    try std.testing.expectEqual(Area.content, area_of("/admin/content/42/revisions"));
    try std.testing.expectEqual(Area.media, area_of("/admin/media"));
    try std.testing.expectEqual(Area.media, area_of("/admin/media/01a1"));
    try std.testing.expectEqual(Area.settings, area_of("/admin/mediakit"));
    try std.testing.expectEqual(Area.settings, area_of("/admin/contentful"));
    try std.testing.expectEqual(Area.settings, area_of("/admin/types/post"));
    try std.testing.expectEqual(Area.settings, area_of("/admin/deployments/main/3"));
}

test "under: whole segments only" {
    try std.testing.expect(under("/admin/settings/users", "/admin/settings/users"));
    try std.testing.expect(under("/admin/settings/users/7", "/admin/settings/users"));
    try std.testing.expect(!under("/admin/settings/usersx", "/admin/settings/users"));
    try std.testing.expect(!under("/admin/settings", "/admin/settings/users"));
}

const views = admin.views;

fn drawn(arena: std.mem.Allocator, comptime View: type, props: View.Props) ![]const u8 {
    std.debug.assert(@hasDecl(View, "render"));
    std.debug.assert(props.publr_request != null);

    var out: std.Io.Writer.Allocating = .init(arena);

    try View.render(&out.writer, arena, props);

    return out.written();
}

fn signed_in_request(sidebar: ?Node) Request {
    std.debug.assert(signed_out.session.email.len == 0);
    std.debug.assert(signed_out.admin.sidebar == null);

    var request = signed_out;

    request.session = .{ .name = "Ada", .email = "ada@example.com", .csrf = "token", .avatar = "" };
    request.admin.path = "/admin/settings/users";
    request.admin.area = "settings";
    request.admin.can_settings = true;
    request.admin.sidebar = sidebar;

    return request;
}

test "layouts: one title for the window and the h1; the empty state replaces the list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request = signed_in_request(admin.render.Node{ .raw = "<p>the settings sidebar</p>" });

    const html = try drawn(arena, views.Users, .{
        .users = &.{},
        .publr_request = &request,
    });

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Users · Publr</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "the settings sidebar") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-part=\"index-page\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "<h1"));

    const empty = try drawn(arena, views.CustomFields, .{
        .groups = &.{},
        .publr_request = &request,
    });

    try std.testing.expect(std.mem.indexOf(u8, empty, "No field groups yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "<table") == null);
}

test "layouts: a record is edited in focus, without the sidebar; problems are an error callout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request = signed_in_request(admin.render.Node{ .raw = "<p>the sidebar</p>" });

    const focused = try drawn(arena, views.RecordForm, .{
        .title = "Article One",
        .parents = &.{.{ .label = "Article", .href = "/admin/content?type=article" }},
        .focus = true,
        .editor = .{ .raw = "<form>the editor</form>" },
        .publr_request = &request,
    });

    try std.testing.expect(std.mem.indexOf(u8, focused, "the editor") != null);
    try std.testing.expect(std.mem.indexOf(u8, focused, "the sidebar") == null);

    const refused = try drawn(arena, views.Message, .{
        .heading = "Something went wrong",
        .text = "Invalid",
        .problems = &.{.{ .code = "title", .text = "is required" }},
        .link_href = "/admin/settings/users",
        .link_label = "Back",
        .publr_request = &request,
    });

    try std.testing.expect(std.mem.indexOf(u8, refused, "data-tone=\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "the sidebar") != null);
}

test "layouts: before sign-in there is no rail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html = try drawn(arena, views.Message, .{
        .heading = "Refused",
        .text = "",
        .problems = &.{},
        .link_href = "/admin/login",
        .link_label = "Back",
        .publr_request = &signed_out,
    });

    try std.testing.expect(std.mem.indexOf(u8, html, "aria-label=\"Sections\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Refused") != null);
}
