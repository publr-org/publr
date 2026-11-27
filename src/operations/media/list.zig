const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/media/list.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const term = @import("../term.zig");
const library = @import("library.zig");
const media_base = @import("../../sdk/media_base.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const listing = store.media.list;

pub const page_size_default = public.page_size_default;

pub const Folder = public.Folder;

pub const Tag = public.Tag;

pub const Period = public.Period;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const media_type = try library.media_type_for(ctx, granted, in.type);
        const library_type = model.media.is_library(media_type.def.handle);

        if (!library_type and (in.folder.len > 0 or in.tags.len > 0)) {
            return error.Invalid;
        }

        var filter = try filter_of(in);

        filter.type_id = media_type.id;

        if (library.public_only(granted)) {
            filter.private = false;
        }

        const limit = @max(1, @min(in.limit, listing.page_max));
        const rows = try listing.items(ctx.db, ctx.arena, filter, limit, in.offset);
        const items = try ctx.arena.alloc(library.Item, rows.len);
        const base = try media_base.of(ctx);

        for (rows, items) |row, *item| {
            const url = try media_base.under(ctx.arena, base, row.storage_key);

            item.* = library.item_of(row, row.title, url);
        }

        return .{
            .items = items,
            .total = try listing.count(ctx.db, ctx.arena, filter),
            .all = try listing.all_count(ctx.db, ctx.arena, filter),
            .unsorted = try listing.unsorted_count(ctx.db, ctx.arena, filter),
            .unreviewed = try listing.unreviewed_count(ctx.db, ctx.arena, filter),
            .folders = if (library_type) try folders_of(ctx, filter) else &.{},
            .tags = if (library_type) try tags_of(ctx, filter) else &.{},
            .periods = try periods_of(ctx, filter),
        };
    }
};

fn filter_of(in: List.In) Error!listing.Filter {
    std.debug.assert(listing.tags_max > 0);

    if (in.tags.len > listing.tags_max or in.search.len > listing.search_len_max) {
        return error.Invalid;
    }

    if (in.families.len > model.field.options.media_types_max) {
        return error.Invalid;
    }

    for (in.families) |family| {
        if (!model.field.options.valid_media_type(family)) {
            return error.Invalid;
        }
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
        .{
            .term = in.folder,
        };

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
        .families = in.families,
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

/// The terms' ids as a JSON array, for a query of their counts.
fn ids_json(ctx: *Ctx, nodes: []const term.Node) Error![]const u8 {
    std.debug.assert(nodes.len <= sdk.operation.page_limit_max);

    const ids = try ctx.arena.alloc([]const u8, nodes.len);

    for (nodes, ids) |node, *id| {
        id.* = node.id;
    }

    return std.json.Stringify.valueAlloc(ctx.arena, ids, .{}) catch error.OutOfMemory;
}

fn folders_of(ctx: *Ctx, filter: listing.Filter) Error![]const Folder {
    std.debug.assert(filter.tags.len <= listing.tags_max);

    const tree = try registry.SDK.dispatch(ctx, term.Tree, .{
        .taxonomy = model.media.folders_handle,
        .limit = sdk.operation.page_limit_max,
    });
    const counts = try listing.term_counts(ctx.db, ctx.arena, filter, .folders, try ids_json(
        ctx,
        tree.terms,
    ));
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
        .limit = sdk.operation.page_limit_max,
    });
    const counts = try listing.term_counts(ctx.db, ctx.arena, filter, .tags, try ids_json(
        ctx,
        tree.terms,
    ));
    const tags = try ctx.arena.alloc(Tag, tree.terms.len);

    for (tree.terms, tags) |node, *tag| {
        tag.* = .{
            .id = node.id,
            .name = node.title,
            .count = count_of(counts, node.id),
        };
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
