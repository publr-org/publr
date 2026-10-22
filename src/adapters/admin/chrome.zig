//! What every admin page reads as `Publr.request`: who is signed in, the rail sections
//! they may open, the plugins' top bar items, which area the address is in and that area's
//! sidebar. Filled once per page from the session; the views never forward it.
const std = @import("std");
const plugin_define = @import("../../sdk/plugin/define.zig");
const AdminBrand = @import("../../sdk/plugin.zig").AdminBrand;
const avatar = @import("avatar.zig");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const types = @import("../../operations/content_type.zig");
const users = @import("../../operations/user.zig");
const ai = @import("../../operations/ai.zig");
const top_bar = @import("top_bar.zig");
const sections = @import("sections.zig");
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

/// `section`: a plugin's part of the admin, its own types in its own sidebar.
pub const Area = enum { overview, content, media, design, settings, section };

/// The rail section of an address: the overview, the content and its records, and the
/// rest (settings, structure, plugins' pages) under Settings.
pub fn area_of(path: []const u8) Area {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] == '/');

    const home = std.mem.eql(u8, path, "/admin") or std.mem.eql(u8, path, "/admin/");

    if (home or under(path, "/admin/ai")) {
        return .overview;
    }

    if (under(path, "/admin/content")) {
        return .content;
    }

    if (under(path, "/admin/media")) {
        return .media;
    }

    if (under(path, "/admin/design")) {
        return .design;
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
    .session = .{
        .name = "",
        .email = "",
        .csrf = "",
        .avatar = "",
    },
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

/// The request a plugin's page is drawn with inside the plugin frame: the sheet alone, who
/// is looking but no token, since the frame reaches the admin only through its bridge; in
/// the person's language when the plugin is compiled in (`ctx`, its `PluginCtx`).
pub fn in_plugin_frame(ctx: anytype, base: []const u8) admin.Error!*const Request {
    std.debug.assert(base.len == 0 or base[0] == '/');

    const arena = ctx.arena();
    const request = try arena.create(Request);

    request.* = signed_out;

    if (@hasField(@TypeOf(ctx.*), "inner")) {
        const language = ctx.inner.language;
        const person = ctx.inner.view.person;

        request.admin.locale = if (language.locale.len > 0) language.locale else "en";
        request.publr_translations = language.translator;
        request.publr_catalogue = language.catalogue;
        request.session.name = person.name;
        request.session.email = person.email;

        if (person.email.len > 0) {
            request.session.avatar = try avatar.address_of(arena, person.email);
        }
    }

    request.admin.base = base;
    request.admin.area = "settings";
    request.admin.framed = true;

    std.debug.assert(request.session.csrf.len == 0);

    return request;
}

/// The request of a signed-in page, or of a page before sign-in (no session, no rail).
pub fn request_of(session: *const Session, options: Options) admin.Error!*const Request {
    const path = session.request.path();
    const request = try session.arena.create(Request);

    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] == '/');

    const brand = brand_of(session);

    if (!session.signed_in()) {
        request.* = signed_out;
        request.admin.base = session.project.admin_path();
        request.admin.path = path;
        request.admin.brand = brand.name;
        request.admin.brand_mark = brand.mark;

        return request;
    }

    const all_sections = try sections.all(session);
    const in = sections.current(all_sections, options.content);
    var pinning = session.*;
    const rail = try @import("destinations.zig").rail_of(&pinning, path, all_sections, in);
    const area: Area = if (in != null) .section else area_of(path);

    request.* = .{
        .session = .{
            .name = session.identity.display_name,
            .email = session.identity.email,
            .csrf = session.csrf_token(),
            .avatar = try avatar.address_of(session.arena, session.identity.email),
        },
        .admin = .{
            .base = session.project.admin_path(),
            .path = path,
            .area = @tagName(area),
            .can_structure = registry.SDK.may(&session.ctx, types.Create),
            .can_settings = registry.SDK.may(&session.ctx, users.List),
            .top_bar = top_bar.of(session),
            .rail = rail.node,
            .pinned_lit = rail.lit,
            .sidebar = if (in) |section|
                try sections.sidebar_of(session, section, options.content)
            else
                try sidebar_of(session, area, path, options),
            .sidebar_heading = if (in) |section|
                try sections.heading_of(session, section)
            else
                null,
            .plugin_icons = try @import("plugin_icons.zig").sprite(session),
            .section = if (in) |section| section.label else "",
            .section_href = if (in) |section| section.href() else "",
            .site_href = admin.app_scope.site_href(session),
            .framed = sheet_alone(session),
            .can_ask = can_ask(session),
            .brand = brand.name,
            .brand_mark = brand.mark,
        },
    };

    @import("language.zig").apply(session, request);

    var reading = session.*;

    request.admin.variant = @import("variant.zig").chosen(&reading);

    var choosing = session.*;

    request.admin.language_menu = try @import("language.zig").menu_of(&choosing);

    return request;
}

/// Whose admin it is: the first plugin that names a brand; Publr's when none does. A plugin
/// that fails is logged and passed over.
fn brand_of(session: *const Session) AdminBrand {
    std.debug.assert(session.ctx.now_ms > 0);
    comptime std.debug.assert(registry.admin_brand.len <= 64);

    inline for (registry.admin_brand) |Plugin| {
        var asking = session.ctx;
        const named = plugin_define.get(Plugin, "admin_brand")(&asking) catch |err| blk: {
            std.log.warn("plugin {s}: admin brand: {t}", .{ Plugin.manifest.name, err });
            break :blk AdminBrand{};
        };

        if (named.name.len > 0) {
            return named;
        }
    }

    return .{};
}

/// Whether a paste with nothing focused asks the agent here: never in a frame, nor on a
/// conversation's workspace, which has its own reply box.
fn can_ask(session: *const Session) bool {
    const path = session.request.path();

    std.debug.assert(path.len > 0);
    std.debug.assert(session.signed_in());

    if (framed(session) or std.mem.startsWith(u8, path, "/admin/ai/")) {
        return false;
    }

    var asking = session.*;

    return registry.SDK.may(&asking.ctx, ai.Ask) and ai.connected(&asking.ctx);
}

/// Whether the page is shown inside another: asked with `?framed=1` (the AI workspace's
/// frame keeps it on every page it shows), or a browser saying it loads a frame. Browsers
/// say so only to secure or local addresses, never to plain http on a name like
/// `publr.local`, so the address is what counts.
pub fn framed(session: *const Session) bool {
    const destination = session.request.header("sec-fetch-dest") orelse "";
    const asked = admin.query_param(session, "framed") orelse "";

    std.debug.assert(destination.len <= 64 << 10);
    std.debug.assert(session.signed_in());

    return std.mem.eql(u8, asked, "1") or std.mem.eql(u8, destination, "iframe");
}

/// Whether the page draws its sheet alone: asked with `?framed=1`, as the AI workspace's
/// preview does. A page framed otherwise (the corner chat wraps the admin in a frame while
/// the agent works) keeps the whole admin around it.
fn sheet_alone(session: *const Session) bool {
    const asked = admin.query_param(session, "framed") orelse "";

    std.debug.assert(asked.len <= 64 << 10);
    std.debug.assert(session.signed_in());

    return std.mem.eql(u8, asked, "1");
}

/// The area's sidebar as a node that does its work only when the chrome draws it: a page
/// in focus never lists the types for a sidebar it does not show.
fn sidebar_of(
    session: *const Session,
    area: Area,
    path: []const u8,
    options: Options,
) admin.Error!?Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(path.len > 0);

    // The sidebars list through operations, which need a context they may write to; the
    // page's session is borrowed, so the node keeps a copy of its own.
    const listing = try session.arena.create(Session);

    listing.* = session.*;

    switch (area) {
        .overview, .media, .design, .section => return null,
        .content => {
            const kept = try session.arena.create(ContentSidebar);

            kept.* = .{
                .session = listing,
                .current = options.content,
            };

            return admin.render.lazy(kept, ContentSidebar);
        },
        .settings => {
            const kept = try session.arena.create(SettingsSidebar);

            kept.* = .{
                .session = listing,
                .path = options.settings_path orelse path,
            };

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

        try node.render(writer, arena, .{
            .request = request,
        });
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

        try node.render(writer, arena, .{
            .request = request,
        });
    }
};

test "area_of: the overview, the content, and everything else under Settings" {
    try std.testing.expectEqual(Area.overview, area_of("/admin"));
    try std.testing.expectEqual(Area.content, area_of("/admin/content"));
    try std.testing.expectEqual(Area.content, area_of("/admin/content/42/revisions"));
    try std.testing.expectEqual(Area.media, area_of("/admin/media"));
    try std.testing.expectEqual(Area.media, area_of("/admin/media/01a1"));
    try std.testing.expectEqual(Area.design, area_of("/admin/design/templates"));
    try std.testing.expectEqual(Area.settings, area_of("/admin/designer"));
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

    return admin.render.html(arena, View, props);
}

fn signed_in_request(sidebar: ?Node) Request {
    std.debug.assert(signed_out.session.email.len == 0);
    std.debug.assert(signed_out.admin.sidebar == null);

    var request = signed_out;

    request.session = .{
        .name = "Ada",
        .email = "ada@example.com",
        .csrf = "token",
        .avatar = "",
    };
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
    const request = signed_in_request(admin.render.Node{
        .raw = "<p>the settings sidebar</p>",
    });

    const html = try drawn(arena, views.Users, .{
        .users = &.{},
        .range = "",
        .previous_href = "",
        .next_href = "",
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
    const request = signed_in_request(admin.render.Node{
        .raw = "<p>the sidebar</p>",
    });

    const focused = try drawn(arena, views.RecordForm, .{
        .title = "Article One",
        .parents = &.{.{
            .label = "Article",
            .href = "/admin/content?type=article",
        }},
        .focus = true,
        .editor = .{
            .raw = "<form>the editor</form>",
        },
        .publr_request = &request,
    });

    try std.testing.expect(std.mem.indexOf(u8, focused, "the editor") != null);
    try std.testing.expect(std.mem.indexOf(u8, focused, "the sidebar") == null);

    const refused = try drawn(arena, views.Message, .{
        .heading = "Something went wrong",
        .text = "Invalid",
        .problems = &.{.{
            .code = "title",
            .text = "is required",
        }},
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
