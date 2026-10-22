const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const record = @import("../record.zig");
const term = @import("../term.zig");
const taxonomy = @import("../taxonomy.zig");
const content_type = @import("../content_type.zig");
const custom_fields = @import("../custom_fields.zig");
const role = @import("../role.zig");
const user = @import("../user.zig");
const snapshot = @import("../snapshot.zig");
const Put = @import("put.zig").Put;

const SDK = registry.SDK;
const stored_rows = store.stored_rows;

fn rows_of(ctx: *sdk.Ctx, kind: stored_rows.Kind, id: []const u8) ![]const u8 {
    std.debug.assert(id.len > 0);

    return stored_rows.read(ctx.db, ctx.arena, stored_rows.shape_of(kind), id);
}

fn put_one(ctx: *sdk.Ctx, kind: stored_rows.Kind, id: []const u8, rows: []const u8) ![]const u8 {
    std.debug.assert(id.len > 0);

    const out = try SDK.dispatch(ctx, Put, .{
        .units = &.{.{
            .kind = @tagName(kind),
            .id = id,
            .rows = rows,
        }},
    });

    std.debug.assert(out.put.len == 1);

    return out.put[0].outcome;
}

/// Removed, put back with its id, and put again changing nothing.
fn round_trip(ctx: *sdk.Ctx, kind: stored_rows.Kind, id: []const u8) !void {
    std.debug.assert(id.len > 0);

    const kept = try rows_of(ctx, kind, id);

    try std.testing.expect(!std.mem.eql(u8, kept, "{}"));
    try std.testing.expectEqualStrings("removed", try put_one(ctx, kind, id, "{}"));
    try std.testing.expectEqualStrings("{}", try rows_of(ctx, kind, id));
    try std.testing.expectEqualStrings("unchanged", try put_one(ctx, kind, id, "{}"));
    try std.testing.expectEqualStrings("added", try put_one(ctx, kind, id, kept));
    try std.testing.expectEqualStrings(kept, try rows_of(ctx, kind, id));
    try std.testing.expectEqualStrings("unchanged", try put_one(ctx, kind, id, kept));
}

fn title_of(ctx: *sdk.Ctx, id: []const u8) ![]const u8 {
    const got = try SDK.dispatch(ctx, record.Get, .{
        .id = id,
    });

    return got.record.title;
}

test "project.put puts a record as kept elsewhere: a person's change, plugins and admins only" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record.fixture.post_type(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    const created = try SDK.dispatch(&admin, record.Create, .{
        .type = "post",
        .document = "{\"title\":\"Hello\",\"body\":\"x\"}",
        .status = "published",
    });
    const kept = try rows_of(&admin, .record, created.id);

    _ = try SDK.dispatch(&admin, record.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Hi\",\"body\":\"x\"}",
    });
    _ = try SDK.dispatch(&admin, record.Publish, .{
        .id = created.id,
    });

    try std.testing.expectError(error.Denied, put_one(&editor, .record, created.id, kept));
    try std.testing.expectEqualStrings("replaced", try put_one(&admin, .record, created.id, kept));

    const revisions = try SDK.dispatch(&admin, snapshot.List, .{
        .id = created.id,
        .kind = "revision",
        .documents = true,
    });

    try std.testing.expectEqualStrings("Hello", try title_of(&admin, created.id));
    // The live "Hi" it replaced is kept, as a publish would keep it.
    try std.testing.expectEqualStrings("Hi", revisions.snapshots[0].title);
    try std.testing.expectEqualStrings("unchanged", try put_one(&admin, .record, created.id, kept));
    const foreign = put_one(&admin, .record, created.id, "{\"users\":[]}");

    try std.testing.expectError(error.Invalid, foreign);
    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, Put, .{
        .units = &.{.{
            .kind = "media",
            .id = created.id,
            .rows = "{}",
        }},
    }));

    try round_trip(&admin, .record, created.id);
    try std.testing.expectEqualStrings("Hello", try title_of(&admin, created.id));
}

test "project.put puts every kind with its id: removed, back, and unchanged when run again" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    const note = try SDK.dispatch(&admin, content_type.Create, .{
        .definition = "{\"handle\":\"note\",\"name\":\"Note\",\"fields\":[{\"name\":" ++
            "\"title\",\"label\":\"Title\",\"kind\":\"string\"}]}",
    });
    const topics = try SDK.dispatch(&admin, taxonomy.Create, .{
        .definition = "{\"handle\":\"topic\",\"name\":\"Topic\",\"title_field\":\"name\"," ++
            "\"fields\":[{\"name\":\"name\",\"label\":\"Name\",\"kind\":\"string\"}]}",
    });
    const filed = try SDK.dispatch(&admin, term.Create, .{
        .taxonomy = "topic",
        .document = "{\"name\":\"Zig\"}",
    });

    _ = try SDK.dispatch(&admin, custom_fields.Update, .{
        .group = "user",
        .definition = "{\"handle\":\"user\",\"name\":\"User fields\",\"kind\":\"component\"," ++
            "\"title_field\":\"\",\"fields\":[{\"name\":\"bio\",\"label\":\"Bio\"," ++
            "\"kind\":\"text\"}]}",
    });
    _ = try SDK.dispatch(&admin, role.Create, .{
        .name = "reviewer",
        .label = "Reviewer",
    });

    const person = try SDK.dispatch(&admin, user.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
    });

    try round_trip(&admin, .term, filed.id);
    try round_trip(&admin, .taxonomy, topics.id);
    try round_trip(&admin, .content_type, note.id);
    try round_trip(&admin, .field_group, "user");
    try round_trip(&admin, .role, "reviewer");
    try round_trip(&admin, .user, person.user_id);

    const internal =
        \\{"internal_records":[{"id":"i1","plugin":"shelf","app":"","kind":"bin","document":"{}",
        \\ "version":1,"created_at":1,"updated_at":2}],
        \\ "internal_record_values":[{"record":"i1","field":"sku","value":"A1"}]}
    ;
    const plugin =
        \\{"sandboxed_plugins":[{"name":"shelf","version":"0.1.0","hash":"ab","manifest":"{}",
        \\ "enabled":0,"granted":"[]","denied":"[]","grants":"{}","next_version":null,
        \\ "next_hash":null,"next_manifest":null,"previous_version":null,"previous_hash":null,
        \\ "previous_manifest":null,"installed_at":1,"updated_at":2,"remove_data":"[]"}]}
    ;

    try std.testing.expectEqualStrings("added", try put_one(&admin, .internal, "i1", internal));
    try round_trip(&admin, .internal, "i1");
    try std.testing.expectEqualStrings("added", try put_one(&admin, .plugin, "shelf", plugin));
    try round_trip(&admin, .plugin, "shelf");
    try std.testing.expectError(error.Denied, put_one(&editor, .plugin, "shelf", "{}"));
}
