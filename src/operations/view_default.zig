//! A type's default view: the view its list starts at, from its plugin's `.data_view`, the
//! one administrators saved for everyone and the person's own (`model.data_view`).

const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const view_operations = @import("view.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const data_view = model.data_view;
const defaults = store.default_views;

pub const Named = struct {
    name: []const u8,
    label: []const u8,
};

pub const Operator = struct {
    id: []const u8,
    label: []const u8,
    /// What the value is: `text`, `choices`, `yes_no`, `number`, `number_range`, `day`,
    /// `day_range`, `span`, `records`.
    takes: []const u8,
};

pub const Filterable = struct {
    name: []const u8,
    label: []const u8,
    operators: []const Operator,
};

const example_query = "{\"types\":[\"post\"],\"type_view\":true,\"clauses\":[]," ++
    "\"order\":\"-updated\",\"columns\":[\"slug\",\"status\",\"updated\"],\"per_page\":20}";

pub const Default = struct {
    pub const name = "view.default";
    pub const description = "Read the view a type's list starts at, and what it may offer";
    pub const details =
        \\`query` is the start, as JSON: the caller's own default if they saved one, else
        \\the one administrators saved for everyone, else the plugin's, else core's (newest
        \\saved first; slug, status and updated shown). `layer` says which. `columns`,
        \\`filterable` and `orderable` are what the view options offer, as the type's plugin
        \\narrows them; each field to filter by comes with its operators.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
    };
    pub const Out = struct {
        query: []const u8,
        layer: []const u8,
        /// Administrators saved a default for everyone.
        everyone: bool,
        /// The field the list's first column shows, always.
        title_field: []const u8,
        columns: []const Named,
        filterable: []const Filterable,
        orderable: []const Named,
    };
    pub const example: In = .{
        .type = "post",
    };
    pub const example_out: Out = .{
        .query = example_query,
        .layer = "core",
        .everyone = false,
        .title_field = "title",
        .columns = &.{
            .{
                .name = "title",
                .label = "Title",
            },
            .{
                .name = "slug",
                .label = "Slug",
            },
            .{
                .name = "body",
                .label = "Body",
            },
            .{
                .name = "related",
                .label = "Related",
            },
            .{
                .name = "status",
                .label = "Status",
            },
            .{
                .name = "updated",
                .label = "Updated",
            },
            .{
                .name = "created",
                .label = "Created",
            },
        },
        .filterable = &.{
            .{
                .name = "title",
                .label = "Title",
                .operators = &.{
                    .{
                        .id = "is",
                        .label = "is",
                        .takes = "text",
                    },
                    .{
                        .id = "is_not",
                        .label = "is not",
                        .takes = "text",
                    },
                    .{
                        .id = "contains",
                        .label = "contains",
                        .takes = "text",
                    },
                    .{
                        .id = "not_contains",
                        .label = "doesn't contain",
                        .takes = "text",
                    },
                    .{
                        .id = "starts_with",
                        .label = "starts with",
                        .takes = "text",
                    },
                },
            },
            .{
                .name = "slug",
                .label = "Slug",
                .operators = &.{
                    .{
                        .id = "is",
                        .label = "is",
                        .takes = "text",
                    },
                    .{
                        .id = "is_not",
                        .label = "is not",
                        .takes = "text",
                    },
                    .{
                        .id = "contains",
                        .label = "contains",
                        .takes = "text",
                    },
                    .{
                        .id = "not_contains",
                        .label = "doesn't contain",
                        .takes = "text",
                    },
                    .{
                        .id = "starts_with",
                        .label = "starts with",
                        .takes = "text",
                    },
                },
            },
            .{
                .name = "related",
                .label = "Related",
                .operators = &.{
                    .{
                        .id = "any_of",
                        .label = "is any of",
                        .takes = "records",
                    },
                    .{
                        .id = "none_of",
                        .label = "is none of",
                        .takes = "records",
                    },
                    .{
                        .id = "all_of",
                        .label = "is all of",
                        .takes = "records",
                    },
                },
            },
        },
        .orderable = &.{
            .{
                .name = "title",
                .label = "Title",
            },
            .{
                .name = "created",
                .label = "Created",
            },
            .{
                .name = "updated",
                .label = "Updated",
            },
            .{
                .name = "status",
                .label = "Status",
            },
        },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The content type, by handle",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .query = "The view the list starts at, as JSON",
        .layer = "Where it came from: `mine`, `everyone`, `plugin` or `core`",
        .everyone = "Whether administrators saved a default for everyone",
        .title_field = "The field the first column shows: the record's title",
        .columns = "Every column the list can show",
        .filterable = "The fields offered to filter by, each with its operators",
        .orderable = "What the list can be ordered by",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const row = try type_of(ctx, in.type);
        const everyone = try stored(ctx, null, row.id);
        const resolved = data_view.resolve(ctx.arena, registry.Kinds.all, .{
            .handle = row.def.handle,
            .fields = row.def.fields,
            .plugin = row.def.view,
            .everyone = everyone,
            .mine = try stored(ctx, owner, row.id),
        }) catch return error.OutOfMemory;

        return .{
            .query = model.view.encode(ctx.arena, resolved.start) catch return error.Invalid,
            .layer = @tagName(resolved.layer),
            .everyone = everyone != null,
            .title_field = row.def.title_field,
            .columns = try plugin_columns(ctx, row.def.handle, try columns_of(
                ctx,
                row.def,
                resolved.columns,
            )),
            .filterable = try filterable_of(ctx, resolved.filterable),
            .orderable = try columns_of(ctx, row.def, resolved.orderable),
        };
    }
};

pub const SaveDefault = struct {
    pub const name = "view.save_default";
    pub const description = "Save the view a type's list starts at, for the caller or everyone";
    pub const details =
        \\`query` is the view as JSON (as `view create` takes it); its types become the type's
        \\own view. Saved for the caller, it wins over everyone's; `for_everyone` saves the
        \\one everyone starts at who saved none: administrators only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        query: []const u8,
        for_everyone: bool = false,
    };
    pub const Out = struct {
        saved: bool,
    };
    pub const example: In = .{
        .type = "post",
        .query = "{\"order\":\"title\",\"per_page\":50}",
    };
    pub const example_out: Out = .{
        .saved = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The content type, by handle",
        .query = "The view, as JSON",
        .for_everyone = "Everyone's default (administrators only)",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const owner = ctx.caller.user_id() orelse return error.Denied;

        if (in.for_everyone and !ctx.caller.holds("admin")) {
            return error.Denied;
        }

        const row = try type_of(ctx, in.type);
        const checked = try view_operations.check_query(ctx, in.query);
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
    pub const name = "view.reset_default";
    pub const description = "Forget a saved default view: the caller's, or everyone's";
    pub const details =
        \\The caller's list starts at everyone's default again, or the plugin's. With
        \\`for_everyone` (administrators only), everyone's goes and the plugin's view is the
        \\start for those who saved none.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        for_everyone: bool = false,
    };
    pub const Out = struct {
        reset: bool,
    };
    pub const example: In = .{
        .type = "post",
    };
    // Nothing saved yet: nothing to forget.
    pub const example_out: Out = .{
        .reset = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The content type, by handle",
        .for_everyone = "Everyone's default (administrators only)",
    };

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
    });
    const ada_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
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
        .definition = try model.content_type.encode(
            harness.fixed.allocator(),
            model.content_type.test_post,
        ),
    });

    const fresh = try SDK.dispatch(&ada, Default, .{
        .type = "post",
    });
    try std.testing.expectEqualStrings("core", fresh.layer);
    try std.testing.expect(std.mem.indexOf(u8, fresh.query, "\"-updated\"") != null);
    try std.testing.expectEqualStrings("Views", fresh.filterable[2].label);
    try std.testing.expectEqualStrings("more", fresh.filterable[2].operators[3].id);

    const everyone_in: SaveDefault.In = .{
        .type = "post",
        .query = "{\"order\":\"title\"}",
        .for_everyone = true,
    };
    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, SaveDefault, everyone_in));
    _ = try SDK.dispatch(&root, SaveDefault, everyone_in);
    _ = try SDK.dispatch(&ada, SaveDefault, .{
        .type = "post",
        .query = "{\"order\":\"-views\",\"per_page\":50}",
    });

    const mine = try SDK.dispatch(&ada, Default, .{
        .type = "post",
    });
    try std.testing.expectEqualStrings("mine", mine.layer);
    try std.testing.expect(mine.everyone);
    try std.testing.expect(std.mem.indexOf(u8, mine.query, "\"-views\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mine.query, "\"type_view\":true") != null);
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
