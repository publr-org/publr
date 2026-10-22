//! What an app reaches: the types living in it or shared with it, and of a plugin's only
//! those of the plugins it lists; and why a record is out of a reader's reach.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Reason = enum { access, not_shared, deleted };

pub const Reach = struct {
    pub const name = "record.reach";
    pub const description = "Say why a record is out of the caller's reach, or that it is not";
    pub const details =
        \\What a page shows in place of a reference it may not follow. `reason` is
        \\`access` (the caller may not read it: a Private type, or one its roles do not
        \\reach), `not_shared` (its type is not shared with the app the call is for) or
        \\`deleted` (in the trash, or gone for good); null when the caller reads it, or
        \\when it is not published yet for a caller who reads live records only. `type`
        \\is its type's handle, empty when the record is gone. Nothing else of the record
        \\is said. Anyone may ask.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        reason: ?Reason,
        type: []const u8,
    };
    pub const example: In = .{
        .id = "a1b2c3d4e5f60718293a4b5c",
    };
    pub const example_out: Out = .{
        .reason = null,
        .type = "post",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id a reference holds",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .reason = "`access`, `not_shared` or `deleted`; null when nothing stands in the way",
        .type = "The record's type, by handle; empty when it is gone",
    };

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
    const found = row orelse return gone;
    const type_row = store.content_types.get_by_id(ctx.db, ctx.arena, found.type_id) catch {
        return error.Failed;
    };
    const def = (type_row orelse return gone).def;

    return .{
        .reason = try reason_of(ctx, granted, def, found),
        .type = def.handle,
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
            .definition = try model.content_type.encode(system.arena, def),
        });
    }

    const document = "{\"title\":\"Item\"}";
    const kept = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "supplier",
        .document = document,
    });

    for ([_][]const u8{ "post", "stock" }) |handle| {
        _ = try SDK.dispatch(&system, record_operations.Create, .{
            .type = handle,
            .document = document,
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
        .document = document,
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
        .definition = try model.content_type.encode(system.arena, order),
    });

    const document = "{\"title\":\"Mine\"}";
    const bought = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "order",
        .document = document,
    });
    _ = try SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = document,
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
            .definition = try model.content_type.encode(system.arena, def),
        });
    }

    const document = "{\"title\":\"Item\"}";
    var ids: [5][]const u8 = undefined;

    for ([_][]const u8{ "stock", "supplier", "assessment", "post" }, 0..) |handle, index| {
        ids[index] = (try SDK.dispatch(&system, record_operations.Create, .{
            .type = handle,
            .document = document,
        })).id;
        _ = try SDK.dispatch(&system, record_operations.Publish, .{
            .id = ids[index],
        });
    }

    ids[4] = (try SDK.dispatch(&system, record_operations.Create, .{
        .type = "post",
        .document = document,
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
