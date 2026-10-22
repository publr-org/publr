const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const record = @import("../record.zig");

const SDK = registry.SDK;

fn person(harness: *sdk.testing.Harness, id: []const u8, role: []const u8) sdk.Ctx {
    std.debug.assert(id.len > 0);
    std.debug.assert(role.len > 0);

    const roles = harness.fixed.allocator().dupe([]const u8, &.{role}) catch unreachable;

    return harness.ctx(.{
        .user = .{
            .id = id,
            .roles = roles,
        },
    });
}

fn requested_of(ctx: *sdk.Ctx, id: []const u8) ![]const u8 {
    const got = try SDK.dispatch(ctx, record.Get, .{
        .id = id,
        .purpose = .edit,
    });

    return got.record.requested;
}

test "a contributor asks; what goes live waits for someone who may publish" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record.fixture.post_type(&system);

    var writer = person(&harness, "u_con", "contributor");
    var other = person(&harness, "u_other", "contributor");
    var editor = person(&harness, "u_ed", "editor");
    const created = try SDK.dispatch(&writer, record.Create, .{
        .type = "post",
        .document = "{\"title\":\"Hello\",\"body\":\"x\"}",
    });

    // Nothing visitors see changes: archiving a draft and back moves at once.
    const archived = try SDK.dispatch(&writer, record.Transition, .{
        .id = created.id,
        .transition = "archive",
    });
    try std.testing.expect(!archived.pending);
    try std.testing.expectEqualStrings("archived", archived.status);
    _ = try SDK.dispatch(&writer, record.Transition, .{
        .id = created.id,
        .transition = "unarchive",
    });

    // Publishing waits, kept on the record; every other way live is refused.
    const asked = try SDK.dispatch(&writer, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    try std.testing.expect(asked.pending);
    try std.testing.expectEqualStrings("draft", asked.status);
    try std.testing.expectEqualStrings("publish", try requested_of(&editor, created.id));
    try std.testing.expectError(error.Denied, SDK.dispatch(&writer, record.Publish, .{
        .id = created.id,
    }));
    try std.testing.expectError(error.Denied, SDK.dispatch(&writer, record.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Hello\",\"body\":\"x\"}",
        .status = "published",
    }));

    try std.testing.expectError(error.Denied, SDK.dispatch(&writer, record.Create, .{
        .type = "post",
        .document = "{\"title\":\"Straight out\",\"body\":\"x\"}",
        .status = "published",
    }));

    // Only the asker withdraws their own; someone who may publish declines any.
    try std.testing.expectError(error.Denied, SDK.dispatch(&other, record.DeclineRequest, .{
        .id = created.id,
    }));
    _ = try SDK.dispatch(&writer, record.DeclineRequest, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("", try requested_of(&editor, created.id));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&editor, record.DeclineRequest, .{
        .id = created.id,
    }));

    // Approving is the transition run by someone who may; it settles the request.
    _ = try SDK.dispatch(&writer, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    const approved = try SDK.dispatch(&editor, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    try std.testing.expectEqualStrings("published", approved.status);
    try std.testing.expectEqualStrings("", try requested_of(&editor, created.id));

    // Changes to a live record wait too, published by `publish` or declined.
    _ = try SDK.dispatch(&writer, record.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Hello again\",\"body\":\"x\"}",
    });
    const changes = try SDK.dispatch(&writer, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    try std.testing.expect(changes.pending);
    try std.testing.expect(changes.changed);
    const declined = try SDK.dispatch(&editor, record.DeclineRequest, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("publish", declined.declined);
    _ = try SDK.dispatch(&writer, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    const live = try SDK.dispatch(&editor, record.Publish, .{
        .id = created.id,
    });
    try std.testing.expect(!live.changed);
    try std.testing.expectEqualStrings("", try requested_of(&editor, created.id));

    // Taking it off live waits as well.
    const off = try SDK.dispatch(&writer, record.Transition, .{
        .id = created.id,
        .transition = "archive",
    });
    try std.testing.expect(off.pending);
    try std.testing.expectEqualStrings("published", off.status);
    try std.testing.expectEqualStrings("archive", try requested_of(&editor, created.id));
}
