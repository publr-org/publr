//! What an app reaches: the types living in it or shared with it, and of a plugin's only
//! those of the plugins it lists; and why a record is out of a reader's reach.

const std = @import("std");
const public = @import("../../publr/operations/record/reach.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Reason = public.Reason;

pub const Reach = struct {
    pub const shape = public.Reach;
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

        if (in.id.len == 0 or in.id.len > model.validate.id_len_max) {
            return error.Invalid;
        }

        return explain(ctx, granted, in.id);
    }
};

/// `record.reach` for a read already under way (a query following a reference).
pub fn explain(ctx: *Ctx, granted: *const Grant, id: []const u8) Error!Reach.Out {
    std.debug.assert(granted.allows());
    std.debug.assert(id.len > 0);

    const gone: Reach.Out = .{
        .reason = .deleted,
        .type = "",
    };
    const row = store.records.get(ctx.db, ctx.arena, id) catch return error.Failed;
    const found = row orelse return internal_reach(ctx, id);
    const type_row = store.content_types.get_by_id(ctx.db, ctx.arena, found.type_id) catch {
        return error.Failed;
    };
    const def = (type_row orelse return gone).def;

    return .{
        .reason = try reason_of(ctx, granted, def, found),
        .type = def.handle,
    };
}

/// A plugin's internal record a reference names: that it is there and its type
/// (`shipping.slot`), for whoever holds the reference; what it holds is read through
/// `internal.*`, as its plugin's grant allows. Gone when there is none.
fn internal_reach(ctx: *Ctx, id: []const u8) Error!Reach.Out {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const owner = try store.internal_records.owner_of(ctx.db, ctx.arena, id) orelse return .{
        .reason = .deleted,
        .type = "",
    };

    return .{
        .reason = null,
        .type = try std.mem.concat(ctx.arena, u8, &.{ owner.plugin, ".", owner.kind }),
        .internal = true,
    };
}

/// What stands in place of a record the reader may not follow a reference to.
pub fn payload(arena: std.mem.Allocator, out: Reach.Out) error{OutOfMemory}!std.json.Value {
    std.debug.assert(out.reason != null);
    std.debug.assert(out.type.len <= 64);

    var object: std.json.ObjectMap = .empty;

    try object.put(arena, "restricted", .{
        .bool = true,
    });
    try object.put(arena, "type", .{
        .string = out.type,
    });
    try object.put(arena, "reason", .{
        .string = @tagName(out.reason.?),
    });

    return .{
        .object = object,
    };
}

fn reason_of(
    ctx: *Ctx,
    granted: *const Grant,
    def: model.content_type.Def,
    found: record_operations.Record,
) Error!?Reason {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(found.id.len > 0);

    if (std.mem.eql(u8, found.status, "trashed")) {
        return .deleted;
    }

    if (!granted.allows_placement(def.app, model.content_type.shared_of(def))) {
        return .not_shared;
    }

    if (!@import("../content_type.zig").visible(granted, def)) {
        return .access;
    }

    if (try record_operations.access.load(ctx, found.id, granted) != null) {
        return null;
    }

    const live_only = granted.live_only_on(def.handle, def.public) or ctx.delivery;

    if (live_only and !try @import("../status.zig").is_live(ctx, found.status)) {
        return null;
    }

    return .access;
}

const SDK = registry.SDK;

test "an app reaches its own types, the ones shared with it and Global ones" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var stock = model.content_type.test_post;
    stock.handle = "stock";
    stock.name = "Stock";
    stock.app = "warehouse";
    stock.shared = .{
        .apps = &.{"www"},
    };
    var supplier = stock;
    supplier.handle = "supplier";
    supplier.name = "Supplier";
    supplier.shared = null;
    const types = @import("../content_type.zig");

    for ([_]model.content_type.Def{ stock, supplier }) |def| {
        _ = try SDK.dispatch(&system, types.Create, .{
            .definition = def,
        });
    }

    const document = "{\"title\":\"Item\"}";
    const kept = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "supplier",
        .document = .{
            .text = document,
        },
    });

    for ([_][]const u8{ "post", "stock" }) |handle| {
        _ = try SDK.dispatch(&system, record_operations.Create, .{
            .type = handle,
            .document = .{
                .text = document,
            },
        });
    }

    var site = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    site.app_reach = "www";
    const listed = try SDK.dispatch(&site, record_operations.List, .{});
    try std.testing.expectEqual(2, listed.records.len);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&site, record_operations.Get, .{
        .id = kept.id,
    }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&site, record_operations.Create, .{
        .type = "supplier",
        .document = .{
            .text = document,
        },
    }));

    for ((try SDK.dispatch(&site, types.List, .{})).types) |summary| {
        try std.testing.expect(!std.mem.eql(u8, summary.handle, "supplier"));
    }

    var warehouse = site;
    warehouse.app_reach = "warehouse";
    const own = try SDK.dispatch(&warehouse, record_operations.List, .{});
    try std.testing.expectEqual(3, own.records.len);

    var portal = site;
    portal.app_reach = "portal";
    const seen = try SDK.dispatch(&portal, record_operations.List, .{});
    try std.testing.expectEqual(1, seen.records.len);
    try std.testing.expectEqualStrings("post", seen.records[0].type);
}

test "an app's plugins: a type another plugin owns is out of reach, the project's own never" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var order = model.content_type.test_post;
    order.handle = "order";
    order.name = "Order";
    order.system = true;
    order.owner = "shop";
    const types = @import("../content_type.zig");
    _ = try SDK.dispatch(&system, types.Create, .{
        .definition = order,
    });

    const document = "{\"title\":\"Mine\"}";
    const bought = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "order",
        .document = .{
            .text = document,
        },
    });
    _ = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = .{
            .text = document,
        },
    });

    var site = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    site.app_plugins = &.{"newsletter"};
    const listed = try SDK.dispatch(&site, record_operations.List, .{});
    try std.testing.expectEqual(1, listed.records.len);
    try std.testing.expectEqualStrings("post", listed.records[0].type);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&site, record_operations.Get, .{
        .id = bought.id,
    }));

    for ((try SDK.dispatch(&site, types.List, .{})).types) |summary| {
        try std.testing.expect(!std.mem.eql(u8, summary.handle, "order"));
    }

    var shop = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    shop.app_plugins = &.{"shop"};
    const everything = try SDK.dispatch(&shop, record_operations.List, .{});
    try std.testing.expectEqual(2, everything.records.len);
    _ = try SDK.dispatch(&shop, record_operations.Get, .{
        .id = bought.id,
    });
}

test "reach: why a reference stands restricted, and when nothing stands in the way" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var stock = model.content_type.test_post;
    stock.handle = "stock";
    stock.name = "Stock";
    stock.app = "warehouse";
    stock.shared = .{
        .apps = &.{"www"},
    };
    var supplier = stock;
    supplier.handle = "supplier";
    supplier.name = "Supplier";
    supplier.shared = null;
    var assessment = model.content_type.test_post;
    assessment.handle = "assessment";
    assessment.name = "Assessment";
    assessment.public = false;
    const types = @import("../content_type.zig");

    for ([_]model.content_type.Def{ stock, supplier, assessment }) |def| {
        _ = try SDK.dispatch(&system, types.Create, .{
            .definition = def,
        });
    }

    const document = "{\"title\":\"Item\"}";
    var ids: [5][]const u8 = undefined;

    for ([_][]const u8{ "stock", "supplier", "assessment", "post" }, 0..) |handle, index| {
        ids[index] = (try SDK.dispatch(&system, record_operations.Create, .{
            .type = handle,
            .document = .{
                .text = document,
            },
        })).id;
        _ = try SDK.dispatch(&system, record_operations.Publish, .{
            .id = ids[index],
        });
    }

    ids[4] = (try SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = .{
            .text = document,
        },
    })).id;
    _ = try SDK.dispatch(&system, record_operations.Delete, .{
        .id = ids[3],
    });

    var visitor = harness.ctx(.anonymous);
    visitor.app_reach = "www";
    visitor.delivery = true;
    const expected = [_]struct {
        reason: ?Reason,
        type: []const u8,
    }{
        .{
            .reason = null,
            .type = "stock",
        },
        .{
            .reason = .not_shared,
            .type = "supplier",
        },
        .{
            .reason = .access,
            .type = "assessment",
        },
        .{
            .reason = .deleted,
            .type = "post",
        },
        .{
            .reason = null,
            .type = "post",
        },
    };

    for (ids, expected) |id, want| {
        const got = try SDK.dispatch(&visitor, Reach, .{
            .id = id,
        });
        try std.testing.expectEqual(want.reason, got.reason);
        try std.testing.expectEqualStrings(want.type, got.type);
    }

    const gone = try SDK.dispatch(&visitor, Reach, .{
        .id = "a1b2c3d4e5f60718293a4b5c",
    });
    try std.testing.expectEqual(Reason.deleted, gone.reason.?);
    try std.testing.expectEqualStrings("", gone.type);

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    editor.app_reach = "www";
    const signed_in = try SDK.dispatch(&editor, Reach, .{
        .id = ids[2],
    });
    try std.testing.expect(signed_in.reason == null);
}

test "reach: another plugin's internal record a reference names is there, with its type" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const slots: store.internal_records.Scope = .{
        .plugin = "shipping",
        .app = "",
        .kind = "slot",
    };

    try store.internal_records.insert_as(ctx.db, slots, "slot0000000000000000001", "{}", 1);

    const found = try explain(&ctx, &Grant.allow_all, "slot0000000000000000001");
    const missing = try explain(&ctx, &Grant.allow_all, "slot0000000000000000002");

    try std.testing.expect(found.reason == null);
    try std.testing.expectEqualStrings("shipping.slot", found.type);
    try std.testing.expect(found.internal);
    try std.testing.expectEqual(Reason.deleted, missing.reason.?);
}
