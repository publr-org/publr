const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const document_domain = @import("document.zig");
const crud_module = @import("document/crud.zig");
const lifecycle = @import("term/lifecycle.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const terms = store.terms;

pub const namespace: sdk.operation.Namespace = .{
    .name = "term",
    .summary = "The terms of the taxonomies: what records are classified under",
    .details =
    \\A term is one document of one taxonomy in one status, with the same lifecycle as a
    \\record: a validated JSON document shaped by the taxonomy's fields, a `version`,
    \\statuses moved by `term transition`, pending edits parked by `term save` on a live
    \\term and applied by `term publish`, revisions in `snapshot list`. In a hierarchical
    \\taxonomy a term may have a `parent` term of the same taxonomy, up to 16 levels;
    \\a record assigned to a term is a member of every ancestor as well.
    \\
    \\Anyone may read live terms of public taxonomies; signed-in users read and write
    \\everything their role allows.
    ,
};

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

fn as_read(ctx: *Ctx, row: store.taxonomies.Row) Error!store.taxonomies.Row {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(row.id.len > 0);

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

/// The shared rules, and every content type the taxonomy applies to is a record type.
fn check_taxonomy_def(
    ctx: *Ctx,
    def: store.taxonomies.Def,
    problems: *model.field.Problems,
) Error!void {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(problems.len <= model.field.problems_max);

    model.taxonomy.validate_def(def, problems);

    const content_types = @import("content_type.zig");

    for (def.applies_to) |handle| {
        const row = try content_types.find_raw(ctx, handle) orelse {
            problems.add("applies_to", "unknown content type");

            continue;
        };

        if (row.def.kind != .record) {
            problems.add("applies_to", "only a record type takes terms");
        }
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

pub const example_id = "e5f60718293a4b5c6d7e8f90";
pub const example_parent_id = "f60718293a4b5c6d7e8f9012";
pub const example_changed_id = "0718293a4b5c6d7e8f901234";
pub const example_draft_id = "18293a4b5c6d7e8f90123456";
pub const example_document = "{\"name\":\"Engineering\"}";
const example_term: Term = .{
    .id = example_id,
    .type_id = "d4e5f60718293a4b5c6d7e8f",
    .type = "topics",
    .status = "published",
    .changed = false,
    .version = 2,
    .title = "Engineering",
    .slug = "engineering",
    .created_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .updated_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .created_at = 1789650000000,
    .updated_at = 1789653600000,
};

pub const Create = struct {
    pub const name = "term.create";
    pub const description = "Create a term of a taxonomy from a JSON document";
    pub const details =
        \\The document is validated against the taxonomy's fields; the title comes from
        \\its `title_field`, the slug from the `slug` field's source when the document
        \\leaves it empty, unique per taxonomy. `parent` puts the term under another term
        \\of the same taxonomy, which must be hierarchical; at most 16 levels. The status
        \\defaults to the initial status (`draft`).
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        taxonomy: []const u8,
        document: []const u8,
        status: ?[]const u8 = null,
        parent: ?[]const u8 = null,
    };
    pub const Out = struct {
        id: []const u8,
        status: []const u8,
        slug: ?[]const u8,
        version: i64,
        parent: ?[]const u8,
    };
    pub const example: In = .{ .taxonomy = "topics", .document = example_document };
    pub const example_out: Out = .{
        .id = example_id,
        .status = "draft",
        .slug = "engineering",
        .version = 1,
        .parent = null,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .taxonomy = "The taxonomy, by handle or id",
        .document = "The document as a JSON object",
        .status = "Initial status; the registry's initial status when omitted",
        .parent = "The parent term's id (hierarchical taxonomies)",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        const created = try crud.create(ctx, granted, in.taxonomy, in.document, in.status, null);

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

    for (try terms.nodes(ctx.db, ctx.arena, taxonomy_id)) |node| {
        if (node.parent_id != null) {
            return true;
        }
    }

    return false;
}

pub const Get = struct {
    pub const name = "term.get";
    pub const description = "Read one term with its document and parent";
    pub const details =
        \\`purpose` says why: `delivery` (default) is the live document; `edit` is the
        \\pending copy when the term has unpublished changes, else the live document.
        \\`slot` names a copy explicitly. Anonymous callers only see live terms of public
        \\taxonomies; anything else answers not found.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        purpose: Purpose = .delivery,
        slot: ?[]const u8 = null,
    };
    pub const Out = struct {
        term: Term,
        parent: ?[]const u8,
        slot: []const u8,
        document: []const u8,
    };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{
        .term = example_term,
        .parent = example_parent_id,
        .slot = "live",
        .document = example_document,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The term id",
        .purpose = "`delivery` or `edit`",
        .slot = "Read this copy instead (`live`, `pending`, ...); signed-in callers only",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const got = try crud.get(ctx, granted, in.id, in.purpose, in.slot);
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
    pub const name = "term.save";
    pub const description = "Write a term's document, and move it in the hierarchy";
    pub const details =
        \\As `record save`: straight in for drafts, parked as pending edits on a live
        \\term, `expected_version` refuses a stale write. `parent` moves the term under
        \\another term (an empty string makes it a root); left out, it stays where it is.
        \\Moving a term rewrites the assignments of every record filed under it or a
        \\descendant, so their ancestors follow; refused while more than 10 000
        \\assignments would change.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        document: []const u8,
        expected_version: ?i64 = null,
        parent: ?[]const u8 = null,
    };
    pub const Out = struct { version: i64, slug: ?[]const u8, changed: bool, parent: ?[]const u8 };
    pub const example: In = .{ .id = example_id, .document = example_document };
    pub const example_out: Out = .{
        .version = 3,
        .slug = "engineering",
        .changed = true,
        .parent = example_parent_id,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The term id",
        .document = "The full new document as a JSON object",
        .expected_version = "The `version` you read; refuse if it changed",
        .parent = "The new parent term's id, or empty for none; omit to keep the parent",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const saved = try crud.save(ctx, granted, in.id, in.document, in.expected_version);

        if (in.parent) |parent| {
            try place(ctx, in.id, if (parent.len == 0) null else parent);
        }

        return .{
            .version = saved.version,
            .slug = saved.slug,
            .changed = saved.changed,
            .parent = try terms.parent_of(ctx.db, ctx.arena, in.id),
        };
    }
};

pub const List = struct {
    pub const name = "term.list";
    pub const description = "List terms, of one taxonomy or across all, with status, " ++
        "author, time, filter, search, order and paging";
    pub const details =
        \\As `record list`, over terms: with no `taxonomy` (nor `taxonomies`) the list
        \\spans every taxonomy the caller may read; `filters` take the registered
        \\clauses (`status:is:draft`, `updated:within:7d`); within one taxonomy filter on
        \\a field by path or pick the term with a `slug`. For the hierarchy, see
        \\`term tree`.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        taxonomy: ?[]const u8 = null,
        taxonomies: []const []const u8 = &.{},
        filters: []const []const u8 = &.{},
        search: ?[]const u8 = null,
        slug: ?[]const u8 = null,
        filter_field: ?[]const u8 = null,
        filter_value: ?[]const u8 = null,
        order: Order = .title_asc,
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct { terms: []const Term };
    pub const example: In = .{ .taxonomy = "topics", .filters = &.{"status:is:published"} };
    pub const example_out: Out = .{ .terms = &.{example_term} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .taxonomy = "One taxonomy, by handle or id",
        .taxonomies = "Several taxonomies, by handle or id; neither: every readable one",
        .filters = "Clauses, `key:operator:value` each: `status:is:draft`, `updated:within:7d`",
        .search = "Full-text query over searchable fields",
        .slug = "Only the term whose slug field holds this value",
        .filter_field = "A field path; one taxonomy only",
        .filter_value = "The value to match",
        .order = "`title_asc` (default), `updated_desc` or `created_desc`",
        .limit = "Page size, up to 200",
        .offset = "Rows to skip",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        if (in.taxonomies.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

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
        });

        return .{ .terms = listed };
    }
};

pub const Node = struct {
    id: []const u8,
    parent: ?[]const u8,
    title: []const u8,
    slug: ?[]const u8,
    status: []const u8,
    depth: u32,
};

pub const Tree = struct {
    pub const name = "term.tree";
    pub const description = "Every term of a taxonomy in tree order, with its depth";
    pub const details =
        \\Parents come before their children, siblings by title, each term with its depth
        \\from 0. A flat taxonomy is a tree of roots. Anonymous callers get live terms of
        \\public taxonomies only; a hidden parent leaves its children at the root.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { taxonomy: []const u8 };
    pub const Out = struct { terms: []const Node };
    pub const example: In = .{ .taxonomy = "topics" };
    pub const example_out: Out = .{ .terms = &.{
        .{
            .id = example_parent_id,
            .parent = null,
            .title = "Technology",
            .slug = "technology",
            .status = "published",
            .depth = 0,
        },
        .{
            .id = example_id,
            .parent = example_parent_id,
            .title = "Engineering",
            .slug = "engineering",
            .status = "published",
            .depth = 1,
        },
    } };
    pub const field_docs: sdk.operation.Docs(In) = .{ .taxonomy = "The taxonomy, by handle or id" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        const taxonomy = try domain.definition.get(ctx, granted, in.taxonomy);
        const live_only = granted.record_filter.flags.live_only;
        const all = try terms.nodes(ctx.db, ctx.arena, taxonomy.id);
        var shown: std.ArrayList(terms.Node) = .empty;

        ctx.depend("type:", taxonomy.def.handle);

        for (all) |node| {
            if (live_only and !registry.Statuses.is_live(node.status)) {
                continue;
            }

            if (!granted.allows_status(node.status)) {
                continue;
            }

            try shown.append(ctx.arena, node);
        }

        return .{ .terms = try tree_of(ctx, shown.items) };
    }

    fn tree_of(ctx: *Ctx, nodes: []const terms.Node) Error![]const Node {
        std.debug.assert(nodes.len <= terms.tree_max);
        std.debug.assert(ctx.now_ms >= 0);

        const parents = try ctx.arena.alloc(u32, nodes.len);

        for (nodes, parents) |node, *parent| {
            parent.* = index_of(nodes, node.parent_id);
        }

        const placed = model.tree.order(ctx.arena, parents) catch return error.Invalid;
        const out = try ctx.arena.alloc(Node, placed.len);

        for (placed, out) |position, *item| {
            const node = nodes[position.index];

            ctx.depend(domain.depend_prefix, node.id);
            item.* = .{
                .id = node.id,
                .parent = node.parent_id,
                .title = node.title,
                .slug = node.slug,
                .status = node.status,
                .depth = position.depth,
            };
        }

        return out;
    }

    fn index_of(nodes: []const terms.Node, id: ?[]const u8) u32 {
        std.debug.assert(nodes.len <= terms.tree_max);
        std.debug.assert(model.tree.none > nodes.len);

        const wanted = id orelse return model.tree.none;

        for (nodes, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, wanted)) {
                return @intCast(index);
            }
        }

        return model.tree.none;
    }
};

pub const Validate = struct {
    pub const name = "term.validate";
    pub const description = "Check a document against a taxonomy and list every problem";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { taxonomy: []const u8, document: []const u8 };
    pub const Out = crud_module.Report;
    pub const example: In = .{ .taxonomy = "topics", .document = "{\"slug\":\"no name\"}" };
    pub const example_out: Out = .{ .valid = false, .problems = &.{
        .{ .path = "name", .message = "required" },
        .{ .path = "slug", .message = "must be [a-z0-9] and hyphens" },
    } };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        return crud.validate(ctx, granted, in.taxonomy, in.document);
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
        .definition = taxonomy_operations.example_definition,
    });
}

test "terms: create with a parent, tree order, save moves, get shows the parent" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_topics(&harness);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    const tech = try SDK.dispatch(&editor, Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Technology\"}",
        .status = "published",
    });
    try std.testing.expectEqualStrings("technology", tech.slug.?);
    const engineering = try SDK.dispatch(&editor, Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Engineering\"}",
        .parent = tech.id,
    });
    try std.testing.expectEqualStrings(tech.id, engineering.parent.?);
    const art = try SDK.dispatch(&editor, Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Art\"}",
    });

    const tree = try SDK.dispatch(&editor, Tree, .{ .taxonomy = "topics" });
    try std.testing.expectEqual(@as(usize, 3), tree.terms.len);
    try std.testing.expectEqualStrings("Art", tree.terms[0].title);
    try std.testing.expectEqualStrings("Technology", tree.terms[1].title);
    try std.testing.expectEqualStrings("Engineering", tree.terms[2].title);
    try std.testing.expectEqual(@as(u32, 1), tree.terms[2].depth);

    const got = try SDK.dispatch(&editor, Get, .{ .id = engineering.id });
    try std.testing.expectEqualStrings(tech.id, got.parent.?);
    try std.testing.expectEqualStrings("topics", got.term.type);

    const moved = try SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = "{\"name\":\"Technology\"}",
        .parent = art.id,
    });
    try std.testing.expectEqualStrings(art.id, moved.parent.?);
    const rooted = try SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = "{\"name\":\"Technology\"}",
        .parent = "",
    });
    try std.testing.expect(rooted.parent == null);

    const cycle = SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = "{\"name\":\"Technology\"}",
        .parent = engineering.id,
    });
    try std.testing.expectError(error.Invalid, cycle);
    const self = SDK.dispatch(&editor, Save, .{
        .id = tech.id,
        .document = "{\"name\":\"Technology\"}",
        .parent = tech.id,
    });
    try std.testing.expectError(error.Invalid, self);
    const stranger = SDK.dispatch(&editor, Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Lost\"}",
        .parent = "nope",
    });
    try std.testing.expectError(error.Invalid, stranger);

    const listed = try SDK.dispatch(&editor, List, .{ .taxonomy = "topics" });
    try std.testing.expectEqual(@as(usize, 3), listed.terms.len);
    try std.testing.expectEqualStrings("Art", listed.terms[0].title);
    const by_slug = try SDK.dispatch(&editor, List, .{
        .taxonomy = "topics",
        .slug = "engineering",
    });
    try std.testing.expectEqual(@as(usize, 1), by_slug.terms.len);

    var anon = harness.ctx(.anonymous);
    const public_tree = try SDK.dispatch(&anon, Tree, .{ .taxonomy = "topics" });
    try std.testing.expectEqual(@as(usize, 1), public_tree.terms.len);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, Get, .{ .id = art.id }));
}

test "a flat taxonomy refuses parents; the hierarchy is bounded" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_topics(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    _ = try SDK.dispatch(&admin, taxonomy_operations.Create, .{ .definition =
        \\{"handle":"tags","name":"Tags","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true}]}
    });
    const one = try SDK.dispatch(&admin, Create, .{
        .taxonomy = "tags",
        .document = "{\"name\":\"A\"}",
    });
    const flat = SDK.dispatch(&admin, Create, .{
        .taxonomy = "tags",
        .document = "{\"name\":\"B\"}",
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
            .document = text,
            .parent = parent,
        });
        parent = created.id;
    }

    const too_deep = SDK.dispatch(&admin, Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Deep\"}",
        .parent = parent,
    });
    try std.testing.expectError(error.Invalid, too_deep);

    const tree = try SDK.dispatch(&admin, Tree, .{ .taxonomy = "topics" });
    try std.testing.expectEqual(@as(usize, terms.depth_max), tree.terms.len);
    try std.testing.expectEqual(terms.depth_max - 1, tree.terms[tree.terms.len - 1].depth);

    const flatten = SDK.dispatch(&admin, taxonomy_operations.Update, .{
        .taxonomy = "topics",
        .definition =
        \\{"handle":"topics","name":"Topics","public":true,"title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
        ,
    });
    try std.testing.expectError(error.Conflict, flatten);
}
