const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/term.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const document_domain = @import("document.zig");
const crud_module = @import("document/crud.zig");
const lifecycle = @import("term/lifecycle.zig");
const changes = @import("project/changes.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const terms = store.terms;

pub const namespace = public.namespace;

/// The term domain: the shared document machinery over the term tables.
pub const domain = document_domain.Domain(.{
    .namespace = "term",
    .definition_namespace = "taxonomy",
    .noun = "term",
    .documents = store.terms,
    .values = store.term_values,
    .definitions = store.taxonomies,
    .check_create = check_taxonomy,
    .check_def = check_taxonomy_def,
    .check_document = check_term_document,
    .expand_def = as_read,
    .prepare_def = as_given,
});

/// A taxonomy as read: an internal one is not found from the site's side (a page, a
/// preview, an app's call, a visitor), whoever asks.
fn as_read(ctx: *Ctx, row: store.taxonomies.Row) Error!store.taxonomies.Row {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(row.id.len > 0);

    if (row.def.internal and @import("record.zig").site_side(ctx)) {
        return error.NotFound;
    }

    return row;
}

fn as_given(ctx: *Ctx, def: store.taxonomies.Def) Error!store.taxonomies.Def {
    std.debug.assert(ctx.now_ms >= 0);

    if (def.fields.len > model.field.fields_max) {
        return error.Invalid;
    }

    return def;
}
pub const access = domain.access;
pub const document = domain.document;
const crud = domain.crud;

fn check_taxonomy(ctx: *Ctx, row: store.taxonomies.Row) Error!void {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (row.def.kind != .record) {
        return error.Invalid;
    }
}

/// The shared rules: a taxonomy holds terms and names no types.
fn check_taxonomy_def(
    ctx: *Ctx,
    def: store.taxonomies.Def,
    problems: *model.field.Problems,
) Error!void {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(problems.len <= model.field.problems_max);

    model.taxonomy.validate_def(def, problems);

    if (def.internal and def.public) {
        problems.add("internal", "an internal taxonomy never reaches the site: not public");
    }
}

fn check_term_document(ctx: *Ctx, def: store.taxonomies.Def, parsed: std.json.Value) Error!void {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(parsed == .object);
    std.debug.assert(def.fields.len <= model.field.fields_max);
}

pub const Purpose = crud_module.Purpose;
pub const Order = terms.Order;
pub const list_max = terms.list_max;
pub const Problem = crud_module.Problem;
pub const Term = terms.Record;
pub const Transition = lifecycle.Transition;
pub const Publish = lifecycle.Publish;
pub const DiscardChanges = lifecycle.DiscardChanges;
pub const Delete = lifecycle.Delete;
pub const Purge = lifecycle.Purge;
pub const example_id = public.example_id;
pub const example_parent_id = public.example_parent_id;
pub const example_changed_id = public.example_changed_id;
pub const example_draft_id = public.example_draft_id;
pub const example_document = public.example_document;
pub const example_edit = public.example_edit;

pub const Create = struct {
    pub const shape = public.Create;
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
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        const created = try crud.create(ctx, granted, in.taxonomy, in.document.text, null, null);

        if (in.parent) |parent| {
            try place(ctx, created.id, if (parent.len == 0) null else parent);
        }

        return .{
            .id = created.id,
            .status = created.status,
            .slug = created.slug,
            .version = created.version,
            .parent = if (in.parent != null and in.parent.?.len > 0) in.parent else null,
        };
    }
};

/// A new term made live by publishing it: the media library's folders and tags.
pub fn published(ctx: *Ctx, in: Create.In) Error!Create.Out {
    std.debug.assert(in.taxonomy.len > 0);
    std.debug.assert(in.document.text.len > 0);

    var created = try registry.SDK.dispatch(ctx, Create, in);
    const moved = try registry.SDK.dispatch(ctx, Publish, .{
        .id = created.id,
    });

    created.status = moved.status;
    created.version = moved.version;

    return created;
}

/// Put a term under a parent (or at the root): the parent is a term of the same,
/// hierarchical, taxonomy, not the term itself nor one below it, and the term lands
/// within `depth_max` levels. Assignments that include the term are rebuilt.
fn place(ctx: *Ctx, id: []const u8, parent_id: ?[]const u8) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const own = try terms.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

    if (parent_id) |parent| {
        const parent_row = try terms.get(ctx.db, ctx.arena, parent) orelse return error.Invalid;
        const taxonomy = try domain.definition.find(ctx, own.type_id) orelse return error.NotFound;

        if (!taxonomy.def.hierarchical or !std.mem.eql(u8, parent_row.type_id, own.type_id)) {
            return error.Invalid;
        }

        if (std.mem.eql(u8, parent, id)) {
            return error.Invalid;
        }

        const above = try terms.ancestors(ctx.db, ctx.arena, parent);

        if (above.len + 1 >= terms.depth_max) {
            return error.Invalid;
        }

        for (above) |ancestor| {
            if (std.mem.eql(u8, ancestor, id)) {
                return error.Invalid;
            }
        }
    }

    try terms.set_parent(ctx.db, id, parent_id);

    _ = try store.record_terms.rebuild(ctx.db, ctx.arena, id);
}

/// Whether any term of a taxonomy has a parent.
pub fn has_parents(ctx: *Ctx, taxonomy_id: []const u8) Error!bool {
    std.debug.assert(taxonomy_id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    return terms.any_parented(ctx.db, taxonomy_id);
}

pub const Get = struct {
    pub const shape = public.Get;
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

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        if (ctx.reads != null and in.id.len <= store.records.id_len) {
            var buffer: [changes.key_len_max]u8 = undefined;

            ctx.depends_on(changes.term_key(&buffer, in.id) catch return error.Invalid);
        }

        var got = try crud.get(ctx, granted, in.id, in.purpose, in.slot);

        if (try domain.dimensions.wanted_of(ctx, in.dimensions)) |wanted| {
            try domain.dimensions.resolve_one(ctx, &got.record, &got.document.text, wanted);
        }

        const parent = try terms.parent_of(ctx.db, ctx.arena, got.record.id);

        return .{
            .term = got.record,
            .parent = parent,
            .slot = got.slot,
            .document = got.document,
        };
    }
};

pub const Save = struct {
    pub const shape = public.Save;
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
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const expected = in.expected_version;
        const saved = try crud.save(ctx, granted, in.id, in.document.text, expected, null);

        if (in.parent) |parent| {
            try place(ctx, in.id, if (parent.len == 0) null else parent);
        }

        return .{
            .version = saved.version,
            .slug = saved.slug,
            .changed = saved.changed,
            .outcome = saved.outcome,
            .parent = try terms.parent_of(ctx.db, ctx.arena, in.id),
        };
    }
};

pub const List = struct {
    pub const shape = public.List;
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
        if (in.taxonomies.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        try changes.listed(ctx, .terms, in.taxonomy, in.taxonomies);

        const wanted = try domain.dimensions.wanted_of(ctx, in.dimensions);
        const listed = try crud.list(ctx, granted, .{
            .definition = in.taxonomy,
            .definitions = in.taxonomies,
            .filters = in.filters,
            .search = in.search,
            .slug = in.slug,
            .filter_field = in.filter_field,
            .filter_value = in.filter_value,
            .order = in.order,
            .limit = in.limit,
            .offset = in.offset,
            .address_code = if (wanted) |pairs|
                domain.dimensions.addressed_code(ctx, pairs)
            else
                "",
        });

        if (wanted) |pairs| {
            if (pairs.len > 0) {
                const texts = try domain.listed.documents_of(ctx, listed);

                const writable = @constCast(texts);

                try domain.dimensions.resolve_listed(ctx, @constCast(listed), writable, pairs);
            }
        }

        return .{
            .terms = listed,
        };
    }
};

pub const Node = public.Node;

pub const Tree = struct {
    pub const shape = public.Tree;
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

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        try changes.listed(ctx, .terms, in.taxonomy, &.{});

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const taxonomy = try domain.definition.get(ctx, granted, in.taxonomy);

        const live_only = granted.live_only_on(taxonomy.def.handle, taxonomy.def.public);
        const statuses = try shown_statuses(ctx, live_only);
        const placed = try terms.tree_page(ctx.db, ctx.arena, taxonomy.id, .{
            .statuses_json = statuses,
            .offset = in.offset,
            .limit = in.limit,
        });
        const out = try ctx.arena.alloc(Node, placed.len);

        for (placed, out) |node, *item| {
            item.* = .{
                .id = node.id,
                .parent = node.parent_id,
                .title = node.title,
                .slug = node.slug,
                .status = node.status,
                .depth = @intCast(node.depth),
            };
        }

        return .{
            .terms = out,
            .total = try terms.tree_count(ctx.db, taxonomy.id, statuses),
        };
    }

    /// The statuses the caller sees, as a JSON array: the live ones of core's flow, which
    /// terms follow; empty for every one.
    fn shown_statuses(ctx: *Ctx, live_only: bool) Error![]const u8 {
        if (!live_only) {
            return "";
        }

        var names: std.ArrayList([]const u8) = .empty;

        for (model.status.Core.all) |status| {
            if (status.live) {
                try names.append(ctx.arena, status.id);
            }
        }

        std.debug.assert(names.items.len > 0);

        return std.json.Stringify.valueAlloc(ctx.arena, names.items, .{}) catch {
            return error.OutOfMemory;
        };
    }
};

pub const Validate = struct {
    pub const shape = public.Validate;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        return crud.validate(ctx, granted, in.taxonomy, in.document.text);
    }
};

pub const operations = [_]type{
    Create, Get,    Save,           Transition, Publish,  List,
    Tree,   Delete, DiscardChanges, Purge,      Validate,
};

const SDK = registry.SDK;
const taxonomy_operations = @import("taxonomy.zig");

pub fn seed_topics(harness: *sdk.testing.Harness) !void {
    var system = harness.ctx(.system);

    std.debug.assert(system.caller == .system);
    std.debug.assert(harness.buffer.len > 0);

    try SDK.bootstrap(&system);
    _ = try SDK.dispatch(&system, taxonomy_operations.Create, .{
        .definition = .{
            .text = taxonomy_operations.example_definition,
        },
    });
}

test "terms: create with a parent, tree order, save moves, get shows the parent" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_topics(&harness);

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    const tech = try published(&editor, .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"name\":\"Technology\"}",
        },
    });
    try std.testing.expectEqualStrings("technology", tech.slug.?);
    const engineering = try SDK.dispatch(&editor, Create, .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"name\":\"Engineering\"}",
        },
        .parent = tech.id,
    });
    try std.testing.expectEqualStrings(tech.id, engineering.parent.?);
    const art = try SDK.dispatch(&editor, Create, .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"name\":\"Art\"}",
        },
    });

    const tree = try SDK.dispatch(&editor, Tree, .{
        .taxonomy = "topics",
    });
    try std.testing.expectEqual(@as(usize, 3), tree.terms.len);
    try std.testing.expectEqualStrings("Art", tree.terms[0].title);
    try std.testing.expectEqualStrings("Technology", tree.terms[1].title);
    try std.testing.expectEqualStrings("Engineering", tree.terms[2].title);
    try std.testing.expectEqual(@as(u32, 1), tree.terms[2].depth);

    const got = try SDK.dispatch(&editor, Get, .{
        .id = engineering.id,
    });
    try std.testing.expectEqualStrings(tech.id, got.parent.?);
    try std.testing.expectEqualStrings("topics", got.term.type);

    const moved = try SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = .{
            .text = "{\"name\":\"Technology\"}",
        },
        .parent = art.id,
    });
    try std.testing.expectEqualStrings(art.id, moved.parent.?);
    const rooted = try SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = .{
            .text = "{\"name\":\"Technology\"}",
        },
        .parent = "",
    });
    try std.testing.expect(rooted.parent == null);

    const cycle = SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = .{
            .text = "{\"name\":\"Technology\"}",
        },
        .parent = engineering.id,
    });
    try std.testing.expectError(error.Invalid, cycle);
    const self = SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = .{
            .text = "{\"name\":\"Technology\"}",
        },
        .parent = tech.id,
    });
    try std.testing.expectError(error.Invalid, self);
    const stranger = SDK.dispatch(&editor, Create, .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"name\":\"Lost\"}",
        },
        .parent = "nope",
    });
    try std.testing.expectError(error.Invalid, stranger);

    const listed = try SDK.dispatch(&editor, List, .{
        .taxonomy = "topics",
    });
    try std.testing.expectEqual(@as(usize, 3), listed.terms.len);
    try std.testing.expectEqualStrings("Art", listed.terms[0].title);
    const by_slug = try SDK.dispatch(&editor, List, .{
        .taxonomy = "topics",
        .slug = "engineering",
    });
    try std.testing.expectEqual(@as(usize, 1), by_slug.terms.len);

    var anon = harness.ctx(.anonymous);
    const public_tree = try SDK.dispatch(&anon, Tree, .{
        .taxonomy = "topics",
    });
    try std.testing.expectEqual(@as(usize, 1), public_tree.terms.len);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, Get, .{
        .id = art.id,
    }));
}

test "a flat taxonomy refuses parents; the hierarchy is bounded" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_topics(&harness);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    _ = try SDK.dispatch(&admin, taxonomy_operations.Create, .{
        .definition = .{
            .text =
            \\{"handle":"tags","name":"Tags","title_field":"name",
            \\ "fields":[{"name":"name","label":"Name","kind":"string",
            \\ "validation":{"required":true}}]}
            ,
        },
    });
    const one = try SDK.dispatch(&admin, Create, .{
        .taxonomy = "tags",
        .document = .{
            .text = "{\"name\":\"A\"}",
        },
    });
    const flat = SDK.dispatch(&admin, Create, .{
        .taxonomy = "tags",
        .document = .{
            .text = "{\"name\":\"B\"}",
        },
        .parent = one.id,
    });
    try std.testing.expectError(error.Invalid, flat);

    var parent: ?[]const u8 = null;
    var depth: u32 = 0;

    while (depth < terms.depth_max) : (depth += 1) {
        const arena = harness.fixed.allocator();
        const text = try std.fmt.allocPrint(arena, "{{\"name\":\"L{d}\"}}", .{depth});
        const created = try SDK.dispatch(&admin, Create, .{
            .taxonomy = "topics",
            .document = .{
                .text = text,
            },
            .parent = parent,
        });
        parent = created.id;
    }

    const too_deep = SDK.dispatch(&admin, Create, .{
        .taxonomy = "topics",
        .document = .{
            .text = "{\"name\":\"Deep\"}",
        },
        .parent = parent,
    });
    try std.testing.expectError(error.Invalid, too_deep);

    const tree = try SDK.dispatch(&admin, Tree, .{
        .taxonomy = "topics",
    });
    try std.testing.expectEqual(@as(usize, terms.depth_max), tree.terms.len);
    try std.testing.expectEqual(terms.depth_max - 1, tree.terms[tree.terms.len - 1].depth);

    const flatten = SDK.dispatch(&admin, taxonomy_operations.Update, .{
        .taxonomy = "topics",
        .definition = .{
            .text =
            \\{"handle":"topics","name":"Topics","public":true,"title_field":"name",
            \\ "fields":[{"name":"name","label":"Name","kind":"string",
            \\ "validation":{"required":true}},
            \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
            ,
        },
    });
    try std.testing.expectError(error.Conflict, flatten);
}
