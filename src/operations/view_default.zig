const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/view/default.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const view_operations = @import("view.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const data_view = model.data_view;
const defaults = store.default_views;

pub const Named = public.Named;
pub const Operator = public.Operator;
pub const Filterable = public.Filterable;

pub const Default = struct {
    pub const shape = public.Default;
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

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const row = try type_of(ctx, in.type);
        const everyone = try stored(ctx, null, row.id);
        const resolved = data_view.resolve(ctx.arena, registry.kinds(ctx), .{
            .handle = row.def.handle,
            .fields = try readable(ctx, row.def.fields),
            .plugin = row.def.view,
            .everyone = everyone,
            .mine = try stored(ctx, owner, row.id),
        }) catch return error.OutOfMemory;

        return .{
            .query = .{
                .text = model.view.encode(ctx.arena, resolved.start) catch return error.Invalid,
            },
            .layer = @tagName(resolved.layer),
            .everyone = everyone != null,
            .title_field = row.def.title_field,
            .columns = first_page(Named, try plugin_columns(ctx, row.def.handle, try columns_of(
                ctx,
                row.def,
                resolved.columns,
            ))),
            .filterable = first_page(Filterable, try filterable_of(ctx, resolved.filterable)),
            .orderable = first_page(Named, try columns_of(ctx, row.def, resolved.orderable)),
        };
    }
};

/// What the view options offer, at most a page of each: a type's fields with core's
/// columns may come to a few more.
fn first_page(comptime Item: type, items: []const Item) []const Item {
    const end = @min(items.len, sdk.operation.page_limit_max);

    std.debug.assert(end <= items.len);

    return items[0..end];
}

pub const SaveDefault = struct {
    pub const shape = public.SaveDefault;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const owner = ctx.caller.user_id() orelse return error.Denied;

        if (in.for_everyone and !ctx.caller.holds("admin")) {
            return error.Denied;
        }

        const row = try type_of(ctx, in.type);
        const checked = try view_operations.check_query(ctx, in.query.text);
        var filters = model.view.decode(ctx.arena, checked) catch return error.Invalid;

        filters.types = &.{};
        filters.type_view = false;

        const query = model.view.encode(ctx.arena, filters) catch return error.Invalid;

        const scope: ?[]const u8 = if (in.for_everyone) null else owner;
        try defaults.put(ctx.db, scope, row.id, query, owner, ctx.now_ms);

        return .{
            .saved = true,
        };
    }
};

pub const ResetDefault = struct {
    pub const shape = public.ResetDefault;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const owner = ctx.caller.user_id() orelse return error.Denied;

        if (in.for_everyone and !ctx.caller.holds("admin")) {
            return error.Denied;
        }

        const row = try type_of(ctx, in.type);
        const reset = try defaults.remove(ctx.db, if (in.for_everyone) null else owner, row.id);

        return .{
            .reset = reset,
        };
    }
};

pub const operations = [_]type{ Default, SaveDefault, ResetDefault };

fn type_of(ctx: *Ctx, handle: []const u8) Error!store.content_types.Row {
    std.debug.assert(ctx.now_ms >= 0);

    if (handle.len == 0 or handle.len > model.filter.key_len_max) {
        return error.Invalid;
    }

    return try store.content_types.get_by_handle(ctx.db, ctx.arena, handle) orelse {
        return error.NotFound;
    };
}

/// A saved default as a view; one that no longer reads (a shape since changed) is none.
fn stored(ctx: *Ctx, user_id: ?[]const u8, type_id: []const u8) Error!?model.view.Filters {
    std.debug.assert(type_id.len > 0);

    const saved = try defaults.get(ctx.db, ctx.arena, user_id, type_id) orelse return null;

    return model.view.decode(ctx.arena, saved.query) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => null,
    };
}

const core_labels = [_][2][]const u8{
    .{ "title", "Title" },
    .{ "slug", "Slug" },
    .{ "status", "Status" },
    .{ "updated", "Updated" },
    .{ "created", "Created" },
};

/// The columns plugins add to the type's list (`.register_columns`), after the type's own.
fn plugin_columns(ctx: *Ctx, handle: []const u8, own: []const Named) Error![]const Named {
    std.debug.assert(handle.len > 0);

    var columns: std.ArrayList(Named) = .empty;

    columns.appendSlice(ctx.arena, own) catch return error.OutOfMemory;

    for (try registry.all_columns(ctx)) |column| {
        if (column.on(handle)) {
            columns.append(ctx.arena, .{
                .name = column.field,
                .label = column.label,
            }) catch return error.OutOfMemory;
        }
    }

    return columns.items;
}

/// Names with their labels: a field's own, or core's column's.
fn columns_of(
    ctx: *Ctx,
    def: model.content_type.Def,
    names: []const []const u8,
) Error![]const Named {
    std.debug.assert(names.len <= model.view.columns_max + model.view.core_orders.len);

    const out = ctx.arena.alloc(Named, names.len) catch return error.OutOfMemory;

    for (names, out) |name, *named| {
        named.* = .{
            .name = name,
            .label = label_of(def, name),
        };
    }

    return out;
}

/// The fields the caller may read (`.visibility`): the only ones a list shows, filters or
/// orders by.
fn readable(ctx: *Ctx, fields: []const model.field.Def) Error![]const model.field.Def {
    std.debug.assert(fields.len <= model.field.fields_max);

    const visibility = @import("document/visibility.zig");

    if (!visibility.any_hidden(fields)) {
        return fields;
    }

    var kept: std.ArrayList(model.field.Def) = .empty;

    for (fields) |field| {
        if (!field.visibility.hidden() or visibility.sees(ctx, field.visibility)) {
            kept.append(ctx.arena, field) catch return error.OutOfMemory;
        }
    }

    std.debug.assert(kept.items.len <= fields.len);

    return kept.items;
}

fn label_of(def: model.content_type.Def, name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    for (def.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field.label;
        }
    }

    for (core_labels) |core| {
        if (std.mem.eql(u8, core[0], name)) {
            return core[1];
        }
    }

    return name;
}

fn filterable_of(ctx: *Ctx, fields: []const data_view.Filterable) Error![]const Filterable {
    std.debug.assert(fields.len <= model.field.fields_max);

    const out = ctx.arena.alloc(Filterable, fields.len) catch return error.OutOfMemory;

    for (fields, out) |field, *offered| {
        const operators = model.field_filter.operators_of(field.family, field.many);
        const listed = ctx.arena.alloc(Operator, operators.len) catch return error.OutOfMemory;

        for (operators, listed) |operator, *one| {
            one.* = .{
                .id = operator.id,
                .label = operator.label,
                .takes = @tagName(operator.takes),
            };
        }

        offered.* = .{
            .name = field.name,
            .label = field.label,
            .operators = listed,
        };
    }

    return out;
}

const SDK = registry.SDK;

test "a type's default view: core's, everyone's, the caller's own; reset goes a layer down" {
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
    const users = @import("user.zig");
    const types = @import("content_type.zig");
    const root_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "root@example.com",
        .display_name = "Root",
        .roles = &.{"editor"},
    });
    const ada_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .roles = &.{"editor"},
    });
    var root = harness.ctx(.{
        .user = .{
            .id = root_account.user_id,
            .roles = &.{"admin"},
        },
    });
    var ada = harness.ctx(.{
        .user = .{
            .id = ada_account.user_id,
            .roles = &.{"editor"},
        },
    });

    _ = try SDK.dispatch(&admin, types.Create, .{
        .definition = .{
            .text = try model.content_type.encode(
                harness.fixed.allocator(),
                model.content_type.test_post,
            ),
        },
    });

    const fresh = try SDK.dispatch(&ada, Default, .{
        .type = "post",
    });
    try std.testing.expectEqualStrings("core", fresh.layer);
    try std.testing.expect(std.mem.indexOf(u8, fresh.query.text, "\"-updated\"") != null);
    try std.testing.expectEqualStrings("Views", fresh.filterable[2].label);
    try std.testing.expectEqualStrings("more", fresh.filterable[2].operators[3].id);

    const everyone_in: SaveDefault.In = .{
        .type = "post",
        .query = .{
            .text = "{\"order\":\"title\"}",
        },
        .for_everyone = true,
    };
    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, SaveDefault, everyone_in));
    _ = try SDK.dispatch(&root, SaveDefault, everyone_in);
    _ = try SDK.dispatch(&ada, SaveDefault, .{
        .type = "post",
        .query = .{
            .text = "{\"order\":\"-views\",\"per_page\":50}",
        },
    });

    const mine = try SDK.dispatch(&ada, Default, .{
        .type = "post",
    });
    try std.testing.expectEqualStrings("mine", mine.layer);
    try std.testing.expect(mine.everyone);
    try std.testing.expect(std.mem.indexOf(u8, mine.query.text, "\"-views\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mine.query.text, "\"type_view\":true") != null);
    try std.testing.expectEqualStrings("everyone", (try SDK.dispatch(&root, Default, .{
        .type = "post",
    })).layer);

    try std.testing.expect((try SDK.dispatch(&ada, ResetDefault, .{
        .type = "post",
    })).reset);
    try std.testing.expectEqualStrings("everyone", (try SDK.dispatch(&ada, Default, .{
        .type = "post",
    })).layer);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&ada, Default, .{
        .type = "nope",
    }));
}
