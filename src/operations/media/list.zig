const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const term = @import("../term.zig");
const library = @import("library.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const listing = store.media.list;

pub const page_size_default: u32 = 25;

pub const Folder = struct {
    id: []const u8,
    name: []const u8,
    parent: ?[]const u8,
    depth: u32,
    /// The files in it and below it that the rest of the filter keeps.
    count: u32,
};

pub const Tag = struct { id: []const u8, name: []const u8, count: u32 };

pub const Period = struct { year: u32, month: u32, count: u32 };

pub const List = struct {
    pub const name = "media.list";
    pub const description = "The library's files a filter keeps, with the explorer's counts";
    pub const details =
        \\Newest first, `limit` a page (25 by default). `folder` is a folder's id (its files
        \\and those of the folders below it), `unsorted` (files in no folder), `unreviewed`
        \\(files taken in from the media folder that no one has looked at), or empty for
        \\all. Every tag in `tags` must be on a file; `search` matches its name or title;
        \\`year` and `month` its upload date; `kind`, `size` and `visibility` the file
        \\itself. Beside the page: the folder tree, each folder with the files it would show
        \\keeping the rest of the filter; the tags, each with what adding it would leave;
        \\the months files were uploaded in; and what All files, Unsorted and Unreviewed
        \\would hold. Signed-in callers only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        folder: []const u8 = "",
        tags: []const []const u8 = &.{},
        search: []const u8 = "",
        year: ?u32 = null,
        month: ?u32 = null,
        kind: []const u8 = "",
        size: []const u8 = "",
        visibility: []const u8 = "",
        limit: u32 = page_size_default,
        offset: u32 = 0,
    };
    pub const Out = struct {
        items: []const library.Item,
        /// How many files the whole filter keeps.
        total: u32,
        all: u32,
        unsorted: u32,
        unreviewed: u32,
        folders: []const Folder,
        tags: []const Tag,
        periods: []const Period,
    };
    pub const example: In = .{ .folder = "unsorted", .limit = 25 };
    pub const example_out: Out = .{
        .items = &.{library.example_item},
        .total = 1,
        .all = 3,
        .unsorted = 1,
        .unreviewed = 0,
        .folders = &.{.{
            .id = "2a3b4c5d6e7f80910a1b2c3d",
            .name = "Photos",
            .parent = null,
            .depth = 0,
            .count = 0,
        }},
        .tags = &.{},
        .periods = &.{.{ .year = 2026, .month = 10, .count = 3 }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .folder = "A folder's id, `unsorted`, `unreviewed`, or empty for every file",
        .tags = "Tag ids; a file must carry each one",
        .search = "Part of a file's name or title",
        .year = "Uploaded in this year",
        .month = "With `year`: uploaded in this month, 1 to 12",
        .kind = "`image`, `video`, `audio`, `pdf` or `other`; empty for any",
        .size = "`small` (under 1 MiB), `medium` (1 to 10 MiB) or `large`; empty for any",
        .visibility = "`public` or `private`; empty for both",
        .limit = "Page size, up to 200",
        .offset = "Files to skip",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .items = "The page of files",
        .total = "How many files the filter keeps",
        .all = "How many the filter keeps in any folder",
        .unsorted = "How many it keeps in no folder",
        .unreviewed = "How many it keeps that came from the media folder unreviewed",
        .folders = "Every folder in tree order, with its depth and count",
        .tags = "Every tag, with its count",
        .periods = "The months files were uploaded in, newest first, with counts",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const filter = try filter_of(in);
        const limit = @max(1, @min(in.limit, listing.page_max));
        const rows = try listing.items(ctx.db, ctx.arena, filter, limit, in.offset);
        const items = try ctx.arena.alloc(library.Item, rows.len);

        for (rows, items) |row, *item| {
            item.* = library.item_of(row, row.title);
        }

        return .{
            .items = items,
            .total = try listing.count(ctx.db, ctx.arena, filter),
            .all = try listing.all_count(ctx.db, ctx.arena, filter),
            .unsorted = try listing.unsorted_count(ctx.db, ctx.arena, filter),
            .unreviewed = try listing.unreviewed_count(ctx.db, ctx.arena, filter),
            .folders = try folders_of(ctx, filter),
            .tags = try tags_of(ctx, filter),
            .periods = try periods_of(ctx, filter),
        };
    }
};

fn filter_of(in: List.In) Error!listing.Filter {
    std.debug.assert(listing.tags_max > 0);

    if (in.tags.len > listing.tags_max or in.search.len > listing.search_len_max) {
        return error.Invalid;
    }

    if (in.folder.len > 64 or (in.month != null and (in.month.? < 1 or in.month.? > 12))) {
        return error.Invalid;
    }

    const folder: listing.Folder = if (in.folder.len == 0)
        .any
    else if (std.mem.eql(u8, in.folder, "unsorted"))
        .unsorted
    else if (std.mem.eql(u8, in.folder, "unreviewed"))
        .unreviewed
    else
        .{ .term = in.folder };

    std.debug.assert(folder != .term or folder.term.len > 0);

    const kind = if (in.kind.len == 0)
        null
    else
        std.meta.stringToEnum(listing.Kind, in.kind) orelse return error.Invalid;
    const size = if (in.size.len == 0)
        null
    else
        std.meta.stringToEnum(listing.Size, in.size) orelse return error.Invalid;
    const private: ?bool = if (in.visibility.len == 0)
        null
    else if (std.mem.eql(u8, in.visibility, "private"))
        true
    else if (std.mem.eql(u8, in.visibility, "public"))
        false
    else
        return error.Invalid;

    return .{
        .kind = kind,
        .size = size,
        .private = private,
        .folder = folder,
        .tags = in.tags,
        .search = std.mem.trim(u8, in.search, " "),
        .year = in.year,
        .month = if (in.year != null) in.month else null,
    };
}

fn count_of(counts: []const listing.TermCount, id: []const u8) u32 {
    std.debug.assert(id.len > 0);
    std.debug.assert(counts.len <= 1 << 20);

    for (counts) |found| {
        if (std.mem.eql(u8, found.term, id)) {
            return @intCast(found.count);
        }
    }

    return 0;
}

fn folders_of(ctx: *Ctx, filter: listing.Filter) Error![]const Folder {
    std.debug.assert(filter.tags.len <= listing.tags_max);

    const tree = try registry.SDK.dispatch(ctx, term.Tree, .{
        .taxonomy = model.media.folders_handle,
    });
    const counts = try listing.term_counts(ctx.db, ctx.arena, filter, .folders);
    const folders = try ctx.arena.alloc(Folder, tree.terms.len);

    for (tree.terms, folders) |node, *folder| {
        folder.* = .{
            .id = node.id,
            .name = node.title,
            .parent = node.parent,
            .depth = node.depth,
            .count = count_of(counts, node.id),
        };
    }

    std.debug.assert(folders.len == tree.terms.len);

    return folders;
}

fn tags_of(ctx: *Ctx, filter: listing.Filter) Error![]const Tag {
    std.debug.assert(filter.tags.len <= listing.tags_max);

    const tree = try registry.SDK.dispatch(ctx, term.Tree, .{
        .taxonomy = model.media.tags_handle,
    });
    const counts = try listing.term_counts(ctx.db, ctx.arena, filter, .tags);
    const tags = try ctx.arena.alloc(Tag, tree.terms.len);

    for (tree.terms, tags) |node, *tag| {
        tag.* = .{ .id = node.id, .name = node.title, .count = count_of(counts, node.id) };
    }

    std.debug.assert(tags.len == tree.terms.len);

    return tags;
}

fn periods_of(ctx: *Ctx, filter: listing.Filter) Error![]const Period {
    std.debug.assert(filter.tags.len <= listing.tags_max);

    const found = try listing.periods(ctx.db, ctx.arena, filter);
    const periods = try ctx.arena.alloc(Period, found.len);

    for (found, periods) |row, *period| {
        period.* = .{
            .year = @intCast(row.year),
            .month = @intCast(row.month),
            .count = @intCast(row.count),
        };
    }

    std.debug.assert(periods.len == found.len);

    return periods;
}
