//! An app's types handed on, when the app is renamed.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/project/move_app.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Def = model.content_type.Def;

pub const MoveApp = struct {
    pub const shape = public.MoveApp;
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
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(granted.allows());

        if (!model.app.valid_name(in.from)) {
            return error.Invalid;
        }

        if (in.to.len > 0 and !model.app.valid_name(in.to)) {
            return error.Invalid;
        }

        const types = try move_in(store.content_types, ctx, in.from, in.to);
        const taxonomies = try move_in(store.taxonomies, ctx, in.from, in.to);
        const design_to: ?[]const u8 = if (in.to.len == 0) null else in.to;

        _ = store.records.move_app(ctx.db, in.from, design_to) catch return error.Failed;

        return .{
            .moved = types + taxonomies,
        };
    }
};

fn move_in(comptime table: type, ctx: *Ctx, from: []const u8, to: []const u8) Error!u32 {
    std.debug.assert(from.len > 0);
    std.debug.assert(to.len == 0 or model.app.valid_name(to));

    const rows = table.list(ctx.db, ctx.arena) catch return error.Failed;
    var moved: u32 = 0;

    for (rows) |row| {
        const renamed = try renamed_def(ctx.arena, row.def, from, to) orelse continue;

        _ = table.update(ctx.db, ctx.arena, row.id, renamed, ctx.now_ms) catch {
            return error.Failed;
        };
        moved += 1;
    }

    return moved;
}

/// The definition with `from` renamed to `to` where it lives and in who it is shared with;
/// null when it names `from` nowhere.
fn renamed_def(arena: std.mem.Allocator, def: Def, from: []const u8, to: []const u8) Error!?Def {
    std.debug.assert(from.len > 0);
    std.debug.assert(def.handle.len > 0);

    var out = def;
    var changed = false;

    if (std.mem.eql(u8, def.app, from)) {
        out.app = to;
        changed = true;
    }

    const shared = def.shared orelse return if (changed) out else null;
    var apps: std.ArrayList([]const u8) = .empty;

    for (shared.apps) |name| {
        if (!std.mem.eql(u8, name, from)) {
            try apps.append(arena, name);
        } else if (to.len > 0 and !std.mem.eql(u8, to, out.app)) {
            try apps.append(arena, to);
            changed = true;
        } else {
            changed = true;
        }
    }

    out.shared = .{
        .all = shared.all,
        .apps = apps.items,
    };

    return if (changed) out else null;
}

const SDK = registry.SDK;

test "move_app hands an app's types to another, or makes them Global; admins only" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var stock = model.content_type.test_post;
    stock.handle = "stock";
    stock.name = "Stock";
    stock.app = "warehouse";
    var page = stock;
    page.handle = "page";
    page.name = "Page";
    page.app = "www";
    page.shared = .{
        .apps = &.{"warehouse"},
    };
    const types = @import("../content_type.zig");

    for ([_]Def{ stock, page }) |def| {
        _ = try SDK.dispatch(&system, types.Create, .{
            .definition = .{
                .text = try model.content_type.encode(system.arena, def),
            },
        });
    }

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_ad",
            .roles = &.{"admin"},
        },
    });

    try std.testing.expectError(error.Denied, SDK.dispatch(&editor, MoveApp, .{
        .from = "warehouse",
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&admin, MoveApp, .{
        .from = "",
    }));

    const moved = try SDK.dispatch(&admin, MoveApp, .{
        .from = "warehouse",
        .to = "stockroom",
    });
    try std.testing.expectEqual(2, moved.moved);

    const got_stock = try types.got(&admin, .{
        .type = "stock",
    });
    try std.testing.expectEqualStrings("stockroom", got_stock.definition.app);
    const got_page = try types.got(&admin, .{
        .type = "page",
    });
    try std.testing.expectEqualStrings("stockroom", got_page.definition.shared.?.apps[0]);

    try std.testing.expectEqual(2, (try SDK.dispatch(&admin, MoveApp, .{
        .from = "stockroom",
    })).moved);
    const global = try types.got(&admin, .{
        .type = "stock",
    });
    try std.testing.expectEqualStrings("", global.definition.app);
    const unshared = try types.got(&admin, .{
        .type = "page",
    });
    try std.testing.expectEqual(0, unshared.definition.shared.?.apps.len);
}
