//! The site page an app file the agent wrote becomes, so the preview shows the site as it
//! is built: `<app>/content/<route>.publr` at the app's mount (`products/[slug]` at its
//! first live record), any other file of the app at the app's mount. Null for a file of
//! no app, or an app on a subdomain.

const std = @import("std");
const Channel = @import("channel.zig").Channel;

const content_dir = "/content/";
const suffix = ".publr";

/// A file's route inside its app: `products/[slug]` for `content/products/[slug].publr`,
/// empty for the app's index or a file that is not a page.
pub const Route = struct {
    app: []const u8,
    route: []const u8,
};

pub fn route_of(path: []const u8) ?Route {
    std.debug.assert(path.len <= 1 << 16);

    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const app = path[0..slash];

    if (app.len == 0) {
        return null;
    }

    const rest = path[slash..];

    const extension = if (std.mem.endsWith(u8, rest, ".md")) ".md" else suffix;

    if (!std.mem.startsWith(u8, rest, content_dir) or !std.mem.endsWith(u8, rest, extension)) {
        return .{
            .app = app,
            .route = "",
        };
    }

    var route = rest[content_dir.len .. rest.len - extension.len];

    route = std.mem.cutSuffix(u8, route, ".dynamic") orelse route;

    if (std.mem.eql(u8, route, "index")) {
        route = "";
    }

    route = std.mem.cutSuffix(u8, route, "/index") orelse route;

    return .{
        .app = app,
        .route = route,
    };
}

/// The site address of `path`, asked of the server: the app's mount, and for a `[slug]`
/// route the slug of a live record of its type (the folder's name, singular). Null when
/// there is no page to show.
pub fn address_of(channel: *Channel, arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    std.debug.assert(path.len > 0);

    const found = route_of(path) orelse return null;
    const zon = try std.fmt.allocPrint(arena, "{s}/app.zon", .{found.app});
    const Read = struct {
        content: []const u8,
    };
    const read = channel.operate(Read, &.{ "--as-admin", "apps", "read", "--path", zon }) catch {
        return null;
    };
    const mount = mount_of(read.content) orelse return null;
    const route = try filled(channel, arena, found.route) orelse return null;
    const base = std.mem.trimEnd(u8, mount, "/");

    if (route.len == 0) {
        return if (base.len == 0) "/" else base;
    }

    return try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, route });
}

/// `.mount = .{ .path = "/shop" }` read from an `app.zon`; null for a subdomain or none.
pub fn mount_of(zon: []const u8) ?[]const u8 {
    std.debug.assert(zon.len <= 1 << 20);

    const at = std.mem.indexOf(u8, zon, ".mount") orelse return null;
    const end = std.mem.indexOfScalarPos(u8, zon, at, '}') orelse return null;
    const field = ".path = \"";
    const start = std.mem.indexOf(u8, zon[at..end], field) orelse return null;
    const value_start = at + start + field.len;
    const value_end = std.mem.indexOfScalarPos(u8, zon, value_start, '"') orelse return null;
    const mount = zon[value_start..value_end];

    return if (mount.len > 0 and mount[0] == '/') mount else null;
}

/// The route with a `[slug]` segment filled by a live record of the folder's type.
fn filled(channel: *Channel, arena: std.mem.Allocator, route: []const u8) !?[]const u8 {
    std.debug.assert(route.len <= 1 << 16);

    const open = std.mem.indexOf(u8, route, "[slug]") orelse return route;
    const folder = std.mem.trimEnd(u8, route[0..open], "/");
    const name = std.fs.path.basename(folder);

    if (name.len == 0) {
        return null;
    }

    const handle = std.mem.cutSuffix(u8, name, "s") orelse name;
    const Listed = struct {
        records: []const struct {
            slug: ?[]const u8 = null,
            status: []const u8 = "",
        },
    };
    const args = [_][]const u8{ "--as-admin", "record", "list", "--type", handle };
    const listed = channel.operate(Listed, &args) catch return null;

    for (listed.records) |one| {
        const slug = one.slug orelse continue;

        if (slug.len > 0 and std.mem.eql(u8, one.status, "published")) {
            const before = route[0..open];
            const after = route[open + "[slug]".len ..];

            return try std.mem.concat(arena, u8, &.{ before, slug, after });
        }
    }

    return null;
}

test "app files become routes: index, nested index, dynamic, a slug, Markdown, not a page" {
    try std.testing.expectEqualStrings("", route_of("shop/content/index.publr").?.route);
    try std.testing.expectEqualStrings("cart", route_of("shop/content/cart.dynamic.publr").?.route);
    try std.testing.expectEqualStrings("posts", route_of("www/content/posts/index.publr").?.route);
    try std.testing.expectEqualStrings(
        "products/[slug]",
        route_of("shop/content/products/[slug].publr").?.route,
    );
    try std.testing.expectEqualStrings(
        "guide/install",
        route_of("docs/content/guide/install.md").?.route,
    );
    try std.testing.expectEqualStrings("", route_of("shop/public/shop.css").?.route);
    try std.testing.expect(route_of("app.zon") == null);
}

test "mounts: a path, a subdomain, none" {
    try std.testing.expectEqualStrings("/shop", mount_of(".{ .mount = .{ .path = \"/shop\" } }").?);
    try std.testing.expect(mount_of(".{ .mount = .{ .subdomain = \"portal\" } }") == null);
    try std.testing.expect(mount_of(".{ .name = \"x\" }") == null);
}
