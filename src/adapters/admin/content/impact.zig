//! The editor's dependency dialog, drawn under `serve --dev` only: every page and fragment
//! a change to the record reaches, those built to a file first, each with the chain that
//! explains it (the theme's templates) and whether the last build recorded it (the index).

const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../app/registry.zig");
const model = @import("../../../model.zig");
const theme_module = @import("../../../theme.zig");
const site_operations = @import("../../../operations/site.zig");
const fields = @import("../fields.zig");
const type_pages = @import("../types.zig");
const rows_module = @import("impact/rows.zig");

const Session = admin.Session;
const Error = admin.Error;
const views = admin.views;
const Dialog = views.RecordImpact;
const Row = rows_module.Row;
const Source = rows_module.Source;
const Def = model.content_type.Def;
const Impact = site_operations.impact.Impact;

const islands_prefix = rows_module.islands_prefix;

/// The dialog as a node for the editor's aside; null unless the server runs `--dev` with
/// a theme loaded.
pub fn node_of(
    session: *Session,
    def: Def,
    full: ?fields.Record,
) Error!?admin.render.Node {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(session.signed_in());

    const public = session.site.public orelse return null;

    if (!public.options.dev) {
        return null;
    }

    const arena = session.arena;
    const record_id: ?[]const u8 = if (full) |got| got.id else null;
    const slug: ?[]const u8 = if (full) |got| got.slug else null;
    var failed = false;
    const empty: theme_module.impact.Impact = .{ .pages = &.{}, .islands = &.{} };
    const found = theme_module.impact.of(arena, public.theme, def.handle) catch |err| blk: {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        failed = true;

        break :blk empty;
    };
    const recorded = registry.SDK.dispatch(&session.ctx, Impact, .{
        .type = def.handle,
        .id = record_id,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => Impact.Out{ .keys = &.{}, .artifacts = &.{} },
    };
    const source: Source = .{
        .arena = arena,
        .def = def,
        .site_url = try type_pages.site_url_of(session),
        .artifacts = recorded.artifacts,
    };
    const rows = try rows_of(source, found, slug);
    const title = if (full) |got|
        (if (got.title.len > 0) got.title else got.id)
    else
        try print(arena, "a new {s}", .{def.name});

    return try admin.render.view(arena, Dialog, .{
        .title = title,
        .keys = try keys_of(arena, recorded.keys),
        .rows = rows,
        .has_rebuild = count(rows, true) > 0,
        .has_live = count(rows, false) > 0,
        .failed = failed,
    });
}

/// The theme's pages, then its fragments, then whatever the index recorded that the theme
/// did not explain (the plan over-approximates and must never miss).
fn rows_of(
    source: Source,
    found: theme_module.impact.Impact,
    slug: ?[]const u8,
) Error![]const Row {
    std.debug.assert(source.site_url.len > 0);
    std.debug.assert(found.pages.len <= theme_module.templates_max);

    var rows: std.ArrayList(Row) = .empty;
    var names: std.ArrayList([]const u8) = .empty;

    for (found.pages) |page| {
        const own = if (page.reads == .entry and slug != null)
            theme_module.substitute(source.arena, page.route, slug.?) catch {
                return error.OutOfMemory;
            }
        else
            "";
        const name = if (own.len > 0) own else page.route;

        const row = try rows_module.page_row(source, page, own, name);

        try append(source.arena, &rows, &names, name, row);
    }

    for (found.islands) |island| {
        const url = try print(source.arena, "{s}{s}", .{ islands_prefix, island.key });

        const row = try rows_module.island_row(source, island, url);

        try append(source.arena, &rows, &names, url, row);
    }

    for (source.artifacts) |artifact| {
        if (contains(names.items, artifact.name)) {
            continue;
        }

        const row = try rows_module.index_row(source, artifact);

        try append(source.arena, &rows, &names, artifact.name, row);
    }

    std.debug.assert(rows.items.len == names.items.len);

    return rows.items;
}

fn append(
    arena: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    names: *std.ArrayList([]const u8),
    name: []const u8,
    row: Row,
) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(rows.items.len == names.items.len);

    rows.append(arena, row) catch return error.OutOfMemory;
    names.append(arena, name) catch return error.OutOfMemory;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(names.len <= theme_module.templates_max + theme_module.islands_max);

    for (names) |known| {
        if (std.mem.eql(u8, known, name)) {
            return true;
        }
    }

    return false;
}

fn count(rows: []const Row, rebuild: bool) u32 {
    std.debug.assert(rows.len <= std.math.maxInt(u32));
    std.debug.assert(islands_prefix.len > 0);

    var total: u32 = 0;

    for (rows) |row| {
        if (row.rebuild == rebuild) {
            total += 1;
        }
    }

    return total;
}

fn keys_of(arena: std.mem.Allocator, keys: []const []const u8) Error![]const Dialog.KeysItem {
    std.debug.assert(keys.len <= 3);
    std.debug.assert(islands_prefix.len > 0);

    const items = arena.alloc(Dialog.KeysItem, keys.len) catch return error.OutOfMemory;

    for (keys, items) |key, *item| {
        item.* = .{ .key = key };
    }

    return items;
}

fn print(arena: std.mem.Allocator, comptime template: []const u8, args: anytype) Error![]const u8 {
    std.debug.assert(template.len > 0);
    std.debug.assert(islands_prefix.len > 0);

    return std.fmt.allocPrint(arena, template, args) catch error.OutOfMemory;
}

const test_pages = [_]theme_module.impact.Page{
    .{
        .route = "/",
        .template = "content/index.publr",
        .live = false,
        .reads = .query,
        .via = "components/latest.publr",
    },
    .{
        .route = "/fresh",
        .template = "content/fresh.dynamic.publr",
        .live = true,
        .reads = .query,
        .via = "",
    },
    .{
        .route = "/greetings/:slug",
        .template = "content/greetings/[slug].publr",
        .live = false,
        .reads = .entry,
        .via = "",
    },
};

const test_islands = [_]theme_module.impact.Island{.{
    .key = "latest",
    .template = "components/latest.publr",
    .dynamic = false,
    .reads = .query,
    .via = "",
    .placed = &.{
        .{ .route = "/visit", .prerendered = true },
        .{ .route = "/greetings/:slug", .prerendered = false },
    },
    .inside = &.{"outer"},
}};

test "rows: the theme's pages, then its fragments, then what only the index knows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source: Source = .{
        .arena = arena_state.allocator(),
        .def = .{ .handle = "greeting", .name = "Greeting", .fields = &.{} },
        .site_url = "http://h",
        .artifacts = &.{
            .{ .name = "/", .keys = &.{ "type:greeting", "records" } },
            .{ .name = "/greetings/hello", .keys = &.{"record:abc"} },
            .{ .name = "/tags", .keys = &.{"records"} },
        },
    };
    const found: theme_module.impact.Impact = .{ .pages = &test_pages, .islands = &test_islands };

    const rows = try rows_of(source, found, "hello");
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqualStrings("/", rows[0].address);
    try std.testing.expectEqualStrings("/fresh", rows[1].address);
    try std.testing.expectEqualStrings("/greetings/hello", rows[2].own);
    try std.testing.expectEqualStrings("/_islands/latest", rows[3].address);
    try std.testing.expectEqualStrings("/tags", rows[4].address);
    try std.testing.expectEqual(@as(u32, 4), count(rows, true));
    try std.testing.expectEqual(@as(u32, 1), count(rows, false));

    const unsaved = try rows_of(source, found, null);
    try std.testing.expectEqualStrings("", unsaved[2].own);
    try std.testing.expectEqual(@as(usize, 6), unsaved.len);

    const keys = try keys_of(source.arena, &.{ "type:greeting", "records" });
    try std.testing.expectEqualStrings("records", keys[1].key);
    try std.testing.expect(contains(&.{ "/", "/x" }, "/x"));
    try std.testing.expect(!contains(&.{"/"}, "/x"));
}
