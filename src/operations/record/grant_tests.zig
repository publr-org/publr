const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const record = @import("../record.zig");
const term = @import("../term.zig");
const taxonomy = @import("../taxonomy.zig");
const types = @import("../content_type.zig");

const SDK = registry.SDK;
const Held = model.permission.Held;
const Access = sdk.plugin_access.Access;

/// Posts and notes, each with a draft and a live record: "Post draft", "Post published"...
pub fn seed_posts_and_notes(system: *sdk.Ctx) !void {
    std.debug.assert(system.caller == .system);

    var note = model.content_type.test_post;

    note.handle = "note";
    note.name = "Note";

    for ([_]model.content_type.Def{ model.content_type.test_post, note }) |def| {
        _ = try SDK.dispatch(system, types.Create, .{
            .definition = try model.content_type.encode(system.arena, def),
        });
    }

    for ([_][]const u8{ "post", "note" }) |handle| {
        for ([_][]const u8{ "draft", "published" }) |status| {
            const document = try std.fmt.allocPrint(
                system.arena,
                "{{\"title\":\"{c}{s} {s}\",\"body\":\"x\"}}",
                .{ std.ascii.toUpper(handle[0]), handle[1..], status },
            );

            _ = try SDK.dispatch(system, record.Create, .{
                .type = handle,
                .document = document,
                .status = status,
            });
        }
    }
}

fn seeded(harness: *sdk.testing.Harness, seed: *const fn (*sdk.Ctx) anyerror!void) !void {
    var system = harness.ctx(.system);

    std.debug.assert(harness.buffer.len > 0);

    try SDK.bootstrap(&system);
    try seed(&system);
}

fn plugin_caller(access: *const Access) sdk.Caller {
    std.debug.assert(access.held.len > 0);

    return .{
        .plugin = .{
            .name = "prices",
            .access = access,
        },
    };
}

fn titles_of(arena: std.mem.Allocator, listed: []const record.Record) ![]const u8 {
    std.debug.assert(listed.len <= 64);

    var joined: std.ArrayList(u8) = .empty;

    for (listed, 0..) |row, index| {
        try joined.appendSlice(arena, if (index == 0) "" else ", ");
        try joined.appendSlice(arena, row.title);
    }

    return joined.items;
}

test "records.read: a list or query over several types reads each by its own grant" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seeded(&harness, seed_posts_and_notes);

    const arena = harness.fixed.allocator();
    // Posts as a visitor sees them; notes, which it writes, drafts and all.
    const held = [_]Held{ .{
        .key = "records.read",
    }, .{
        .key = "records.write",
        .records = &.{"note"},
    } };
    const access: Access = .{
        .held = &held,
        .own_types = &.{},
    };
    var reader = harness.ctx(plugin_caller(&access));

    const listed = try SDK.dispatch(&reader, record.List, .{
        .types = &.{ "post", "note" },
        .order = .title_asc,
    });

    try std.testing.expectEqualStrings(
        "Note draft, Note published, Post published",
        try titles_of(arena, listed.records),
    );

    const every = try SDK.dispatch(&reader, record.List, .{
        .order = .title_asc,
    });

    try std.testing.expectEqual(@as(usize, 3), every.records.len);

    // Ids named (`many`): a draft post stays out, a draft note is found.
    var ids: [4][]const u8 = undefined;
    var system = harness.ctx(.system);
    const all = try SDK.dispatch(&system, record.List, .{
        .order = .title_asc,
    });

    for (all.records, &ids) |row, *id| {
        id.* = row.id;
    }

    const named = try SDK.dispatch(&reader, record.List, .{
        .types = &.{ "post", "note" },
        .ids = &.{ ids[0], ids[2] },
        .limit = 2,
    });

    try std.testing.expectEqualStrings("Note draft", try titles_of(arena, named.records));

    const queried = try SDK.dispatch(&reader, record.Query, .{
        .query = "*[_type in [\"post\", \"note\"]] | order(title asc) { title }",
    });
    const text = try std.json.Stringify.valueAlloc(arena, queried.result, .{});

    try std.testing.expectEqualStrings(
        "[{\"title\":\"Note draft\"},{\"title\":\"Note published\"}," ++
            "{\"title\":\"Post published\"}]",
        text,
    );

    // A draft post asked for by its id is not there for this reader.
    try std.testing.expectError(error.NotFound, SDK.dispatch(&reader, record.Get, .{
        .id = ids[2],
    }));
}

test "records.read .drafts reads drafts of every type it reaches; without it none" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seeded(&harness, seed_posts_and_notes);

    const arena = harness.fixed.allocator();
    var held = [_]Held{.{
        .key = "records.read",
        .drafts = true,
    }};
    const access: Access = .{
        .held = &held,
        .own_types = &.{},
    };
    var reader = harness.ctx(plugin_caller(&access));
    const drafts = try SDK.dispatch(&reader, record.List, .{
        .order = .title_asc,
    });

    try std.testing.expectEqual(@as(usize, 4), drafts.records.len);

    held[0].drafts = false;

    const live = try SDK.dispatch(&reader, record.List, .{
        .order = .title_asc,
    });

    try std.testing.expectEqualStrings(
        "Note published, Post published",
        try titles_of(arena, live.records),
    );
}

test "records.read without .drafts reads the live copy, never a record's pending changes" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seeded(&harness, seed_posts_and_notes);

    var system = harness.ctx(.system);
    const published = try SDK.dispatch(&system, record.List, .{
        .type = "post",
        .filters = &.{"status:is:published"},
    });
    const id = published.records[0].id;

    _ = try SDK.dispatch(&system, record.Save, .{
        .id = id,
        .document = "{\"title\":\"Post unpublished edit\",\"body\":\"x\"}",
    });

    const held = [_]Held{.{
        .key = "records.read",
    }};
    const access: Access = .{
        .granted = &.{"records.read"},
        .held = &held,
        .own_types = &.{},
    };
    var reader = harness.ctx(plugin_caller(&access));
    const got = try SDK.dispatch(&reader, record.Get, .{
        .id = id,
        .purpose = .edit,
    });

    try std.testing.expectEqualStrings("Post published", got.record.title);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&reader, record.Get, .{
        .id = id,
        .slot = "pending",
    }));

    const listed = try SDK.dispatch(&reader, record.List, .{
        .type = "post",
        .documents = true,
    });

    try std.testing.expectEqualStrings("Post published", listed.records[0].title);
    try std.testing.expect(std.mem.indexOf(u8, listed.documents[0], "unpublished") == null);
}

/// Topics (public) and Desk notes (private), each with a draft and a live term.
pub fn seed_taxonomies(system: *sdk.Ctx) !void {
    std.debug.assert(system.caller == .system);

    _ = try SDK.dispatch(system, taxonomy.Create, .{
        .definition = taxonomy.example_definition,
    });

    const private = try std.mem.replaceOwned(
        u8,
        system.arena,
        taxonomy.example_definition,
        "\"handle\":\"topics\",\"name\":\"Topics\",\"public\":true",
        "\"handle\":\"desk\",\"name\":\"Desk notes\",\"public\":false",
    );

    std.debug.assert(!std.mem.eql(u8, private, taxonomy.example_definition));

    _ = try SDK.dispatch(system, taxonomy.Create, .{
        .definition = private,
    });

    for ([_][]const u8{ "topics", "desk" }) |handle| {
        for ([_][]const u8{ "draft", "published" }) |status| {
            const document = try std.fmt.allocPrint(
                system.arena,
                "{{\"name\":\"{s} {s}\"}}",
                .{ handle, status },
            );

            _ = try SDK.dispatch(system, term.Create, .{
                .taxonomy = handle,
                .document = document,
                .status = status,
            });
        }
    }
}

test "terms.read: public taxonomies' live terms; .private and .drafts open more; names any" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seeded(&harness, seed_taxonomies);

    const arena = harness.fixed.allocator();
    var held = [_]Held{.{
        .key = "terms.read",
    }};
    const access: Access = .{
        .held = &held,
        .own_types = &.{},
    };
    var reader = harness.ctx(plugin_caller(&access));
    const visitor = try SDK.dispatch(&reader, term.List, .{
        .order = .title_asc,
    });

    try std.testing.expectEqualStrings("topics published", try titles_of(arena, visitor.terms));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&reader, term.Tree, .{
        .taxonomy = "desk",
    }));

    held[0].private = true;

    const private = try SDK.dispatch(&reader, term.List, .{
        .order = .title_asc,
    });

    try std.testing.expectEqualStrings(
        "desk published, topics published",
        try titles_of(arena, private.terms),
    );

    held[0].drafts = true;

    const tree = try SDK.dispatch(&reader, term.Tree, .{
        .taxonomy = "desk",
    });

    try std.testing.expectEqual(@as(usize, 2), tree.terms.len);

    held[0].private = false;
    held[0].drafts = false;
    held[0].taxonomies = &.{"desk"};

    const named = try SDK.dispatch(&reader, term.List, .{
        .order = .title_asc,
    });

    try std.testing.expectEqualStrings("desk published", try titles_of(arena, named.terms));
}

test "terms.write reads the taxonomies it writes, drafts too, beside a visitor's read" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seeded(&harness, seed_taxonomies);

    const arena = harness.fixed.allocator();
    const held = [_]Held{ .{
        .key = "terms.read",
    }, .{
        .key = "terms.write",
        .taxonomies = &.{"desk"},
    } };
    const access: Access = .{
        .held = &held,
        .own_types = &.{},
    };
    var reader = harness.ctx(plugin_caller(&access));
    const listed = try SDK.dispatch(&reader, term.List, .{
        .order = .title_asc,
    });

    try std.testing.expectEqualStrings(
        "desk draft, desk published, topics published",
        try titles_of(arena, listed.terms),
    );
}
