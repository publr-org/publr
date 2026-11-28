const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const record = @import("../record.zig");
const term = @import("../term.zig");
const taxonomy = @import("../taxonomy.zig");
const content_type = @import("../content_type.zig");
const model_content_type = @import("../../model/content_type.zig");
const custom_fields = @import("../custom_fields.zig");
const role = @import("../role.zig");
const user = @import("../user.zig");
const snapshot = @import("../snapshot.zig");
const Put = @import("put.zig").Put;
const deps = @import("../../lib/deps.zig");

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
            .rows = .{
                .text = rows,
            },
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

fn index_revision(ctx: *sdk.Ctx) !u64 {
    std.debug.assert(ctx.db.transaction_depth == 0);

    var index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };

    return index.revision();
}

fn changes_since(ctx: *sdk.Ctx, after: u64) ![]const []const u8 {
    std.debug.assert(ctx.db.transaction_depth == 0);

    var index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };

    return (try index.changes_since(ctx.arena, after)).keys;
}

fn has(keys: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    for (keys) |each| {
        if (std.mem.eql(u8, each, key)) {
            return true;
        }
    }

    return false;
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
        .document = .{
            .text = "{\"title\":\"Hello\",\"body\":\"x\"}",
        },
    });
    _ = try SDK.dispatch(&admin, record.Publish, .{
        .id = created.id,
    });
    const kept = try rows_of(&admin, .record, created.id);

    _ = try SDK.dispatch(&admin, record.Save, .{
        .id = created.id,
        .document = .{
            .text = "{\"title\":\"Hi\",\"body\":\"x\"}",
        },
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
            .rows = .{
                .text = "{}",
            },
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
        .definition = try model_content_type.read(
            admin.arena,
            "{\"handle\":\"note\",\"name\":\"Note\",\"fields\":[{\"name\":" ++
                "\"title\",\"label\":\"Title\",\"kind\":\"string\"}]}",
        ),
    });
    const topics = try SDK.dispatch(&admin, taxonomy.Create, .{
        .definition = try model_content_type.read(
            admin.arena,
            "{\"handle\":\"topic\",\"name\":\"Topic\",\"title_field\":\"name\"," ++
                "\"fields\":[{\"name\":\"name\",\"label\":\"Name\",\"kind\":\"string\"}]}",
        ),
    });
    const filed = try SDK.dispatch(&admin, term.Create, .{
        .taxonomy = "topic",
        .document = .{
            .text = "{\"name\":\"Zig\"}",
        },
    });

    _ = try SDK.dispatch(&admin, custom_fields.Update, .{
        .group = "user",
        .definition = try model_content_type.read(
            admin.arena,
            "{\"handle\":\"user\",\"name\":\"User fields\",\"kind\":\"component\"," ++
                "\"title_field\":\"\",\"fields\":[{\"name\":\"bio\",\"label\":\"Bio\"," ++
                "\"kind\":\"text\"}]}",
        ),
    });
    _ = try SDK.dispatch(&admin, role.Create, .{
        .name = "reviewer",
        .label = "Reviewer",
    });

    const person = try SDK.dispatch(&admin, user.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .roles = &.{"editor"},
    });

    // A member's user type travels with the account.
    try std.testing.expect(try store.user_types.add(admin.db, person.user_id, "member"));
    try std.testing.expect(std.mem.indexOf(
        u8,
        try rows_of(&admin, .user, person.user_id),
        "\"user_types\":[{\"user_id\":",
    ) != null);

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
        \\ "previous_manifest":null,"installed_at":1,"updated_at":2}]}
    ;

    const before_internal = try index_revision(&admin);

    try std.testing.expectEqualStrings("added", try put_one(&admin, .internal, "i1", internal));

    // A page that showed what is worked out from it rebuilds.
    const raised = try changes_since(&admin, before_internal);

    try std.testing.expect(has(raised, "internal:shelf/bin/i1"));
    try std.testing.expect(has(raised, "internal:shelf/bin"));
    try round_trip(&admin, .internal, "i1");
    try std.testing.expectEqualStrings("added", try put_one(&admin, .plugin, "shelf", plugin));
    try round_trip(&admin, .plugin, "shelf");
    try std.testing.expectError(error.Denied, put_one(&editor, .plugin, "shelf", "{}"));
}

test "project.put carries a file's row with its record; removing it keeps it in the trash" {
    const files_module = @import("../../lib/files.zig");
    const upload = @import("../media/upload.zig");
    const media_edit = @import("../media/edit.zig");
    const trash = @import("../trash.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var disk = try files_module.Disk.open(std.testing.io, root);
    defer disk.close();

    var system = harness.ctx(.system);
    system.files = .{
        .disk = &disk,
    };
    try SDK.bootstrap(&system);
    try system.files.?.write(.incoming, "upload0001", "plain words");

    const notes = try SDK.dispatch(&system, upload.Upload, .{
        .upload = "upload0001",
        .filename = "notes.txt",
    });
    const kept = try system.arena.dupe(u8, try rows_of(&system, .record, notes.id));

    try std.testing.expect(std.mem.indexOf(u8, kept, "\"media\":[{\"record\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"filename\":\"notes.txt\"") != null);

    // Rows that leave the file's row out leave it as it is.
    const end = std.mem.indexOf(u8, kept, ",\"media\":").?;
    const without = try std.fmt.allocPrint(system.arena, "{s}}}", .{kept[0..end]});

    const left_out = try put_one(&system, .record, notes.id, without);

    try std.testing.expectEqualStrings("unchanged", left_out);

    // Removed: into the trash with its file set aside, as `media.delete` leaves it.
    try std.testing.expectEqualStrings("removed", try put_one(&system, .record, notes.id, "{}"));

    const listed = try SDK.dispatch(&system, trash.List, .{});

    try std.testing.expectEqual(@as(usize, 1), listed.entries.len);
    try std.testing.expectEqualStrings("File notes.txt", listed.entries[0].label);
    try std.testing.expectError(
        error.NotFound,
        system.files.?.read(std.testing.allocator, .files, notes.key, 1024),
    );

    const trashed = try system.files.?.read(std.testing.allocator, .trash, notes.key, 1024);
    defer std.testing.allocator.free(trashed);

    try std.testing.expectEqualStrings("plain words", trashed);

    // Put back, its row is back with it, the file where the caller put it.
    try system.files.?.write(.files, notes.key, "plain words");
    try std.testing.expectEqualStrings("added", try put_one(&system, .record, notes.id, kept));
    try std.testing.expectEqualStrings(kept, try rows_of(&system, .record, notes.id));

    // Back in the library, so what the trash kept of it goes.
    const emptied = try SDK.dispatch(&system, trash.List, .{});

    try std.testing.expectEqual(@as(usize, 0), emptied.entries.len);
    try std.testing.expectError(
        error.NotFound,
        system.files.?.read(std.testing.allocator, .trash, notes.key, 1024),
    );

    const got = try SDK.dispatch(&system, media_edit.Get, .{
        .id = notes.id,
    });

    try std.testing.expectEqualStrings("notes.txt", got.media.filename);

    // Put naming another file: the one it no longer names goes.
    const other = "2026/11/other-ab12.txt";
    const moved = try std.mem.replaceOwned(u8, system.arena, kept, notes.key, other);

    try system.files.?.write(.files, other, "plain words");
    try std.testing.expectEqualStrings("replaced", try put_one(&system, .record, notes.id, moved));
    try std.testing.expectError(
        error.NotFound,
        system.files.?.read(std.testing.allocator, .files, notes.key, 1024),
    );
}
