//! Which writes to records raise keys in the site-changes index: heard around the record
//! operations, a move over many included.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const registry = @import("../../server/registry.zig");
const content_type = @import("../content_type.zig");
const record = @import("../record.zig");
const term = @import("../term.zig");

const SDK = registry.SDK;

const note_definition = "{\"handle\":\"note\",\"name\":\"Note\",\"public\":true,\"fields\":[" ++
    "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\"}]}";

/// The distinct keys raised since `after`, and the revision they reach.
fn raised(ctx: *sdk.Ctx, after: u64) !deps.Index.Changes {
    std.debug.assert(ctx.db.transaction_depth == 0);

    var index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };

    return index.changes_since(ctx.arena, after);
}

test "site changes: live writes and moves raise, pending edits and drafts do not" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    _ = try SDK.dispatch(&system, content_type.Create, .{
        .definition = note_definition,
    });

    const start = (try raised(&system, 0)).revision;
    const draft = try SDK.dispatch(&system, record.Create, .{
        .type = "note",
        .document = "{\"title\":\"Draft\"}",
    });

    try std.testing.expectEqual(start, (try raised(&system, start)).revision);

    const live = try SDK.dispatch(&system, record.Create, .{
        .type = "note",
        .document = "{\"title\":\"Live\"}",
    });
    _ = try SDK.dispatch(&system, record.Publish, .{
        .id = live.id,
    });
    const created = try raised(&system, start);

    try std.testing.expectEqual(@as(usize, 3), created.keys.len);
    try std.testing.expectEqualStrings("records", created.keys[1]);
    try std.testing.expectEqualStrings("type:note", created.keys[2]);

    // An edit parked on the live record changes nothing visitors see.
    _ = try SDK.dispatch(&system, record.Save, .{
        .id = live.id,
        .document = "{\"title\":\"Live, edited\"}",
    });
    try std.testing.expectEqual(created.revision, (try raised(&system, start)).revision);

    // Its changes applied by `publish` named on the live record: no move, still raised.
    _ = try SDK.dispatch(&system, record.Transition, .{
        .id = live.id,
        .transition = "publish",
    });

    const published = try raised(&system, created.revision);

    try std.testing.expect(published.revision > created.revision);

    // Taken out of live, many at once: raised as it leaves, from where it was.
    _ = try SDK.dispatch(&system, record.TransitionMany, .{
        .transition = "unpublish",
        .ids = &.{live.id},
    });

    const unpublished = try raised(&system, published.revision);
    const draft_key = try std.fmt.allocPrint(system.arena, "record:{s}", .{draft.id});
    const live_key = try std.fmt.allocPrint(system.arena, "record:{s}", .{live.id});

    try std.testing.expect(contains(unpublished.keys, live_key));
    try std.testing.expect(!contains(unpublished.keys, draft_key));

    // Both trashed at once: the drafts too, as the trash always raises.
    _ = try SDK.dispatch(&system, record.TransitionMany, .{
        .transition = "trash",
        .ids = &.{ draft.id, live.id },
    });

    const trashed = try raised(&system, unpublished.revision);

    try std.testing.expectEqual(@as(usize, 4), trashed.keys.len);
    try std.testing.expect(contains(trashed.keys, draft_key));
    try std.testing.expect(contains(trashed.keys, live_key));
}

fn contains(keys: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    for (keys) |each| {
        if (std.mem.eql(u8, each, key)) {
            return true;
        }
    }

    return false;
}

test "site changes: a page's reads name the record, the type and every record" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    _ = try SDK.dispatch(&system, content_type.Create, .{
        .definition = note_definition,
    });

    const made = try SDK.dispatch(&system, record.Create, .{
        .type = "note",
        .document = "{\"title\":\"Read\"}",
    });
    var named: sdk.testing.reads.Named = .{};
    var drawing = system;
    drawing.reads = named.reads();

    _ = try SDK.dispatch(&drawing, record.Get, .{
        .id = made.id,
    });
    _ = try SDK.dispatch(&drawing, record.List, .{
        .type = "note",
    });
    _ = try SDK.dispatch(&drawing, record.Query, .{
        .query = "*[_type == \"note\"]",
    });

    const record_key = try std.fmt.allocPrint(system.arena, "record:{s}", .{made.id});

    try std.testing.expect(named.has(record_key));
    try std.testing.expect(named.has("type:note"));
    try std.testing.expect(named.has("records"));
}

test "site changes: live terms raise, pending edits do not; a page's term reads name them" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try term.seed_topics(&harness);

    var system = harness.ctx(.system);
    const made = try SDK.dispatch(&system, term.Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Draft\"}",
    });
    const start = (try raised(&system, 0)).revision;

    _ = try SDK.dispatch(&system, term.Publish, .{
        .id = made.id,
    });

    const live = try raised(&system, start);
    const term_key = try std.fmt.allocPrint(system.arena, "term:{s}", .{made.id});

    try std.testing.expect(contains(live.keys, term_key));
    try std.testing.expect(contains(live.keys, "taxonomy:topics"));
    try std.testing.expect(contains(live.keys, "terms"));

    // An edit parked on the live term changes nothing visitors see; applying it does.
    _ = try SDK.dispatch(&system, term.Save, .{
        .id = made.id,
        .document = "{\"name\":\"Live, edited\"}",
    });
    try std.testing.expectEqual(live.revision, (try raised(&system, start)).revision);

    _ = try SDK.dispatch(&system, term.Publish, .{
        .id = made.id,
    });
    try std.testing.expect((try raised(&system, live.revision)).revision > live.revision);

    var named: sdk.testing.reads.Named = .{};
    var drawing = system;
    drawing.reads = named.reads();

    _ = try SDK.dispatch(&drawing, term.Get, .{
        .id = made.id,
    });
    _ = try SDK.dispatch(&drawing, term.Tree, .{
        .taxonomy = "topics",
    });

    try std.testing.expect(named.has(term_key));
    try std.testing.expect(named.has("taxonomy:topics"));
    try std.testing.expect(named.has("terms"));
}
