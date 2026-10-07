//! The media library: `/admin/media` (the explorer, the filters and the files as tiles,
//! filtered by the address) and `/admin/media/:id` (one file: its preview and focal point,
//! what is written about it, its folder, tags and privacy), saved and deleted by form.

const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const media = @import("../../operations/media.zig");
const explorer = @import("media/explorer.zig");

const views = admin.views;
const back = "/admin/media";

pub fn library(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const filter = try filter_of(session.arena, request.query());
    const listed = registry.SDK.dispatch(&session.ctx, media.List, .{
        .folder = filter.folder,
        .tags = filter.tags,
        .search = filter.search,
        .year = if (filter.year > 0) filter.year else null,
        .month = if (filter.month > 0) filter.month else null,
        .kind = explorer.chosen(filter.kind),
        .size = explorer.chosen(filter.size),
        .visibility = explorer.chosen(filter.visibility),
        .limit = explorer.page_size,
        .offset = (filter.page - 1) * explorer.page_size,
    }) catch |err| return admin.fail(&session, err, "/admin");
    const arena = session.arena;
    const sides = try sides_of(views.Media, arena, filter, listed);
    const pages = @max(1, (listed.total + explorer.page_size - 1) / explorer.page_size);
    var next = filter;
    var previous = filter;

    next.page = filter.page + 1;
    previous.page = filter.page -| 1;

    try admin.screen(&session, .ok, views.Media, .{
        .folder = filter.folder,
        .tags = filter.tags,
        .search = filter.search,
        .year = @floatFromInt(filter.year),
        .month = @floatFromInt(filter.month),
        .page = @floatFromInt(filter.page),
        .page_size = @floatFromInt(explorer.page_size),
        .pages = @floatFromInt(pages),
        .prev_href = if (filter.page > 1) try explorer.href_of(arena, previous) else "",
        .next_href = if (filter.page < pages) try explorer.href_of(arena, next) else "",
        .page_text = try std.fmt.allocPrint(arena, "Page {d} of {d} · {d} files", .{
            filter.page, pages, listed.total,
        }),
        .pills = try pills_of(arena, filter),
        .add_filters = try add_filters_of(arena, filter),
        .kind = filter.kind,
        .size_filter = filter.size,
        .visibility = filter.visibility,
        .items = try items_of(arena, listed.items),
        .total = @floatFromInt(listed.total),
        .all = @floatFromInt(listed.all),
        .unsorted = @floatFromInt(listed.unsorted),
        .all_href = sides.all_href,
        .unsorted_href = sides.unsorted_href,
        .unreviewed = @floatFromInt(listed.unreviewed),
        .unreviewed_href = sides.unreviewed_href,
        .on_server = on_server(&session),
        .folders = sides.folders,
        .tag_list = sides.tags,
        .periods = sides.periods,
        .years = sides.years,
        .months = sides.months,
    });
}

/// Whether the files are in a folder on a server, which people can put files into by hand.
pub fn on_server(session: *const admin.Session) bool {
    std.debug.assert(session.ctx.now_ms >= 0);

    const files = session.ctx.files orelse return false;

    return files == .disk;
}

fn filter_of(arena: std.mem.Allocator, query: []const u8) admin.Error!explorer.Filter {
    std.debug.assert(query.len <= 64 << 10);
    std.debug.assert(explorer.page_size > 0);

    const form = admin.Form.parse(arena, query) orelse return .{};
    var tags: std.ArrayList([]const u8) = .empty;
    var filter: explorer.Filter = .{};

    for (form.pairs[0..form.len]) |entry| {
        if (std.mem.eql(u8, entry.name, "tag") and entry.value.len > 0 and tags.items.len < 16) {
            try tags.append(arena, entry.value);
        }
    }

    filter.tags = tags.items;
    filter.folder = form.get("folder") orelse "";
    filter.search = form.get("search") orelse "";
    filter.year = number_of(form.get("year"), 9999);
    filter.month = if (filter.year > 0) number_of(form.get("month"), 12) else 0;
    filter.page = @max(1, number_of(form.get("page"), 100_000));
    filter.kind = one_of(form.get("type"), &.{ "any", "image", "video", "audio", "pdf", "other" });
    filter.size = one_of(form.get("size"), &.{ "any", "small", "medium", "large" });
    filter.visibility = one_of(form.get("visibility"), &.{ "any", "public", "private" });

    return filter;
}

/// The value when it is one the filter takes, else none.
fn one_of(text: ?[]const u8, values: []const []const u8) []const u8 {
    std.debug.assert(values.len > 0);

    const given = text orelse return "";

    for (values) |value| {
        if (std.mem.eql(u8, value, given)) {
            return value;
        }
    }

    return "";
}

fn number_of(text: ?[]const u8, limit: u32) u32 {
    std.debug.assert(limit > 0);

    const given = text orelse return 0;
    const number = std.fmt.parseInt(u32, given, 10) catch return 0;

    return if (number <= limit) number else 0;
}

/// The explorer's side of a listing, in the item types of the page `View` draws it on: the
/// tree, the tags, the months, what each leads to.
pub fn Sides(comptime View: type) type {
    return struct {
        all_href: []const u8,
        unsorted_href: []const u8,
        unreviewed_href: []const u8,
        folders: []const View.FoldersItem,
        tags: []const View.Tag_listItem,
        periods: []const View.PeriodsItem,
        years: []const View.YearsItem,
        months: []const View.MonthsItem,
    };
}

pub fn sides_of(
    comptime View: type,
    arena: std.mem.Allocator,
    filter: explorer.Filter,
    listed: media.List.Out,
) admin.Error!Sides(View) {
    std.debug.assert(filter.page >= 1);
    std.debug.assert(listed.folders.len <= 1 << 16);

    var everywhere = filter;
    var unsorted = filter;

    everywhere.folder = "";
    everywhere.page = 1;
    unsorted.folder = "unsorted";
    unsorted.page = 1;

    var unreviewed = unsorted;

    unreviewed.folder = "unreviewed";

    return .{
        .all_href = try explorer.href_of(arena, everywhere),
        .unsorted_href = try explorer.href_of(arena, unsorted),
        .unreviewed_href = try explorer.href_of(arena, unreviewed),
        .folders = try folders_of(View.FoldersItem, arena, filter, listed.folders),
        .tags = try tags_of(View.Tag_listItem, arena, filter, listed.tags),
        .periods = try periods_of(View.PeriodsItem, arena, listed.periods),
        .years = try years_of(View.YearsItem, arena, filter, listed.periods),
        .months = try months_of(View.MonthsItem, arena, filter, listed.periods),
    };
}

fn folders_of(
    comptime Folder: type,
    arena: std.mem.Allocator,
    filter: explorer.Filter,
    folders: []const media.list.Folder,
) admin.Error![]const Folder {
    std.debug.assert(folders.len <= 1 << 16);
    std.debug.assert(filter.page >= 1);

    const out = try arena.alloc(Folder, folders.len);

    for (folders, out) |folder, *entry| {
        var into = filter;

        into.folder = folder.id;
        into.page = 1;

        const indent = try arena.alloc(u8, folder.depth * "— ".len);

        for (0..folder.depth) |step| {
            @memcpy(indent[step * "— ".len ..][0.."— ".len], "— ");
        }

        entry.* = .{
            .id = folder.id,
            .name = folder.name,
            .parent = folder.parent orelse "",
            .depth = @floatFromInt(folder.depth),
            .level = enum_of(@FieldType(Folder, "level"), explorer.depth_level(folder.depth)),
            .label = try std.fmt.allocPrint(arena, "{s}{s}", .{ indent, folder.name }),
            .count = @floatFromInt(folder.count),
            .href = try explorer.href_of(arena, into),
            .current = std.mem.eql(u8, folder.id, filter.folder),
            .nests = explorer.nests(folder.depth),
        };
    }

    return out;
}

fn tags_of(
    comptime Tag: type,
    arena: std.mem.Allocator,
    filter: explorer.Filter,
    tags: []const media.list.Tag,
) admin.Error![]const Tag {
    std.debug.assert(tags.len <= 1 << 16);
    std.debug.assert(filter.page >= 1);

    const out = try arena.alloc(Tag, tags.len);

    for (tags, out) |tag, *entry| {
        var toggled = filter;

        toggled.tags = try explorer.toggled(arena, filter.tags, tag.id);
        toggled.page = 1;

        const selected = explorer.contains(filter.tags, tag.id);

        entry.* = .{
            .id = tag.id,
            .name = tag.name,
            .count = @floatFromInt(tag.count),
            .href = try explorer.href_of(arena, toggled),
            .selected = selected,
            .enabled = selected or tag.count > 0,
        };
    }

    return out;
}

fn periods_of(
    comptime Period: type,
    arena: std.mem.Allocator,
    periods: []const media.list.Period,
) admin.Error![]const Period {
    std.debug.assert(periods.len <= 240);

    const out = try arena.alloc(Period, periods.len);

    for (periods, out) |period, *entry| {
        entry.* = .{
            .year = @floatFromInt(period.year),
            .month = @floatFromInt(period.month),
            .count = @floatFromInt(period.count),
        };
    }

    return out;
}

fn years_of(
    comptime Option: type,
    arena: std.mem.Allocator,
    filter: explorer.Filter,
    periods: []const media.list.Period,
) admin.Error![]const Option {
    std.debug.assert(periods.len <= 240);

    var out: std.ArrayList(Option) = .empty;

    try out.append(arena, .{ .value = "0", .label = "Any year", .selected = filter.year == 0 });

    for (periods, 0..) |period, index| {
        if (index > 0 and periods[index - 1].year == period.year) {
            continue;
        }

        const label = try std.fmt.allocPrint(arena, "{d}", .{period.year});

        try out.append(arena, .{
            .value = label,
            .label = label,
            .selected = period.year == filter.year,
        });
    }

    return out.items;
}

fn months_of(
    comptime Option: type,
    arena: std.mem.Allocator,
    filter: explorer.Filter,
    periods: []const media.list.Period,
) admin.Error![]const Option {
    std.debug.assert(periods.len <= 240);

    var out: std.ArrayList(Option) = .empty;

    try out.append(arena, .{ .value = "0", .label = "Any month", .selected = filter.month == 0 });

    for (periods) |period| {
        if (period.year != filter.year) {
            continue;
        }

        try out.append(arena, .{
            .value = try std.fmt.allocPrint(arena, "{d}", .{period.month}),
            .label = try std.fmt.allocPrint(arena, "{s} · {d}", .{
                explorer.month_name(period.month), period.count,
            }),
            .selected = period.month == filter.month,
        });
    }

    return out.items;
}

const Pill = views.Media.PillsItem;
const PillOption = views.Media.OptionsItem;
const Choice = struct { value: []const u8, label: []const u8 };

const kinds = [_]Choice{
    .{ .value = "image", .label = "Images" },
    .{ .value = "video", .label = "Videos" },
    .{ .value = "audio", .label = "Audio" },
    .{ .value = "pdf", .label = "PDFs" },
    .{ .value = "other", .label = "Other files" },
};
const sizes = [_]Choice{
    .{ .value = "small", .label = "Under 1 MB" },
    .{ .value = "medium", .label = "1 to 10 MB" },
    .{ .value = "large", .label = "Over 10 MB" },
};
const visibilities = [_]Choice{
    .{ .value = "public", .label = "Public" },
    .{ .value = "private", .label = "Private" },
};

const Field = enum { kind, size, visibility };

/// The bar's filters, drawn as Content's: on the file itself, each with the values it
/// takes and a way back to Any. Type is always there; Size and Visibility once added.
fn pills_of(arena: std.mem.Allocator, filter: explorer.Filter) admin.Error![]const Pill {
    std.debug.assert(filter.page >= 1);
    std.debug.assert(kinds.len > 0);

    var pills: std.ArrayList(Pill) = .empty;

    try pills.append(arena, try pill_of(arena, filter, .kind, "Type", &kinds));

    if (filter.size.len > 0) {
        try pills.append(arena, try pill_of(arena, filter, .size, "Size", &sizes));
    }

    if (filter.visibility.len > 0) {
        const pill = try pill_of(arena, filter, .visibility, "Visibility", &visibilities);

        try pills.append(arena, pill);
    }

    return pills.items;
}

fn with(filter: explorer.Filter, field: Field, value: []const u8) explorer.Filter {
    std.debug.assert(filter.page >= 1);

    var next = filter;

    next.page = 1;

    switch (field) {
        .kind => next.kind = value,
        .size => next.size = value,
        .visibility => next.visibility = value,
    }

    return next;
}

fn pill_of(
    arena: std.mem.Allocator,
    filter: explorer.Filter,
    field: Field,
    label: []const u8,
    choices: []const Choice,
) admin.Error!Pill {
    std.debug.assert(choices.len > 0);
    std.debug.assert(label.len > 0);

    const current = switch (field) {
        .kind => filter.kind,
        .size => filter.size,
        .visibility => filter.visibility,
    };
    const any = current.len == 0 or std.mem.eql(u8, current, "any");
    const options = try arena.alloc(PillOption, choices.len + 1);
    var value: []const u8 = "Any";

    options[0] = .{
        .label = "Any",
        .href = try explorer.href_of(arena, with(filter, field, "any")),
        .selected = any,
    };

    for (choices, options[1..]) |choice, *option| {
        const selected = std.mem.eql(u8, current, choice.value);

        if (selected) {
            value = choice.label;
        }

        option.* = .{
            .label = choice.label,
            .href = try explorer.href_of(arena, with(filter, field, choice.value)),
            .selected = selected,
        };
    }

    // Type stays in the bar at Any; the others leave it.
    const dropped = with(filter, field, "");
    const removable = field != .kind or !any;

    return .{
        .id = @tagName(field),
        .label = label,
        .value = value,
        .options = options,
        .remove_href = if (removable) try explorer.href_of(arena, dropped) else "",
    };
}

const AddFilter = views.Media.Add_filtersItem;

/// Filter's menu: the bar's filters that are not in it yet.
fn add_filters_of(arena: std.mem.Allocator, filter: explorer.Filter) admin.Error![]const AddFilter {
    std.debug.assert(filter.page >= 1);

    const out = try arena.alloc(AddFilter, 2);

    out[0] = .{
        .label = "Size",
        .href = try std.fmt.allocPrint(arena, "{s}#filter-size", .{
            try explorer.href_of(arena, with(filter, .size, "any")),
        }),
        .added = filter.size.len > 0,
    };
    out[1] = .{
        .label = "Visibility",
        .href = try std.fmt.allocPrint(arena, "{s}#filter-visibility", .{
            try explorer.href_of(arena, with(filter, .visibility, "any")),
        }),
        .added = filter.visibility.len > 0,
    };

    return out;
}

const Item = views.Media.ItemsItem;

fn items_of(arena: std.mem.Allocator, items: []const media.Item) admin.Error![]const Item {
    std.debug.assert(items.len <= 200);

    const out = try arena.alloc(Item, items.len);

    for (items, out) |item, *entry| {
        const image = std.mem.eql(u8, item.family, "image");

        entry.* = .{
            .id = item.id,
            .title = item.title,
            .href = try std.fmt.allocPrint(arena, "/admin/media/{s}", .{item.id}),
            .thumb = if (image)
                try std.fmt.allocPrint(arena, "/media/{s}?w=480&h=480&fit=cover", .{item.key})
            else
                "",
            .image = image and !item.missing,
            .video = std.mem.eql(u8, item.family, "video") and !item.missing,
            .src = try std.fmt.allocPrint(arena, "/media/{s}", .{item.key}),
            .kind = try explorer.kind_of(arena, item.filename),
            .icon = enum_of(@FieldType(Item, "icon"), explorer.icon_of(item.family)),
            .facts = try explorer.facts_of(arena, item),
            .missing = item.missing,
            .selected = false,
        };
    }

    return out;
}

/// A closed string set's value by name; the names come from the sets the views declare.
fn enum_of(comptime Enum: type, name: []const u8) Enum {
    std.debug.assert(name.len > 0);

    const value = std.meta.stringToEnum(Enum, name);

    std.debug.assert(value != null);

    return value.?;
}

pub const file = @import("media/file.zig");

test {
    std.testing.refAllDecls(@This());
}

test "media over http: the library, a file's page and its form, the file served" {
    const routes = @import("../../server/routes.zig");
    const files_module = @import("../../lib/files.zig");
    const encode = @import("../../lib/image/encode.zig");
    const sdk = @import("../../sdk.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var disk = try files_module.Disk.open(std.testing.io, root);
    defer disk.close();

    var flow: admin.Flow = .{ .inner = undefined };
    var project: routes.Project = .{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    };

    project.files = .{ .disk = &disk };
    flow.inner.init(project, arena);
    _ = try flow.call(
        "POST",
        "/admin/setup",
        "email=ada%40example.com&display_name=Ada&password=correct+horse+battery",
    );

    var system = harness.ctx(.system);
    system.files = project.files;
    try registry.SDK.bootstrap(&system);

    const png = try encode.sample_png(arena, 8, 4);

    try project.files.?.write(.incoming, "upload0001", png);

    const uploaded = try registry.SDK.dispatch(&system, media.Upload, .{
        .upload = "upload0001",
        .filename = "harbour.png",
    });
    const library_page = try flow.call("GET", "/admin/media", "");

    try std.testing.expectEqual(.ok, library_page.status);
    const island = "data-part=\"media-library\"";

    try std.testing.expect(std.mem.indexOf(u8, library_page.body, island) != null);
    try std.testing.expect(std.mem.indexOf(u8, library_page.body, uploaded.key) != null);
    try std.testing.expect(std.mem.indexOf(u8, library_page.body, "PNG · 8 × 4") != null);

    const page_path = try std.fmt.allocPrint(arena, "/admin/media/{s}", .{uploaded.id});
    const file_page = try flow.call("GET", page_path, "");

    try std.testing.expectEqual(.ok, file_page.status);
    try std.testing.expect(std.mem.indexOf(u8, file_page.body, "harbour.png") != null);

    const csrf = flow.csrf_of(file_page.body);
    const form = try std.fmt.allocPrint(
        arena,
        "csrf={s}&title=Harbour&alt=Boats&focal_x=20&focal_y=80&folder=&tags=sea%2C+boats",
        .{csrf},
    );
    const streamed_head = try std.fmt.allocPrint(
        arena,
        "POST /media/upload?filename=boats.png HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
            "Cookie: {s}\r\nX-Csrf-Token: {s}\r\nContent-Length: {d}\r\n\r\n",
        .{ flow.cookie, csrf, png.len },
    );
    const streamed = try flow.inner.call(streamed_head, png);

    try std.testing.expectEqual(.created, streamed.status);
    try std.testing.expect(std.mem.indexOf(u8, streamed.body, "\"title\":\"boats\"") != null);

    const forged = try std.fmt.allocPrint(
        arena,
        "POST /media/upload?filename=x.png HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
            "Cookie: {s}\r\nContent-Length: {d}\r\n\r\n",
        .{ flow.cookie, png.len },
    );

    try std.testing.expectEqual(.forbidden, (try flow.inner.call(forged, png)).status);

    const saved = try flow.call("POST", page_path, form);

    try std.testing.expect(std.mem.endsWith(u8, saved.header("Location").?, "?saved=1"));

    const detail = try registry.SDK.dispatch(&system, media.Get, .{ .id = uploaded.id });

    try std.testing.expectEqualStrings("Boats", detail.alt);
    try std.testing.expectEqual(@as(u8, 80), detail.focal_y);
    try std.testing.expectEqual(@as(usize, 2), detail.tags.len);

    const served_path = try std.fmt.allocPrint(arena, "/media/{s}?w=4", .{uploaded.key});
    const served = try flow.call("GET", served_path, "");

    try std.testing.expectEqual(.ok, served.status);
    try std.testing.expectEqualStrings("image/png", served.header("Content-Type").?);
    try std.testing.expect(std.mem.startsWith(u8, served.body, "\x89PNG"));
    _ = try registry.SDK.dispatch(&system, media.Update, .{ .id = uploaded.id, .private = true });
    flow.cookie = "";

    const hidden = try flow.call("GET", served_path, "");

    try std.testing.expectEqual(.not_found, hidden.status);
}
