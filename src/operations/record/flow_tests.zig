const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const record = @import("../record.zig");
const types = @import("../content_type.zig");

const SDK = registry.SDK;

/// Entries wait for review; only a reviewer (or an administrator) publishes them.
const reviewed_type: model.content_type.Def = .{
    .handle = "guestbook.entry",
    .name = "Entry",
    .fields = &.{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
    }},
    .flow = .{
        .statuses = &.{.{
            .id = "guestbook.in_review",
            .label = "Waiting for review",
        }},
        .transitions = &.{
            .{
                .name = "submit",
                .from = &.{"draft"},
                .to = "guestbook.in_review",
                .label = "Submit for review",
            },
            .{
                .name = "publish",
                .from = &.{"guestbook.in_review"},
                .to = "published",
                .label = "Publish",
                .authorize = .{
                    .answer = .roles,
                    .roles = &.{"reviewer"},
                },
            },
        },
        .start = "draft",
    },
};

test "a transition's authorize holds on every path that moves a record" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    _ = try SDK.dispatch(&system, types.Create, .{
        .definition = try model.content_type.encode(system.arena, reviewed_type),
    });

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const created = try SDK.dispatch(&editor, record.Create, .{
        .type = "guestbook.entry",
        .document = "{\"title\":\"Lovely\"}",
    });

    // Not where the transition starts: refused by name.
    const early = SDK.dispatch(&editor, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    try std.testing.expectError(error.Failed, early);

    const submitted = try SDK.dispatch(&editor, record.Transition, .{
        .id = created.id,
        .transition = "submit",
    });
    try std.testing.expectEqualStrings("guestbook.in_review", submitted.status);

    // The editor may write the record, but not make the reviewer's transition, by any path.
    const by_name = SDK.dispatch(&editor, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    try std.testing.expectError(error.Denied, by_name);
    const by_publish = SDK.dispatch(&editor, record.Publish, .{
        .id = created.id,
    });
    try std.testing.expectError(error.Denied, by_publish);
    const in_bulk = try SDK.dispatch(&editor, record.TransitionMany, .{
        .transition = "publish",
        .ids = &.{created.id},
    });
    try std.testing.expectEqual(@as(u32, 0), in_bulk.moved);
    try std.testing.expectEqual(@as(u32, 1), in_bulk.not_moved);

    const unknown = SDK.dispatch(&editor, record.Transition, .{
        .id = created.id,
        .transition = "approve",
    });
    try std.testing.expectError(error.Invalid, unknown);

    // An administrator passes every answer.
    const published = try SDK.dispatch(&admin, record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });
    try std.testing.expectEqualStrings("published", published.status);
}

test "the trash: restore goes back where the record was, destroy is a person's, reads skip it" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record.fixture.post_type(&system);

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const archived = try SDK.dispatch(&editor, record.Create, .{
        .type = "post",
        .document = "{\"title\":\"Kept\",\"body\":\"x\"}",
    });
    const live = try SDK.dispatch(&editor, record.Create, .{
        .type = "post",
        .document = "{\"title\":\"Live\",\"body\":\"x\"}",
    });

    _ = try SDK.dispatch(&editor, record.Transition, .{
        .id = archived.id,
        .transition = "archive",
    });
    _ = try SDK.dispatch(&editor, record.Transition, .{
        .id = live.id,
        .transition = "publish",
    });

    for ([_][]const u8{ archived.id, live.id }) |id| {
        const trashed = try SDK.dispatch(&editor, record.Transition, .{
            .id = id,
            .transition = "trash",
        });

        try std.testing.expectEqualStrings("trashed", trashed.status);
    }

    // Queries leave the trash out unless asked.
    const counted = try SDK.dispatch(&editor, record.Query, .{
        .query = "count(*[_type == \"post\"])",
    });
    try std.testing.expectEqualStrings("0", counted.result.text);
    const with_trash = try SDK.dispatch(&editor, record.Query, .{
        .query = "count(*[_type == \"post\"])",
        .trashed = true,
    });
    try std.testing.expectEqualStrings("2", with_trash.result.text);

    // Back to the status it had; a live one back where records start.
    const back = try SDK.dispatch(&editor, record.Transition, .{
        .id = archived.id,
        .transition = "restore",
    });
    try std.testing.expectEqualStrings("archived", back.status);
    const unpublished = try SDK.dispatch(&editor, record.Transition, .{
        .id = live.id,
        .transition = "restore",
    });
    try std.testing.expectEqualStrings("draft", unpublished.status);

    // Many at once by the same rule: each back to the status it had.
    _ = try SDK.dispatch(&editor, record.Transition, .{
        .id = archived.id,
        .transition = "trash",
    });
    const restored = try SDK.dispatch(&editor, record.TransitionMany, .{
        .transition = "restore",
        .ids = &.{ archived.id, live.id },
    });
    try std.testing.expectEqual(@as(u32, 1), restored.moved);
    try std.testing.expectEqual(@as(u32, 1), restored.not_moved);
    const read_back = try SDK.dispatch(&editor, record.Get, .{
        .id = archived.id,
    });
    try std.testing.expectEqualStrings("archived", read_back.record.status);

    // Destroy leaves only the trash, and only for a person who may: anyone else waits.
    const not_trashed = SDK.dispatch(&admin, record.Transition, .{
        .id = live.id,
        .transition = "destroy",
    });
    try std.testing.expectError(error.Failed, not_trashed);
    _ = try SDK.dispatch(&editor, record.Transition, .{
        .id = live.id,
        .transition = "trash",
    });
    const waiting = try SDK.dispatch(&editor, record.Transition, .{
        .id = live.id,
        .transition = "destroy",
    });
    try std.testing.expect(waiting.pending);
    try std.testing.expectEqualStrings("trashed", waiting.status);
    const destroyed = try SDK.dispatch(&admin, record.Transition, .{
        .id = live.id,
        .transition = "destroy",
    });
    try std.testing.expect(!destroyed.pending);
    const gone = SDK.dispatch(&admin, record.Get, .{
        .id = live.id,
    });
    try std.testing.expectError(error.NotFound, gone);
}

const order_type: model.content_type.Def = .{
    .handle = "orders.order",
    .name = "Order",
    .fields = &.{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
    }},
    .flow = .{
        .statuses = &.{.{
            .id = "orders.paid",
            .label = "Paid",
            .live = true,
        }},
        .transitions = &.{.{
            .name = "pay",
            .from = &.{"draft"},
            .to = "orders.paid",
            .label = "Mark paid",
        }},
        .start = "draft",
    },
};

const sale_type: model.content_type.Def = .{
    .handle = "shop.sale",
    .name = "Sale",
    .fields = &.{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
    }},
    .flow = .{
        .statuses = &.{.{
            .id = "shop.settled",
            .label = "Settled",
            .alias = "orders.paid",
        }},
        .transitions = &.{.{
            .name = "settle",
            .from = &.{"draft"},
            .to = "shop.settled",
            .label = "Settle",
        }},
        .start = "draft",
    },
};

test "a status standing in for another plugin's takes its meaning and is found by its name" {
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

    // Without orders, the sale's own meaning: settled is not shown on the site.
    _ = try SDK.dispatch(&system, types.Create, .{
        .definition = try model.content_type.encode(system.arena, sale_type),
    });

    const alone = (try record.domain.definition.find(&admin, "shop.sale")).?;

    try std.testing.expect(!alone.def.flow.is_live("shop.settled"));

    _ = try SDK.dispatch(&system, types.Create, .{
        .definition = try model.content_type.encode(system.arena, order_type),
    });

    const sale = try SDK.dispatch(&admin, record.Create, .{
        .type = "shop.sale",
        .document = "{\"title\":\"Tea\"}",
    });
    const settled = try SDK.dispatch(&admin, record.Transition, .{
        .id = sale.id,
        .transition = "settle",
    });

    try std.testing.expectEqualStrings("shop.settled", settled.status);

    // With orders present: Paid's meaning, and found by anything asking for orders' status.
    const joined = (try record.domain.definition.find(&admin, "shop.sale")).?;

    try std.testing.expect(joined.def.flow.is_live("shop.settled"));
    try std.testing.expectEqualStrings("Paid", joined.def.flow.find("shop.settled").?.label);

    const asked = try SDK.dispatch(&admin, record.List, .{
        .type = "shop.sale",
        .filters = &.{"status:is:orders.paid"},
    });

    try std.testing.expectEqual(@as(usize, 1), asked.records.len);
}

test "a Private type with roles ticked: those roles and administrators reach it, no other" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var ledger = order_type;
    ledger.handle = "orders.ledger";
    ledger.roles = &.{"editor"};

    _ = try SDK.dispatch(&system, types.Create, .{
        .definition = try model.content_type.encode(system.arena, ledger),
    });

    const made = try SDK.dispatch(&system, record.Create, .{
        .type = "orders.ledger",
        .document = "{\"title\":\"#1001\"}",
    });
    var contributor = harness.ctx(.{
        .user = .{
            .id = "u_contributor",
            .roles = &.{"contributor"},
        },
    });

    try std.testing.expectError(error.NotFound, SDK.dispatch(&contributor, record.Get, .{
        .id = made.id,
    }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&contributor, record.List, .{
        .type = "orders.ledger",
    }));

    const listed = try SDK.dispatch(&contributor, types.List, .{});

    for (listed.types) |summary| {
        try std.testing.expect(!std.mem.eql(u8, summary.handle, "orders.ledger"));
    }

    for ([_][]const u8{ "editor", "admin" }) |role_name| {
        var reader = harness.ctx(.{
            .user = .{
                .id = "u_reader",
                .roles = &.{role_name},
            },
        });
        const got = try SDK.dispatch(&reader, record.Get, .{
            .id = made.id,
        });

        try std.testing.expectEqualStrings(made.id, got.record.id);
    }
}
