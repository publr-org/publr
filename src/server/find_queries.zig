//! What an agent finds: each query an agent asks is pinned to the answer that must come
//! first, over the real operations and the real guide, and each hint to the field it is
//! shown for. A discoverability miss becomes a line here before it is fixed.
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("registry.zig");
const find = @import("../adapters/cli/find.zig");

/// A query and the command or guide entry that must answer it first.
const Pinned = struct {
    query: []const u8,
    first: []const u8,
};

const pinned = [_]Pinned{
    .{
        .query = "group posts into categories",
        .first = "taxonomy create",
    },
    .{
        .query = "categories and tags for a blog",
        .first = "taxonomy create",
    },
    .{
        .query = "tag blog posts",
        .first = "taxonomy create",
    },
    .{
        .query = "add a category",
        .first = "term create",
    },
    .{
        .query = "publish a post later at a set time",
        .first = "record transition_at",
    },
    .{
        .query = "who may call an operation",
        .first = "operation authorize",
    },
    .{
        .query = "keep an api key",
        .first = "secret set",
    },
    .{
        .query = "upload a picture",
        .first = "media upload",
    },
    .{
        .query = "add fields to another type",
        .first = "custom_fields create",
    },
};

test "each pinned query answers its command first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const all = try find.documents(registry.SDK, arena, null, find.guide);

    var missed: u32 = 0;

    for (pinned) |case| {
        const found = try find.rank(arena, all, case.query);

        if (found.len == 0) {
            std.debug.print("`{s}` found nothing\n", .{case.query});
            missed += 1;
            continue;
        }

        const first = found[0].document;
        const named = if (first.command.len > 0) first.command else first.guide;

        if (!std.mem.eql(u8, named, case.first)) {
            std.debug.print("`{s}` answered first `{s}`, wanted `{s}`\n", .{
                case.query,
                named,
                case.first,
            });
            missed += 1;
        }
    }

    try std.testing.expectEqual(@as(u32, 0), missed);
}

test "the guide is read into entries, and a query reads none of its stop words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const all = try find.documents(registry.SDK, arena, null, find.guide);
    var taxonomies = false;

    for (all) |document| {
        if (std.mem.eql(u8, document.guide, "Taxonomies")) taxonomies = true;
    }

    try std.testing.expect(taxonomies);
    try std.testing.expectEqual(@as(usize, 0), (try find.rank(arena, all, "how do I")).len);
    try std.testing.expect((try find.rank(arena, all, "categories")).len <= find.matches_max);
}

test "a field named like a taxonomy gets the taxonomy's hint, once, when it is added" {
    const content_type = @import("../operations/content_type.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    const arena = system.arena;
    const Def = @import("../model.zig").content_type.Def;
    const first = try std.json.parseFromSliceLeaky(Def, arena,
        \\{"handle":"note","name":"Note","fields":[
        \\{"name":"title","label":"Title","kind":"string"},
        \\{"name":"category","label":"Category","kind":"string"}]}
    , .{});
    const made = try registry.SDK.dispatch(&system, content_type.Create, .{
        .definition = first,
    });

    try std.testing.expectEqual(@as(usize, 1), made.hints.len);
    try std.testing.expectEqualStrings("category", made.hints[0].field);
    try std.testing.expectEqualStrings("taxonomy create", made.hints[0].see);

    const second = try std.json.parseFromSliceLeaky(Def, arena,
        \\{"handle":"note","name":"Note","fields":[
        \\{"name":"title","label":"Title","kind":"string"},
        \\{"name":"category","label":"Category","kind":"string"},
        \\{"name":"tags","label":"Tags","kind":"string","many":true}]}
    , .{});
    const changed = try registry.SDK.dispatch(&system, content_type.Update, .{
        .type = "note",
        .definition = second,
    });

    // `category` was told already; only the field this change adds gets a hint.
    try std.testing.expectEqual(@as(usize, 1), changed.hints.len);
    try std.testing.expectEqualStrings("tags", changed.hints[0].field);
}

test "plugin check warns on a record field named like a taxonomy, and stops nothing" {
    const check = @import("plugin_build/check.zig");
    const doc_reader = @import("../sdk/plugin/doc_reader.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]doc_reader.File{.{
        .path = "main.zig",
        .text =
        \\const publr = @import("publr");
        \\
        \\/// A post
        \\const Post = struct {
        \\    /// Title
        \\    title: []const u8,
        \\    /// Category
        \\    category: []const u8 = "",
        \\};
        \\
        \\/// Posts
        \\pub const Posts = publr.record.define(Post, .{ .name = "blog.post" });
        \\
        ,
    }};
    const problems = try check.problems_of(arena, try doc_reader.source_of(arena, &files));
    var told = false;

    for (problems) |placed| {
        if (std.mem.indexOf(u8, placed.problem.message, "`category`") != null) {
            try std.testing.expect(placed.problem.warning);
            try std.testing.expectEqual(@as(u32, 8), placed.problem.line);
            told = true;
        }
    }

    try std.testing.expect(told);
    try std.testing.expect(!doc_reader.failing(problems));
}
