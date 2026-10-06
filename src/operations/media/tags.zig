//! A file's tags by name: finding the tag terms, making the missing ones.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const term = @import("../term.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const TagRef = @import("edit.zig").TagRef;

pub const tags_max: u32 = 64;
pub const name_len_max: u32 = 64;

/// The tags the ids name, with their names, in the same order; ids no longer a tag are left
/// out.
pub fn named(ctx: *Ctx, ids: []const []const u8) Error![]const TagRef {
    std.debug.assert(ids.len <= tags_max);
    std.debug.assert(ctx.now_ms >= 0);

    if (ids.len == 0) {
        return &.{};
    }

    const taxonomy = model.media.tags_handle;
    const tree = try registry.SDK.dispatch(ctx, term.Tree, .{ .taxonomy = taxonomy });
    var found: std.ArrayList(TagRef) = .empty;

    for (ids) |id| {
        for (tree.terms) |node| {
            if (std.mem.eql(u8, node.id, id)) {
                try found.append(ctx.arena, .{ .id = node.id, .name = node.title });
            }
        }
    }

    return found.items;
}

/// The tags of these names, by id, made published when missing. Names compare without
/// regard to case or surrounding spaces; repeats count once.
pub fn ensure(ctx: *Ctx, names: []const []const u8) Error![]const []const u8 {
    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (names.len > tags_max) {
        return error.Invalid;
    }

    const taxonomy = model.media.tags_handle;
    const tree = try registry.SDK.dispatch(ctx, term.Tree, .{ .taxonomy = taxonomy });
    var ids: std.ArrayList([]const u8) = .empty;

    for (names) |raw| {
        const wanted = std.mem.trim(u8, raw, " \t");

        if (wanted.len == 0 or wanted.len > name_len_max) {
            return error.Invalid;
        }

        const id = existing(tree.terms, wanted) orelse try create(ctx, wanted);

        if (!contains(ids.items, id)) {
            try ids.append(ctx.arena, id);
        }
    }

    std.debug.assert(ids.items.len <= names.len);

    return ids.items;
}

fn existing(nodes: []const term.Node, wanted: []const u8) ?[]const u8 {
    std.debug.assert(wanted.len > 0);

    for (nodes) |node| {
        if (std.ascii.eqlIgnoreCase(node.title, wanted)) {
            return node.id;
        }
    }

    return null;
}

fn create(ctx: *Ctx, wanted: []const u8) Error![]const u8 {
    std.debug.assert(wanted.len > 0 and wanted.len <= name_len_max);

    const Document = struct { name: []const u8 };
    const document = std.json.Stringify.valueAlloc(ctx.arena, Document{ .name = wanted }, .{}) catch
        return error.OutOfMemory;
    const created = try registry.SDK.dispatch(ctx, term.Create, .{
        .taxonomy = model.media.tags_handle,
        .document = document,
        .status = "published",
    });

    std.debug.assert(created.id.len > 0);

    return created.id;
}

fn contains(ids: []const []const u8, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (ids) |known| {
        if (std.mem.eql(u8, known, id)) {
            return true;
        }
    }

    return false;
}

/// `current` with `tag` added, or taken out when `remove`.
pub fn toggled(
    arena: std.mem.Allocator,
    current: []const []const u8,
    tag: []const u8,
    remove: bool,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(tag.len > 0);
    std.debug.assert(current.len <= tags_max);

    var next: std.ArrayList([]const u8) = .empty;

    for (current) |id| {
        if (!(remove and std.mem.eql(u8, id, tag))) {
            try next.append(arena, id);
        }
    }

    if (!remove and !contains(current, tag)) {
        try next.append(arena, tag);
    }

    return next.items;
}

test "toggled: adds once, removes what is there, leaves the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(usize, 2), (try toggled(arena, &.{"a"}, "b", false)).len);
    try std.testing.expectEqual(@as(usize, 1), (try toggled(arena, &.{"a"}, "a", false)).len);
    try std.testing.expectEqual(@as(usize, 0), (try toggled(arena, &.{"a"}, "a", true)).len);
    try std.testing.expectEqual(@as(usize, 1), (try toggled(arena, &.{"a"}, "b", true)).len);
}
