const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const role = @import("../../model/role.zig");
const roles = @import("../role.zig");
const user = @import("../user.zig");
const trash = @import("../trash.zig");

const SDK = registry.SDK;

fn find(listed: []const roles.Listed, name: []const u8) ?roles.Listed {
    std.debug.assert(name.len > 0);

    for (listed) |one| {
        if (std.mem.eql(u8, one.name, name)) {
            return one;
        }
    }

    return null;
}

test "core's roles are rows; administrators only, and admin never changes" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_editor",
            .roles = &.{role.editor},
        },
    });

    const listed = (try SDK.dispatch(&admin, roles.List, .{})).roles;

    try std.testing.expect(find(listed, role.admin).?.locked);
    try std.testing.expectEqualStrings(role.owner_core, find(listed, role.editor).?.owner);
    try std.testing.expect(!find(listed, role.contributor).?.changed);

    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, roles.List, .{}));
    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, roles.Create, .{
        .name = "boss",
        .label = "Boss",
        .grants = &.{"*"},
    }));
    try std.testing.expectError(error.Failed, SDK.dispatch(&admin, roles.Update, .{
        .name = role.admin,
        .label = "Admin",
        .grants = &.{},
    }));
    try std.testing.expectError(error.Failed, SDK.dispatch(&admin, roles.Remove, .{
        .name = role.admin,
    }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&admin, roles.Get, .{
        .name = "nobody",
    }));
}

test "a site role: copied, given, changed, and its holders call what it grants" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
        },
    });

    const made = (try SDK.dispatch(&admin, roles.Create, .{
        .name = "reviewer",
        .label = "Reviewer",
        .copy = role.contributor,
        .grants = &.{"user.list"},
    })).role;

    try std.testing.expectEqualStrings("", made.owner);
    try std.testing.expect(!made.changed);

    const reviewer = [_][]const u8{"reviewer"};
    var holder = harness.ctx(.{
        .user = .{
            .id = "u_reviewer",
            .roles = &reviewer,
        },
    });

    try std.testing.expect(SDK.may(&holder, user.List));
    try std.testing.expect(!SDK.may(&holder, roles.List));

    _ = try SDK.dispatch(&admin, roles.Update, .{
        .name = "reviewer",
        .label = "Reviewer",
        .grants = &.{"record.get"},
    });
    try std.testing.expect(!SDK.may(&holder, user.List));

    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, roles.Create, .{
        .name = "reviewer",
        .label = "Again",
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, roles.Create, .{
        .name = "Bad",
        .label = "Bad",
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, roles.Update, .{
        .name = "reviewer",
        .label = "Reviewer",
        .grants = &.{"record."},
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, roles.Reset, .{
        .name = "reviewer",
    }));
}

test "a declared role changed shows it, and reset puts back what code declares" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
        },
    });

    const changed = (try SDK.dispatch(&admin, roles.Update, .{
        .name = role.editor,
        .label = "Writer",
        .grants = &.{"record.get"},
    })).role;

    try std.testing.expect(changed.changed);
    try std.testing.expectEqualStrings("Writer", changed.label);

    const reset = (try SDK.dispatch(&admin, roles.Reset, .{
        .name = role.editor,
    })).role;

    try std.testing.expect(!reset.changed);
    try std.testing.expectEqualStrings("Writer", reset.label);
}

test "removing: never someone's only role; holders lose it; the trash brings it back" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
        },
    });

    try sdk.stored_roles.declare(&admin, "courses", &.{.{
        .name = "teacher",
        .label = "Teacher",
    }});
    try store.role_grants.add(admin.db, "teacher", &.{"courses.*"});

    const created = try SDK.dispatch(&admin, user.Create, .{
        .email = "tea@example.com",
        .display_name = "Tea",
        .roles = &.{"teacher"},
        .password = "correct horse battery",
    });

    try std.testing.expectError(error.Failed, SDK.dispatch(&admin, roles.Remove, .{
        .name = "teacher",
    }));

    try store.user_roles.set(admin.db, created.user_id, &.{ "teacher", role.editor });

    const removed = try SDK.dispatch(&admin, roles.Remove, .{
        .name = "teacher",
    });

    try std.testing.expect(!try sdk.stored_roles.exists(&admin, "teacher"));

    const left = try store.user_roles.of(admin.db, admin.arena, created.user_id);

    try std.testing.expectEqual(@as(usize, 1), left.len);

    try sdk.stored_roles.declare(&admin, "courses", &.{.{
        .name = "teacher",
        .label = "Teacher",
    }});
    try std.testing.expect(!try sdk.stored_roles.exists(&admin, "teacher"));

    _ = try SDK.dispatch(&admin, trash.Restore, .{
        .id = removed.trash,
    });

    const back = (try SDK.dispatch(&admin, roles.Get, .{
        .name = "teacher",
    })).role;

    try std.testing.expectEqual(@as(u32, 1), back.holders);
    try std.testing.expectEqualStrings("courses.*", back.grants[0]);
}
