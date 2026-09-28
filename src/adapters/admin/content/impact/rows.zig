//! One dialog row per page or fragment the change reaches: its address (a link for a page
//! that opens; a fragment's address serves bare HTML, so never one), its status, and the
//! chain of lines that explains it.

const std = @import("std");
const admin = @import("../../../admin.zig");
const model = @import("../../../../model.zig");
const theme_module = @import("../../../../theme.zig");
const site_operations = @import("../../../../operations/site.zig");

const Error = admin.Error;
const views = admin.views;
const Dialog = views.RecordImpact;
pub const Row = Dialog.RowsItem;
pub const Line = Dialog.WhyItem;
const Def = model.content_type.Def;
const Artifact = site_operations.impact.Artifact;
const Reads = theme_module.impact.Reads;

pub const islands_prefix = "/_islands/";
pub const status_built = "in the last build";
pub const status_unbuilt = "not built yet";
pub const status_live = "rendered per request";

/// What the rows are made from: the type, the site's address, and the index's answer.
pub const Source = struct {
    arena: std.mem.Allocator,
    def: Def,
    site_url: []const u8,
    artifacts: []const Artifact,
};

pub fn page_row(
    source: Source,
    page: theme_module.impact.Page,
    own: []const u8,
    name: []const u8,
) Error!Row {
    std.debug.assert(page.route.len > 0);
    std.debug.assert(name.len > 0);

    var why: std.ArrayList(Line) = .empty;

    try read_lines(source, &why, page.template, page.reads, page.via);

    const status = if (page.live)
        status_live
    else if (page.reads == .entry and own.len == 0)
        "its page, once the record has a slug"
    else
        try index_lines(source, &why, name);

    return .{
        .address = page.route,
        .href = if (own.len > 0)
            try print(source.arena, "{s}{s}", .{ source.site_url, own })
        else
            try href_of(source, page.route),
        .own = own,
        .kind = "page",
        .status = status,
        .rebuild = !page.live,
        .why = why.items,
    };
}

pub fn island_row(source: Source, island: theme_module.impact.Island, url: []const u8) Error!Row {
    std.debug.assert(island.key.len > 0);
    std.debug.assert(std.mem.startsWith(u8, url, islands_prefix));

    var why: std.ArrayList(Line) = .empty;

    try read_lines(source, &why, island.template, island.reads, island.via);

    for (island.placed) |place| {
        try why.append(source.arena, .{
            .text = "placed on",
            .code = place.route,
            .href = try href_of(source, place.route),
            .tail = if (place.prerendered)
                "prerendered: that page keeps a stale copy until it is next built"
            else
                "",
            .nested = false,
        });
    }

    for (island.inside) |parent| {
        const parent_url = try print(source.arena, "{s}{s}", .{ islands_prefix, parent });

        try why.append(source.arena, .{
            .text = "inside",
            .code = parent_url,
            .href = "",
            .tail = "",
            .nested = false,
        });
    }

    const status = if (island.dynamic) status_live else try index_lines(source, &why, url);

    return .{
        .address = url,
        .href = "",
        .own = "",
        .kind = "fragment",
        .status = status,
        .rebuild = !island.dynamic,
        .why = why.items,
    };
}

/// An artifact the index holds that no template explains: still rebuilt, so still shown.
pub fn index_row(source: Source, artifact: Artifact) Error!Row {
    std.debug.assert(artifact.name.len > 0);
    std.debug.assert(artifact.keys.len > 0);

    const lines = source.arena.alloc(Line, 2) catch return error.OutOfMemory;

    lines[0] = try recorded_line(source, artifact);
    lines[1] = .{
        .text = "the theme's templates show no read of the type; the index does",
        .code = "",
        .href = "",
        .tail = "",
        .nested = false,
    };

    const fragment = std.mem.startsWith(u8, artifact.name, islands_prefix);

    return .{
        .address = artifact.name,
        .href = if (fragment)
            ""
        else
            try print(source.arena, "{s}{s}", .{ source.site_url, artifact.name }),
        .own = "",
        .kind = if (fragment) "fragment" else "page",
        .status = status_built,
        .rebuild = true,
        .why = lines,
    };
}

/// "content/index.publr lists Post records", or the embed and, one step in, the
/// template that does the reading.
fn read_lines(
    source: Source,
    why: *std.ArrayList(Line),
    template: []const u8,
    reads: Reads,
    via: []const u8,
) Error!void {
    std.debug.assert(template.len > 0);
    std.debug.assert(reads != .none);

    const how = switch (reads) {
        .entry => "renders the record",
        .query => try print(source.arena, "lists {s} records", .{source.def.name}),
        .none => unreachable,
    };

    if (via.len == 0) {
        why.append(source.arena, line(template, how, false)) catch return error.OutOfMemory;

        return;
    }

    why.append(source.arena, line(template, "embeds", false)) catch return error.OutOfMemory;
    why.append(source.arena, line(via, how, true)) catch return error.OutOfMemory;
}

fn line(code: []const u8, tail: []const u8, nested: bool) Line {
    std.debug.assert(code.len > 0);
    std.debug.assert(tail.len > 0);

    return .{ .text = "", .code = code, .href = "", .tail = tail, .nested = nested };
}

/// The status of a built artifact, and the keys it recorded as a line when it is there.
fn index_lines(source: Source, why: *std.ArrayList(Line), name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(source.artifacts.len <= site_operations.impact.artifacts_max);

    for (source.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.name, name)) {
            why.append(source.arena, try recorded_line(source, artifact)) catch {
                return error.OutOfMemory;
            };

            return status_built;
        }
    }

    return status_unbuilt;
}

fn recorded_line(source: Source, artifact: Artifact) Error!Line {
    std.debug.assert(artifact.keys.len > 0);
    std.debug.assert(artifact.name.len > 0);

    return .{
        .text = "recorded by the last build through",
        .code = std.mem.join(source.arena, ", ", artifact.keys) catch return error.OutOfMemory,
        .href = "",
        .tail = "",
        .nested = false,
    };
}

/// A route is an address only without a parameter in it; a pattern has no page to open.
fn href_of(source: Source, route: []const u8) Error![]const u8 {
    std.debug.assert(source.site_url.len > 0);
    std.debug.assert(route.len > 0);

    const parameter = std.mem.indexOfScalar(u8, route, ':') != null;
    const catch_all = std.mem.indexOfScalar(u8, route, '*') != null;

    if (parameter or catch_all) {
        return "";
    }

    return print(source.arena, "{s}{s}", .{ source.site_url, route });
}

fn print(arena: std.mem.Allocator, comptime template: []const u8, args: anytype) Error![]const u8 {
    std.debug.assert(template.len > 0);
    std.debug.assert(islands_prefix.len > 0);

    return std.fmt.allocPrint(arena, template, args) catch error.OutOfMemory;
}

const test_source: Source = .{
    .arena = undefined,
    .def = .{ .handle = "post", .name = "Post", .fields = &.{} },
    .site_url = "http://h",
    .artifacts = &.{
        .{ .name = "/", .keys = &.{ "type:post", "records" } },
        .{ .name = "/posts/hello", .keys = &.{"record:abc"} },
    },
};

test "a page row: the chain through an embed, the index line, a link only where it opens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var source = test_source;
    source.arena = arena_state.allocator();

    const home = try page_row(source, .{
        .route = "/",
        .template = "content/index.publr",
        .live = false,
        .reads = .query,
        .via = "components/latest.publr",
    }, "", "/");
    try std.testing.expectEqualStrings("http://h/", home.href);
    try std.testing.expect(home.rebuild);
    try std.testing.expectEqualStrings(status_built, home.status);
    try std.testing.expectEqualStrings("embeds", home.why[0].tail);
    try std.testing.expect(home.why[1].nested);
    try std.testing.expectEqualStrings("lists Post records", home.why[1].tail);
    try std.testing.expectEqualStrings("type:post, records", home.why[2].code);

    const entry: theme_module.impact.Page = .{
        .route = "/posts/:slug",
        .template = "content/posts/[slug].publr",
        .live = false,
        .reads = .entry,
        .via = "",
    };
    const saved = try page_row(source, entry, "/posts/hello", "/posts/hello");
    try std.testing.expectEqualStrings("http://h/posts/hello", saved.href);
    try std.testing.expectEqualStrings("renders the record", saved.why[0].tail);
    try std.testing.expectEqualStrings(status_built, saved.status);
    const unsaved = try page_row(source, entry, "", "/posts/:slug");
    try std.testing.expectEqualStrings("", unsaved.href);
    try std.testing.expectEqualStrings("its page, once the record has a slug", unsaved.status);

    const live = try page_row(source, .{
        .route = "/fresh",
        .template = "content/fresh.dynamic.publr",
        .live = true,
        .reads = .query,
        .via = "",
    }, "", "/fresh");
    try std.testing.expect(!live.rebuild);
    try std.testing.expectEqualStrings(status_live, live.status);
    try std.testing.expectEqual(@as(usize, 1), live.why.len);
}

test "a fragment row: placements with the prerender note, parents, the index; an index row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var source = test_source;
    source.arena = arena_state.allocator();

    const latest = try island_row(source, .{
        .key = "latest",
        .template = "components/latest.publr",
        .dynamic = false,
        .reads = .query,
        .via = "",
        .placed = &.{
            .{ .route = "/visit", .prerendered = true },
            .{ .route = "/posts/:slug", .prerendered = false },
        },
        .inside = &.{"outer"},
    }, "/_islands/latest");
    try std.testing.expectEqualStrings("", latest.href);
    try std.testing.expectEqualStrings("fragment", latest.kind);
    try std.testing.expectEqualStrings(status_unbuilt, latest.status);
    try std.testing.expect(latest.rebuild);
    try std.testing.expectEqualStrings("http://h/visit", latest.why[1].href);
    try std.testing.expect(latest.why[1].tail.len > 0);
    try std.testing.expectEqualStrings("", latest.why[2].href);
    try std.testing.expectEqualStrings("", latest.why[2].tail);
    try std.testing.expectEqualStrings("/_islands/outer", latest.why[3].code);
    try std.testing.expectEqual(@as(usize, 4), latest.why.len);

    const extra = try index_row(source, .{ .name = "/tags", .keys = &.{"records"} });
    try std.testing.expectEqualStrings("page", extra.kind);
    try std.testing.expect(extra.rebuild);
    try std.testing.expectEqualStrings("records", extra.why[0].code);
    const fragment = try index_row(source, .{ .name = "/_islands/x", .keys = &.{"records"} });
    try std.testing.expectEqualStrings("fragment", fragment.kind);
    try std.testing.expectEqualStrings("", fragment.href);
    try std.testing.expectEqualStrings("http://h/tags", extra.href);

    try std.testing.expectEqualStrings("", try href_of(source, "/docs/*"));
}
