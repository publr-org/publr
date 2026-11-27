//! A built-in plugin's own admin screens, drawn in the admin's chrome as core's are: a route
//! handler `require`s a signed-in session (or `accept`s a POST from the admin's own page),
//! draws a `screen` with one of the plugin's views (`publr.views.all`), or `fail`s with a
//! way back. What lies behind a `Page` is the admin's own session.
const std = @import("std");
const route = @import("route.zig");
const Ctx = @import("../ctx.zig").Ctx;
const admin = @import("../../adapters/admin.zig");
const http = @import("../../lib/http.zig");

const Error = route.Error;

fn session_of(page: anytype) *admin.Session {
    return @ptrCast(@alignCast(@constCast(page)));
}

fn core(comptime Core: type, given: anytype) *Core {
    return @ptrCast(@alignCast(@constCast(given)));
}

/// Where a screen stands in the admin's sidebars.
pub const ScreenOptions = struct {
    /// The address whose Settings entry is lit, for a page that belongs under another's
    /// entry: merging a branch is part of Environments.
    settings_path: ?[]const u8 = null,
    /// A plugin's page: the address of the menu entry it is, or of the tabbed page it is a
    /// tab of.
    section_page: ?[]const u8 = null,
};

/// One admin request, signed in.
pub const Page = opaque {
    /// The signed-in person's: operations called with it are theirs.
    pub fn ctx(page: *const Page) *Ctx {
        const session = session_of(page);
        const host = session.arena.create(HostApi) catch @panic("out of memory");

        host.* = .{
            .inner = &session.ctx,
        };

        std.debug.assert(session.signed_in());

        return host.ctx();
    }

    /// Memory freed when the request ends.
    pub fn arena(page: *const Page) std.mem.Allocator {
        return session_of(page).arena;
    }

    /// The session's token, for a form the page posts back (`csrf`).
    pub fn csrf_token(page: *const Page) []const u8 {
        return session_of(page).csrf_token();
    }

    /// A route parameter that must be there; null after a not-found page otherwise.
    pub fn param(page: *const Page, name: []const u8, back: []const u8) Error!?[]const u8 {
        return admin.param(session_of(page), name, back);
    }

    /// One query parameter, decoded; null when absent or empty.
    pub fn query_param(page: *const Page, name: []const u8) ?[]const u8 {
        return admin.query_param(session_of(page), name);
    }

    /// A signed-in screen: `View`, one of the plugin's views, with its props.
    pub fn screen(
        page: *const Page,
        status: route.Status,
        comptime View: type,
        props: View.Props,
        options: ScreenOptions,
    ) Error!void {
        const drawn = std.enums.fromInt(http.Status, @backingInt(status)) orelse .ok;

        return admin.screen(session_of(page), drawn, View, props, .{
            .settings_path = options.settings_path,
            .section_page = options.section_page,
        });
    }

    /// A one-line failure page with a way back: what `err` means, or the plugin's own
    /// refusal in its words when the call failed with one.
    pub fn fail(page: *const Page, err: anyerror, back: []const u8) Error!void {
        return admin.fail(session_of(page), err, back);
    }

    /// A page saying `heading` and `text`, with a way back.
    pub fn message(
        page: *const Page,
        heading: []const u8,
        text: []const u8,
        back: []const u8,
    ) Error!void {
        const no_problems: []const struct {
            path: []const u8,
            message: []const u8,
        } = &.{};

        return admin.message(session_of(page), heading, text, no_problems, back, .{});
    }

    /// The text for people in the person's language.
    pub fn translated(page: *const Page, comptime id: []const u8) Error![]const u8 {
        return session_of(page).translated(id, .{});
    }

    /// The field kinds the project knows, the build's and its installed plugins': what
    /// `compare` shows a field's definition by.
    pub fn kinds(page: *const Page) compare.Kinds {
        const known = admin.kinds_of(session_of(page));

        std.debug.assert(known.len <= std.math.maxInt(u32));

        return .{
            .held = @ptrCast(known.ptr),
            .count = @intCast(known.len),
        };
    }

    /// Where the page of a record of type `handle` is in the site's preview, by its slug
    /// (`new` for none yet): the first app with a page for the type. Null when no app has.
    pub fn record_path(
        page: *const Page,
        handle: []const u8,
        slug: ?[]const u8,
    ) Error!?[]const u8 {
        std.debug.assert(handle.len > 0);

        const session = session_of(page);
        const preview = admin.preview_pages;

        return preview.record_path(session.project, session.arena, null, handle, slug) catch
            error.OutOfMemory;
    }

    /// The route of the app `app_name` that draws `path` (`/posts/:slug` for `/posts/hello`),
    /// as it is written in the app: what the pages of one template share. Null when the app
    /// is not loaded or no route of it draws the path.
    pub fn route_of(page: *const Page, app_name: []const u8, path: []const u8) ?[]const u8 {
        std.debug.assert(app_name.len > 0);
        std.debug.assert(path.len > 0);

        const app = session_of(page).project.find(app_name) orelse return null;
        const program = app.program orelse return null;
        const matched = program.match(path) orelse return null;

        return matched.route.pattern;
    }
};

/// The actions plugins put on the rows of `slot` (`.row_actions`), for a row named `name` of
/// `kind`, as `ctx`'s caller may use them: those whose operation they may call, `{name}` in
/// their paths filled in. On a plugin's own page or a `Page`'s `ctx()`.
pub fn row_actions(
    ctx: *const Ctx,
    comptime slot: []const u8,
    kind: []const u8,
    name: []const u8,
) error{OutOfMemory}![]const RowLink {
    std.debug.assert(name.len > 0);

    const inner = @import("../../sdk/plugin/context.zig").host_of(ctx).inner;
    const links = try admin.row_actions(inner, slot, kind, name);
    const found = try inner.arena.alloc(RowLink, links.len);

    for (links, found) |link, *row| {
        row.* = .{
            .label = link.label,
            .href = link.href,
        };
    }

    return found;
}

/// Two versions side by side, as the admin draws them on a review screen.
pub const compare = @import("compare.zig");

/// One row action as `row_actions` answers it: what the menu item says and where it goes.
pub const RowLink = struct {
    label: []const u8,
    href: []const u8,
};

const HostApi = @import("../../sdk/plugin/context.zig").HostApi;

/// A posted form, decoded.
pub const Form = struct {
    pairs: []const Pair,

    pub const Pair = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn get(form: Form, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        for (form.pairs) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                return pair.value;
            }
        }

        return null;
    }

    /// The value under `name` trimmed of whitespace; null when absent or blank.
    pub fn text(form: Form, name: []const u8) ?[]const u8 {
        const value = form.get(name) orelse return null;
        const trimmed = std.mem.trim(u8, value, " \r\n\t");

        return if (trimmed.len == 0) null else trimmed;
    }
};

/// A POST from the admin's own page, signed in, its form decoded.
pub const Post = struct {
    page: *Page,
    form: Form,
};

/// Sign-in required, by an account that may use the admin: null after redirecting to the
/// login page otherwise.
pub fn require(
    request: *route.Request,
    response: *route.Response,
    context: *route.Context,
) Error!?*Page {
    const found = try admin.require(
        core(http.Request, request),
        core(http.Response, response),
        core(http.Context, context),
    ) orelse return null;
    const session = try found.arena.create(admin.Session);

    session.* = found;

    std.debug.assert(session.signed_in());

    return @ptrCast(session);
}

/// A POST that may change something: signed in, a form that reads, from the admin's own page
/// (same origin, the session's token). Null after answering otherwise.
pub fn accept(
    request: *route.Request,
    response: *route.Response,
    context: *route.Context,
    back: []const u8,
) Error!?Post {
    const found = try admin.accept(
        core(http.Request, request),
        core(http.Response, response),
        core(http.Context, context),
        back,
    ) orelse return null;
    const session = try found.session.arena.create(admin.Session);
    const pairs = try session_pairs(found.session.arena, &found.form);

    session.* = found.session;

    std.debug.assert(back.len > 0);

    return .{
        .page = @ptrCast(session),
        .form = .{
            .pairs = pairs,
        },
    };
}

fn session_pairs(arena: std.mem.Allocator, form: *const http.Form) Error![]const Form.Pair {
    const pairs = try arena.alloc(Form.Pair, form.len);

    for (form.pairs[0..form.len], pairs) |given, *pair| {
        pair.* = .{
            .name = given.name,
            .value = given.value,
        };
    }

    std.debug.assert(pairs.len == form.len);

    return pairs;
}

/// `text` as a value in an address's query (`return=`): every character a path is not made
/// of escaped.
pub fn query_value(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    return admin.query_value(arena, text);
}

/// Unix milliseconds as `YYYY-MM-DD HH:MM`, UTC.
pub fn time_text(arena: std.mem.Allocator, ms: i64) []const u8 {
    return admin.time_text(arena, ms);
}

test "a page names the route of an app that draws a path" {
    var harness: @import("../../adapters/apps.zig").Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    var session: admin.Session = undefined;

    session.project = &harness.flow.project;

    const page: *const Page = @ptrCast(&session);

    try std.testing.expectEqualStrings("/", page.route_of("www", "/").?);
    try std.testing.expect(page.route_of("nowhere", "/") == null);
}
