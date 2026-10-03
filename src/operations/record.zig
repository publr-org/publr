const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const types = @import("content_type.zig");
const taxonomies = @import("taxonomy.zig");
const document_domain = @import("document.zig");
const crud_module = @import("document/crud.zig");
pub const fixture = @import("record/fixture.zig");
const lifecycle = @import("record/lifecycle.zig");
const virtual = @import("record/virtual.zig");
const virtual_edit = @import("record/virtual/edit.zig");
const app_module = @import("record/app.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const records = store.records;

pub const namespace: sdk.operation.Namespace = .{
    .name = "record",
    .summary = "The content itself: one document per record, in one status",
    .details =
    \\A record is one document of one content type in one status. Documents are JSON
    \\objects shaped by the type's fields and validated on every write. Each write bumps
    \\the record's `version`; pass `expected_version` to refuse overwriting someone
    \\else's change.
    \\
    \\Status is the publication axis (`draft`, `published`, `archived`, `deleted`,
    \\moved by `record transition`); `changed` is the editing axis: saving a live record
    \\parks the edit in a pending copy and sets `changed`, the live document stays as
    \\it is until `record publish` applies the copy, or `record discard_changes` drops
    \\it. Unpublishing, archiving and deleting keep pending edits as they are.
    \\
    \\Anyone may read live records of public types; signed-in users read and write
    \\everything their role allows.
    ,
};

/// The record domain: the shared document machinery over the record tables. A component
/// has no records of its own; a settings type has exactly one.
pub const domain = document_domain.Domain(.{
    .namespace = "record",
    .definition_namespace = "content_type",
    .noun = "record",
    .documents = store.records,
    .values = store.values,
    .definitions = store.content_types,
    .check_create = check_kind,
    .check_def = check_content_type,
    .check_document = check_record_document,
    .expand_def = with_taxonomies,
    .prepare_def = without_taxonomies,
});

/// A content type as read: its own fields, then the implicit `terms` field of every
/// taxonomy that applies to it.
fn with_taxonomies(ctx: *Ctx, row: store.content_types.Row) Error!store.content_types.Row {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.def.fields.len <= model.field.fields_max);

    const applying = try store.taxonomies.list(ctx.db, ctx.arena);
    var fields: std.ArrayList(model.field.Def) = .empty;

    try fields.appendSlice(ctx.arena, row.def.fields);

    for (applying) |taxonomy| {
        if (!model.taxonomy.applies(taxonomy.def, row.def.handle)) {
            continue;
        }

        if (fields.items.len == model.field.fields_max) {
            break;
        }

        try fields.append(ctx.arena, model.taxonomy.implicit_field(taxonomy.def));
    }

    var expanded = row;

    expanded.def.fields = fields.items;

    return expanded;
}

/// A content type as given: the implicit fields, if the caller sent them back, are dropped;
/// they are the taxonomy's, never stored on the type.
fn without_taxonomies(ctx: *Ctx, def: store.content_types.Def) Error!store.content_types.Def {
    std.debug.assert(ctx.now_ms >= 0);

    if (def.fields.len > model.field.fields_max) {
        return error.Invalid;
    }

    var fields: std.ArrayList(model.field.Def) = .empty;

    for (def.fields) |candidate| {
        const implicit = candidate.locked and std.mem.eql(u8, candidate.kind, "terms") and
            std.mem.eql(u8, candidate.name, candidate.options.taxonomy);

        if (!implicit) {
            try fields.append(ctx.arena, candidate);
        }
    }

    var own = def;

    own.fields = fields.items;

    return own;
}
pub const access = domain.access;
const settings_denied = @import("document/access.zig").settings_denied;
pub const document = domain.document;
const crud = domain.crud;

fn check_kind(ctx: *Ctx, row: store.content_types.Row) Error!void {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    switch (row.def.kind) {
        .record => {},
        .component => return error.Invalid,
        .settings => {
            if (settings_denied(ctx)) {
                return error.Denied;
            }

            if (try records.count_by_type(ctx.db, row.id) > 0) {
                return error.Conflict;
            }
        },
    }
}

/// What a content type may not be: hierarchical is for taxonomies, and every `terms`
/// field names a taxonomy that exists.
fn check_content_type(
    ctx: *Ctx,
    def: store.content_types.Def,
    problems: *model.field.Problems,
) Error!void {
    std.debug.assert(problems.len <= model.field.problems_max);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    if (def.hierarchical) {
        problems.add("hierarchical", "only a taxonomy is hierarchical");
    }

    if (def.applies_to.len > 0 or def.single) {
        problems.add("applies_to", "only a taxonomy applies to content types");
    }

    var buffer: [model.field.fields_max]model.field.Def = undefined;

    for (model.taxonomy.terms_fields(def.fields, &buffer)) |assigned| {
        if (try taxonomies.find(ctx, assigned.options.taxonomy) == null) {
            problems.add(assigned.name, "unknown taxonomy");
        }
    }
}

/// Every term a document assigns exists and belongs to the field's taxonomy.
fn check_record_document(
    ctx: *Ctx,
    def: store.content_types.Def,
    parsed: std.json.Value,
) Error!void {
    std.debug.assert(parsed == .object);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    var buffer: [model.field.fields_max]model.field.Def = undefined;

    for (model.taxonomy.terms_fields(def.fields, &buffer)) |assigned| {
        const chosen = parsed.object.get(assigned.name) orelse continue;

        switch (chosen) {
            .string => |id| try check_term(ctx, assigned, id),
            .array => |items| {
                if (items.items.len > store.record_terms.ids_max) {
                    return error.Invalid;
                }

                for (items.items) |item| {
                    if (item == .string) {
                        try check_term(ctx, assigned, item.string);
                    }
                }
            },
            else => {},
        }
    }
}

fn check_term(ctx: *Ctx, assigned: model.field.Def, id: []const u8) Error!void {
    std.debug.assert(assigned.options.taxonomy.len > 0);

    if (id.len > model.validate.id_len_max) {
        return error.Invalid;
    }

    const term = try store.terms.get(ctx.db, ctx.arena, id) orelse return error.Invalid;

    if (!std.mem.eql(u8, term.type, assigned.options.taxonomy)) {
        return error.Invalid;
    }
}

pub const Purpose = crud_module.Purpose;
pub const Order = records.Order;
pub const list_max = records.list_max;
pub const Problem = crud_module.Problem;
pub const Record = records.Record;
pub const Transition = lifecycle.Transition;
pub const Publish = lifecycle.Publish;
pub const DiscardChanges = lifecycle.DiscardChanges;
pub const Delete = lifecycle.Delete;
pub const Purge = lifecycle.Purge;
pub const SetApp = app_module.SetApp;

pub const example_id = "a1b2c3d4e5f60718293a4b5c";
pub const example_changed_id = "b2c3d4e5f60718293a4b5c6d";
pub const example_draft_id = "c3d4e5f60718293a4b5c6d7e";
pub const example_document = "{\"title\":\"Hello, world\",\"body\":\"<p>First post.</p>\"}";
const example_record: Record = .{
    .id = example_id,
    .type_id = "7c2d9e4f1a8b3c5d6e7f8a9b",
    .type = "post",
    .status = "published",
    .changed = false,
    .version = 3,
    .title = "Hello, world",
    .slug = "hello-world",
    .created_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .updated_by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .created_at = 1789650000000,
    .updated_at = 1789653600000,
};

pub const Create = struct {
    pub const name = "record.create";
    pub const description = "Create a record of a type from a JSON document";
    pub const details =
        \\The document is validated against the type's fields; the title comes from
        \\the type's `title_field`. When the type has a `slug` field it is filled from
        \\its source (or the title) when the document leaves it empty, and made unique
        \\per type. The status defaults to the initial status (`draft`); a type may
        \\restrict which statuses it accepts. `app` says which app the record belongs to
        \\(an app's `.name`); a record made through an app belongs to it unless told,
        \\anything else to the project.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        document: []const u8,
        status: ?[]const u8 = null,
        app: ?[]const u8 = null,
    };
    pub const Out = crud_module.Created;
    pub const example: In = .{ .type = "post", .document = example_document };
    pub const example_out: Out = .{
        .id = example_id,
        .status = "draft",
        .slug = "hello-world",
        .version = 1,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The content type, by handle or id",
        .document = "The document as a JSON object",
        .status = "Initial status; the registry's initial status when omitted",
        .app = "The app it belongs to, by `.name`; empty for the project's own",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        return crud.create(ctx, granted, in.type, in.document, in.status, in.app);
    }
};

pub const Get = struct {
    pub const name = "record.get";
    pub const description = "Read one record with its document";
    pub const details =
        \\`purpose` says why: `delivery` (default) is the live document, what a site or
        \\API consumer wants; `edit` is what the admin editor wants: the pending copy
        \\when the record has unpublished changes, else the live document. `slot` names a
        \\copy explicitly (`live`, `pending`, or a plugin's own) for previews. Anonymous
        \\callers only see live records of public types; anything else answers not found.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
        purpose: Purpose = .delivery,
        slot: ?[]const u8 = null,
    };
    pub const Out = crud_module.Got;
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{
        .record = example_record,
        .slot = "live",
        .document = example_document,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .purpose = "`delivery` or `edit`",
        .slot = "Read this copy instead (`live`, `pending`, ...); signed-in callers only",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        var got = try crud.get(ctx, granted, in.id, in.purpose, in.slot);

        // What a site or the API reads shows virtual fields worked out; the editor gets
        // what they keep, to save it back.
        if (in.purpose == .delivery) {
            var one = [_][]const u8{got.document};

            try virtual.expand(ctx, &.{got.record}, &one, &.{});
            got.document = one[0];
        } else {
            got.document = try virtual_edit.with_members(ctx, granted, got.record, got.document);
        }

        return got;
    }
};

pub const Save = struct {
    pub const name = "record.save";
    pub const description = "Write a record's fields: straight in for drafts, parked when live";
    pub const details =
        \\Writes the fields the document gives over the copy it changes; a field left out
        \\keeps its value. Validates the whole, keeps the slug unless the document sets one,
        \\bumps `version`. Pass the `version` you last read as `expected_version` and the
        \\save is refused (`conflict`) if someone saved in between. Without `status`: on a
        \\live record (or one that already has pending edits) the fields are parked in the
        \\pending copy and the record is marked `changed`; the live document is untouched
        \\until `record publish`. Otherwise they go into the record's own document, the old
        \\one kept as a revision snapshot. With `status`, the record's current one or one a
        \\registered transition reaches: the fields go straight into the live document (and
        \\into the pending copy, which stays pending), then the record moves to `status`.
        \\The type must accept the status and the grant allow it, as for `record create`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        document: []const u8,
        expected_version: ?i64 = null,
        status: ?[]const u8 = null,
    };
    pub const Out = crud_module.Saved;
    pub const example: In = .{ .id = example_id, .document = example_document };
    pub const example_out: Out = .{ .version = 3, .slug = "hello-world", .changed = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .document = "The fields to write, as a JSON object; the others keep their values",
        .expected_version = "The `version` you read; refuse if it changed",
        .status = "Write straight into the live document and end in this status",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        // A virtual field's list is written into the records it names before the save keeps
        // its order.
        try virtual_edit.apply(ctx, granted, in.id, in.document);

        return crud.save(ctx, granted, in.id, in.document, in.expected_version, in.status);
    }
};

pub const List = struct {
    pub const name = "record.list";
    pub const description = "List records, of one type or across the content, with status, " ++
        "author, time, filter, search, order and paging";
    pub const details =
        \\With no `type` (nor `types`) the list spans regular content types the caller may read.
        \\Settings require an explicit `type` or `types` selection.
        \\`filters` are clauses, `key:operator:value` each, of the filters the registry
        \\knows (the core ones, and a plugin's): `status:is:draft`, `status:not:archived`,
        \\`changed:is:pending` (or `none`), `created:by:me` (a user id or `me`; `updated`
        \\the same), `updated:within:7d` (`24h`, `7d`, `30d`, `90d`),
        \\`created:after:2026-01-01`, `created:before:2026-02-01`. An
        \\empty value asks nothing. Within one type, filter on any field by its path
        \\(`filter_field` + `filter_value`; `seo.title`, `faq.question` for nested ones;
        \\numbers and booleans compare as numbers, `true` = 1; references and images by
        \\the target id); search uses fields marked `searchable` (full text). Filters,
        \\search and order look at live values only. Anonymous callers get live records of
        \\public types only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        type: ?[]const u8 = null,
        types: []const []const u8 = &.{},
        filters: []const []const u8 = &.{},
        search: ?[]const u8 = null,
        slug: ?[]const u8 = null,
        filter_field: ?[]const u8 = null,
        filter_value: ?[]const u8 = null,
        filter_values: []const []const u8 = &.{},
        ids: []const []const u8 = &.{},
        order: Order = .updated_desc,
        limit: u32 = 50,
        offset: u32 = 0,
        documents: bool = false,
        /// With `documents`: virtual fields worked out (`false` reads what they keep).
        expand: bool = true,
    };
    pub const Out = struct {
        records: []const Record,
        /// With `documents`: each record's live document, in the records' order.
        documents: []const []const u8 = &.{},
    };
    pub const example: In = .{ .type = "post", .filters = &.{"status:is:published"}, .limit = 20 };
    pub const example_out: Out = .{ .records = &.{example_record} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "One content type, by handle or id",
        .types = "Several content types, by handle or id; " ++
            "neither: every readable regular content type",
        .filters = "Clauses, `key:operator:value` each: `status:is:draft`, `updated:within:7d`",
        .search = "Full-text query over searchable fields",
        .slug = "Only the record whose slug field holds this value (a type with a slug field)",
        .filter_field = "A field path (`views`, `seo.title`, `tags`); one type only",
        .filter_value = "The value to match (text, number, true/false, or an id for references)",
        .filter_values = "With `filter_field`: any of these values (references or text)",
        .ids = "Only these records, by id (up to the page size)",
        .order = "`updated_desc` (default), `created_desc` or `title_asc`",
        .limit = "Page size, up to 200",
        .offset = "Rows to skip",
        .documents = "Also return each record's live document, read with the page in one go",
        .expand = "With documents: virtual fields as the records they stand for (default)",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        if (in.types.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        const listed = try crud.list(ctx, granted, .{
            .definition = in.type,
            .definitions = in.types,
            .filters = in.filters,
            .search = in.search,
            .slug = in.slug,
            .filter_field = in.filter_field,
            .filter_value = in.filter_value,
            .filter_values = in.filter_values,
            .ids = in.ids,
            .order = in.order,
            .limit = in.limit,
            .offset = in.offset,
        });

        if (!in.documents) {
            return .{ .records = listed };
        }

        const documents = try domain.listed.documents_of(ctx, listed);

        if (in.expand) {
            const writable = @constCast(documents);
            const clauses = try virtual.kept_clauses(ctx.arena, in.filters);

            try virtual.expand(ctx, listed, writable, clauses);
        }

        return .{ .records = listed, .documents = documents };
    }
};

pub const Referrers = struct {
    pub const name = "record.referrers";
    pub const description = "List the records whose references point at a record or media item";
    pub const details =
        \\Every reference and image value is a pointer to another record, and Publr keeps
        \\a reverse index of them. Give a record id (or a media id) and get back who
        \\points at it and through which field. Only records the caller may read are
        \\listed.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { referrers: []const Referrer };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .referrers = &.{
        .{ .record_id = "9b1e7c3d5a2f4e6b8d0c1a3f", .field = "related" },
    } };
    pub const field_docs: sdk.operation.Docs(In) = .{ .id = "The target record or media id" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .referrers = "Record id and field path (`related`, `faq.link`) that points at the target",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return .{ .referrers = try crud.referrers(ctx, granted, in.id) };
    }
};

pub const Referrer = crud_module.Referrer;

pub const Validate = struct {
    pub const name = "record.validate";
    pub const description = "Check a document against a type and list every problem without saving";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { type: []const u8, document: []const u8 };
    pub const Out = crud_module.Report;
    pub const example: In = .{ .type = "post", .document = "{\"body\":\"no title\",\"extra\":1}" };
    pub const example_out: Out = .{ .valid = false, .problems = &.{
        .{ .path = "title", .message = "required" },
        .{ .path = "extra", .message = "unknown field" },
    } };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        return crud.validate(ctx, granted, in.type, in.document);
    }
};

pub const Shown = @import("record/shown.zig").Shown(List, example_id);
pub const Query = @import("record/query.zig").Query;

pub const operations = [_]type{
    Create,    Get,    Save,           Transition, Publish,  List,
    Referrers, Delete, DiscardChanges, Purge,      Validate, SetApp,
    Shown,     Query,
};

const SDK = registry.SDK;

fn seed_admin_type(harness: *sdk.testing.Harness) !void {
    var system = harness.ctx(.system);

    std.debug.assert(system.caller == .system);
    std.debug.assert(harness.buffer.len > 0);

    try SDK.bootstrap(&system);
    try fixture.post_type(&system);
}

test "create, get, save with expected_version, transition, list; slugs are unique per type" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    const first = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = example_document },
    );
    try std.testing.expectEqualStrings("draft", first.status);
    try std.testing.expectEqualStrings("hello-world", first.slug.?);

    const second = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = example_document },
    );
    try std.testing.expectEqualStrings("hello-world-2", second.slug.?);

    const got = try SDK.dispatch(&editor, Get, .{ .id = first.id });
    try std.testing.expectEqualStrings("Hello, world", got.record.title);
    try std.testing.expectEqualStrings("u_ed", got.record.created_by.?);
    try std.testing.expectEqual(@as(i64, 1), got.record.version);

    const saved = try SDK.dispatch(&editor, Save, .{
        .id = first.id,
        .document = "{\"title\":\"Hello again\",\"body\":\"x\"}",
        .expected_version = 1,
    });
    try std.testing.expectEqual(@as(i64, 2), saved.version);
    try std.testing.expectEqualStrings("hello-world", saved.slug.?);

    const stale = SDK.dispatch(
        &editor,
        Save,
        .{ .id = first.id, .document = example_document, .expected_version = 1 },
    );
    try std.testing.expectError(error.Conflict, stale);

    const invalid = SDK.dispatch(
        &editor,
        Save,
        .{ .id = first.id, .document = "{\"title\":\"\",\"body\":\"no title\"}" },
    );
    try std.testing.expectError(error.Invalid, invalid);

    const published = try SDK.dispatch(&editor, Transition, .{ .id = first.id, .to = "published" });
    try std.testing.expectEqualStrings("published", published.status);
    try std.testing.expectEqual(@as(i64, 3), published.version);
    const bad_move = SDK.dispatch(&editor, Transition, .{ .id = first.id, .to = "nope" });
    try std.testing.expectError(error.Invalid, bad_move);

    const drafts = try SDK.dispatch(&editor, List, .{
        .type = "post",
        .filters = &.{"status:is:draft"},
    });
    try std.testing.expectEqual(@as(usize, 1), drafts.records.len);
    const everything = try SDK.dispatch(&editor, List, .{ .type = "post", .order = .title_asc });
    try std.testing.expectEqual(@as(usize, 2), everything.records.len);
    try std.testing.expectEqualStrings("Hello again", everything.records[0].title);

    const by_slug = try SDK.dispatch(&editor, List, .{ .type = "post", .slug = "hello-world-2" });
    try std.testing.expectEqual(@as(usize, 1), by_slug.records.len);
    try std.testing.expectEqualStrings(second.id, by_slug.records[0].id);
    const no_slug = try SDK.dispatch(&editor, List, .{ .type = "post", .slug = "nope" });
    try std.testing.expectEqual(@as(usize, 0), no_slug.records.len);
    const both = SDK.dispatch(&editor, List, .{
        .type = "post",
        .slug = "x",
        .filter_field = "views",
    });
    try std.testing.expectError(error.Invalid, both);
}

test "a unique field refuses a value another record holds; a new record takes defaults" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    _ = try SDK.dispatch(&system, types.Create, .{ .definition =
        \\{"handle":"product","name":"Product","public":true,"title_field":"title","fields":[
        \\{"name":"title","label":"Title","kind":"string","default":"Untitled"},
        \\{"name":"sku","label":"SKU","kind":"string","unique":true},
        \\{"name":"stock","label":"Stock","kind":"integer","default":"5"}]}
    });

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    const first = try SDK.dispatch(&editor, Create, .{
        .type = "product",
        .document = "{\"sku\":\"A-1\"}",
    });
    const got = try SDK.dispatch(&editor, Get, .{ .id = first.id });
    try std.testing.expectEqualStrings("Untitled", got.record.title);
    try std.testing.expect(std.mem.indexOf(u8, got.document, "\"stock\":5") != null);

    const taken = SDK.dispatch(&editor, Create, .{
        .type = "product",
        .document = "{\"title\":\"Other\",\"sku\":\"A-1\"}",
    });
    try std.testing.expectError(error.Conflict, taken);

    const second = try SDK.dispatch(&editor, Create, .{
        .type = "product",
        .document = "{\"title\":\"Other\",\"sku\":\"A-2\"}",
    });
    const kept = try SDK.dispatch(&editor, Save, .{
        .id = second.id,
        .document = "{\"title\":\"Other\",\"sku\":\"A-2\"}",
    });
    try std.testing.expectEqual(@as(i64, 2), kept.version);
    const collides = SDK.dispatch(&editor, Save, .{
        .id = second.id,
        .document = "{\"title\":\"Other\",\"sku\":\"A-1\"}",
    });
    try std.testing.expectError(error.Conflict, collides);
}

test "a grant for the caller's own records pages over those alone" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var ada = harness.ctx(.{ .user = .{ .id = "u_ada", .roles = &.{"editor"} } });
    var bob = harness.ctx(.{ .user = .{ .id = "u_bob", .roles = &.{"editor"} } });
    const own: sdk.Grant = .{ .record_filter = .{ .flags = .{ .own_only = true } } };

    ada.parent = ada.allocate_operation_id();
    bob.parent = bob.allocate_operation_id();

    const mine = try SDK.dispatch(&ada, Create, .{ .type = "post", .document = example_document });
    // Bob's is the newest: a filter applied after the limit would leave Ada with nothing.
    _ = try SDK.dispatch(&bob, Create, .{
        .type = "post",
        .document = "{\"title\":\"Bob's\",\"body\":\"b\"}",
    });

    const first = try List.run(&ada, .{ .type = "post", .order = .created_desc, .limit = 1 }, &own);
    try std.testing.expectEqual(@as(usize, 1), first.records.len);
    try std.testing.expectEqualStrings(mine.id, first.records[0].id);

    const theirs = try List.run(&ada, .{
        .type = "post",
        .filters = &.{"created:by:u_bob"},
    }, &own);
    try std.testing.expectEqual(@as(usize, 0), theirs.records.len);
}

test "a slug field that refuses taken slugs: a given one conflicts, a derived one is numbered" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    var strict = model.content_type.test_post;
    strict.handle = "address";
    strict.name = "Address";
    strict.fields = &.{
        .{ .name = "title", .label = "Title", .kind = "string", .required = true },
        .{
            .name = "slug",
            .label = "Slug",
            .kind = "slug",
            .options = .{
                .source = "title",
                .slug = .{ .refuse_taken = true, .reserved = &.{"admin"} },
            },
        },
    };
    const definition = try model.content_type.encode(harness.fixed.allocator(), strict);
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = definition });

    const first = try SDK.dispatch(&admin, Create, .{
        .type = "address",
        .document = "{\"title\":\"Home\",\"slug\":\"home\"}",
    });
    const typed = SDK.dispatch(&admin, Create, .{
        .type = "address",
        .document = "{\"title\":\"Other\",\"slug\":\"home\"}",
    });
    const derived = try SDK.dispatch(&admin, Create, .{
        .type = "address",
        .document = "{\"title\":\"Home\"}",
    });

    try std.testing.expectEqualStrings("home", first.slug.?);
    try std.testing.expectError(error.Conflict, typed);
    try std.testing.expectEqualStrings("home-2", derived.slug.?);

    const kept = try SDK.dispatch(&admin, Create, .{
        .type = "address",
        .document = "{\"title\":\"Admin\"}",
    });
    const typed_kept = SDK.dispatch(&admin, Create, .{
        .type = "address",
        .document = "{\"title\":\"X\",\"slug\":\"admin\"}",
    });

    try std.testing.expectEqualStrings("admin-2", kept.slug.?);
    try std.testing.expectError(error.Invalid, typed_kept);
}

test "anonymous callers see live records of public types only; private types are invisible" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    var anon = harness.ctx(.anonymous);
    var private = model.content_type.test_post;
    private.handle = "note";
    private.name = "Note";
    private.public = false;
    const private_definition = try model.content_type.encode(harness.fixed.allocator(), private);
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = private_definition });

    const draft = try SDK.dispatch(
        &admin,
        Create,
        .{ .type = "post", .document = example_document },
    );
    const live = try SDK.dispatch(&admin, Create, .{
        .type = "post",
        .document = "{\"title\":\"Live one\",\"body\":\"y\"}",
        .status = "published",
    });
    const secret = try SDK.dispatch(&admin, Create, .{
        .type = "note",
        .document = "{\"title\":\"Secret\",\"body\":\"z\"}",
        .status = "published",
    });

    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, Get, .{ .id = draft.id }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, Get, .{ .id = secret.id }));
    try std.testing.expectEqualStrings(
        "Live one",
        (try SDK.dispatch(&anon, Get, .{ .id = live.id })).record.title,
    );

    const listed = try SDK.dispatch(&anon, List, .{ .type = "post" });
    try std.testing.expectEqual(@as(usize, 1), listed.records.len);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&anon, List, .{ .type = "note" }));
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&anon, Create, .{ .type = "post", .document = example_document }),
    );

    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, types.List, .{}));
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&anon, types.Create, .{ .definition = private_definition }),
    );

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&editor, types.Create, .{ .definition = private_definition }),
    );

    const visible_types = (try SDK.dispatch(&editor, types.List, .{})).types;
    var seen_post = false;
    var seen_note = false;

    for (visible_types) |summary| {
        seen_post = seen_post or std.mem.eql(u8, summary.handle, "post");
        seen_note = seen_note or std.mem.eql(u8, summary.handle, "note");
    }

    try std.testing.expect(seen_post and seen_note);
}

test "list across types: every readable type, the ones named, exclusions, one-type filters" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    var anon = harness.ctx(.anonymous);
    var private = model.content_type.test_post;
    private.handle = "note";
    private.name = "Note";
    private.public = false;
    const private_definition = try model.content_type.encode(harness.fixed.allocator(), private);
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = private_definition });
    _ = try SDK.dispatch(&admin, Create, .{ .type = "post", .document = example_document });
    _ = try SDK.dispatch(&admin, Create, .{
        .type = "post",
        .document = "{\"title\":\"Live one\",\"body\":\"y\"}",
        .status = "published",
    });
    _ = try SDK.dispatch(&admin, Create, .{
        .type = "note",
        .document = "{\"title\":\"Secret\",\"body\":\"z\"}",
        .status = "published",
    });
    _ = try SDK.dispatch(&editor, Create, .{
        .type = "note",
        .document = "{\"title\":\"Mine\",\"body\":\"m\",\"views\":7}",
    });

    const everything = try SDK.dispatch(&editor, List, .{ .order = .title_asc });
    try std.testing.expectEqual(@as(usize, 4), everything.records.len);
    try std.testing.expectEqualStrings("Hello, world", everything.records[0].title);
    try std.testing.expectEqualStrings("note", everything.records[2].type);
    const public_live = try SDK.dispatch(&anon, List, .{});
    try std.testing.expectEqual(@as(usize, 1), public_live.records.len);
    try std.testing.expectEqualStrings("Live one", public_live.records[0].title);

    const named = try SDK.dispatch(&editor, List, .{ .types = &.{ "post", "note" } });
    try std.testing.expectEqual(@as(usize, 4), named.records.len);
    try std.testing.expectError(
        error.NotFound,
        SDK.dispatch(&anon, List, .{ .types = &.{ "post", "note" } }),
    );
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&editor, List, .{ .type = "post", .types = &.{"note"} }),
    );

    const not_drafts = try SDK.dispatch(&editor, List, .{ .filters = &.{"status:not:draft"} });
    try std.testing.expectEqual(@as(usize, 2), not_drafts.records.len);
    const by_admin = try SDK.dispatch(&editor, List, .{ .filters = &.{"created:by:u_admin"} });
    try std.testing.expectEqual(@as(usize, 3), by_admin.records.len);
    const saved_by_editor = try SDK.dispatch(&editor, List, .{ .filters = &.{"updated:by:u_ed"} });
    try std.testing.expectEqual(@as(usize, 1), saved_by_editor.records.len);
    try std.testing.expectEqualStrings("Mine", saved_by_editor.records[0].title);
    const mine = try SDK.dispatch(&editor, List, .{ .filters = &.{"created:by:me"} });
    try std.testing.expectEqual(@as(usize, 1), mine.records.len);
    const later = try SDK.dispatch(&editor, List, .{ .filters = &.{"updated:after:2100-01-01"} });
    try std.testing.expectEqual(@as(usize, 0), later.records.len);
    const lately = try SDK.dispatch(&editor, List, .{
        .filters = &.{ "updated:within:24h", "changed:is:none" },
    });
    try std.testing.expectEqual(@as(usize, 4), lately.records.len);
    const mine_lately = try SDK.dispatch(&editor, List, .{
        .filters = &.{ "created:by:me", "created:within:24h" },
    });
    try std.testing.expectEqual(@as(usize, 1), mine_lately.records.len);
    const twice_since: List.In = .{
        .filters = &.{ "created:within:24h", "created:after:2020-01-01" },
    };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&editor, List, twice_since));
    const unknown_filter: List.In = .{ .filters = &.{"nope:is:x"} };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&editor, List, unknown_filter));
    const wrong_operator: List.In = .{ .filters = &.{"status:within:7d"} };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&editor, List, wrong_operator));
    const nobody_me: List.In = .{ .filters = &.{"created:by:me"} };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&anon, List, nobody_me));

    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&editor, List, .{ .filter_field = "views", .filter_value = "7" }),
    );
    const sevens = try SDK.dispatch(&editor, List, .{
        .type = "note",
        .filter_field = "views",
        .filter_value = "7",
    });
    try std.testing.expectEqual(@as(usize, 1), sevens.records.len);
}

test "validate reports problems; filters and search go through the projection" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    const report = try SDK.dispatch(
        &editor,
        Validate,
        .{ .type = "post", .document = "{\"body\":1,\"extra\":true}" },
    );
    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(usize, 3), report.problems.len);

    _ = try SDK.dispatch(
        &editor,
        Create,
        .{
            .type = "post",
            .document = "{\"title\":\"Ten\",\"body\":\"about apples\",\"views\":10}",
        },
    );
    _ = try SDK.dispatch(
        &editor,
        Create,
        .{
            .type = "post",
            .document = "{\"title\":\"Twenty\",\"body\":\"about pears\",\"views\":20}",
        },
    );

    const tens = try SDK.dispatch(
        &editor,
        List,
        .{ .type = "post", .filter_field = "views", .filter_value = "10" },
    );
    try std.testing.expectEqual(@as(usize, 1), tens.records.len);
    try std.testing.expectEqualStrings("Ten", tens.records[0].title);

    const pears = try SDK.dispatch(&editor, List, .{ .type = "post", .search = "pears" });
    try std.testing.expectEqual(@as(usize, 1), pears.records.len);
    try std.testing.expectEqualStrings("Twenty", pears.records[0].title);

    const not_filterable = SDK.dispatch(
        &editor,
        List,
        .{ .type = "post", .filter_field = "body", .filter_value = "x" },
    );
    try std.testing.expectError(error.Invalid, not_filterable);
}

test "slug comes from the slug field's source; type update re-indexes existing records" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    const definition =
        \\{"handle":"person","name":"Person","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}},
        \\ {"name":"age","label":"Age","kind":"integer"}]}
    ;
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = definition });

    const ada_document = "{\"name\":\"Ada L.\",\"age\":36}";
    const ada = try SDK.dispatch(&admin, Create, .{ .type = "person", .document = ada_document });
    try std.testing.expectEqualStrings("ada-l", ada.slug.?);

    const explicit = try SDK.dispatch(&admin, Create, .{
        .type = "person",
        .document = "{\"name\":\"Grace\",\"handle\":\"amazing-grace\",\"age\":45}",
    });
    try std.testing.expectEqualStrings("amazing-grace", explicit.slug.?);

    const by_age: List.In = .{ .type = "person", .filter_field = "age", .filter_value = "36" };
    const thirty_six = try SDK.dispatch(&admin, List, by_age);
    try std.testing.expectEqual(@as(usize, 1), thirty_six.records.len);
    try std.testing.expectEqualStrings("Ada L.", thirty_six.records[0].title);

    const widened =
        \\{"handle":"person","name":"Person","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}},
        \\ {"name":"age","label":"Age","kind":"number"}]}
    ;
    const evolved = try SDK.dispatch(
        &admin,
        types.Update,
        .{ .type = "person", .definition = widened },
    );
    try std.testing.expectEqual(@as(u32, 2), evolved.records_rewritten);

    const as_number: List.In = .{ .type = "person", .filter_field = "age", .filter_value = "36" };
    try std.testing.expectEqual(
        @as(usize, 1),
        (try SDK.dispatch(&admin, List, as_number)).records.len,
    );

    const narrowed =
        \\{"handle":"person","name":"Person","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}}]}
    ;
    const refused = SDK.dispatch(
        &admin,
        types.Update,
        .{ .type = "person", .definition = narrowed },
    );
    try std.testing.expectError(error.Conflict, refused);

    const dropped = try SDK.dispatch(&admin, types.Update, .{
        .type = "person",
        .definition = narrowed,
        .drop_content = true,
    });
    try std.testing.expectEqual(@as(u32, 2), dropped.values_dropped);

    const shape =
        \\{"handle":"person","name":"Person","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"reference","options":{"to":["x"]}},
        \\ {"name":"handle","label":"Handle","kind":"slug","options":{"source":"name"}}]}
    ;
    const invalid = SDK.dispatch(&admin, types.Update, .{ .type = "person", .definition = shape });
    try std.testing.expectError(error.Invalid, invalid);
}

test "referrers: reverse index of reference values, filtered by what the caller may read" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .roles = &.{"editor"} } });
    const target = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = example_document },
    );
    const pointing_document = try std.fmt.allocPrint(
        harness.fixed.allocator(),
        "{{\"title\":\"Pointing\",\"body\":\"x\",\"tags\":[\"{s}\"]}}",
        .{target.id},
    );
    const pointing = try SDK.dispatch(
        &editor,
        Create,
        .{ .type = "post", .document = pointing_document },
    );

    const found = try SDK.dispatch(&editor, Referrers, .{ .id = target.id });
    try std.testing.expectEqual(@as(usize, 1), found.referrers.len);
    try std.testing.expectEqualStrings(pointing.id, found.referrers[0].record_id);
    try std.testing.expectEqualStrings("tags", found.referrers[0].field);

    var anon = harness.ctx(.anonymous);
    const hidden = try SDK.dispatch(&anon, Referrers, .{ .id = target.id });
    try std.testing.expectEqual(@as(usize, 0), hidden.referrers.len);
}

test "adding a slug field to a type backfills existing records, duplicates get suffixes" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    const without =
        \\{"handle":"hotel","name":"Hotel","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true}]}
    ;
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition = without });
    const abc: Create.In = .{ .type = "hotel", .document = "{\"name\":\"ABC\"}" };
    const first = try SDK.dispatch(&admin, Create, abc);
    const second = try SDK.dispatch(&admin, Create, abc);
    try std.testing.expect(first.slug == null);

    const with_slug =
        \\{"handle":"hotel","name":"Hotel","title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
    ;
    const updated = try SDK.dispatch(&admin, types.Update, .{
        .type = "hotel",
        .definition = with_slug,
    });
    try std.testing.expectEqual(@as(u32, 2), updated.records_rewritten);

    const one = try SDK.dispatch(&admin, Get, .{ .id = first.id });
    const two = try SDK.dispatch(&admin, Get, .{ .id = second.id });
    const slugs = [_][]const u8{ one.record.slug.?, two.record.slug.? };
    const has_plain = std.mem.eql(u8, slugs[0], "abc") or std.mem.eql(u8, slugs[1], "abc");
    const has_suffixed = std.mem.eql(u8, slugs[0], "abc-2") or std.mem.eql(u8, slugs[1], "abc-2");
    try std.testing.expect(has_plain and has_suffixed);
}

test "terms fields: a type opts into a taxonomy, records file under terms, ancestors count" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    const term_operations = @import("term.zig");
    const unknown_taxonomy = SDK.dispatch(&admin, types.Create, .{ .definition =
        \\{"handle":"article","name":"Article","fields":[
        \\{"name":"title","label":"Title","kind":"string","required":true},
        \\{"name":"topics","label":"Topics","kind":"terms","many":true,
        \\"options":{"taxonomy":"topics"}}]}
    });
    try std.testing.expectError(error.Invalid, unknown_taxonomy);

    _ = try SDK.dispatch(&admin, taxonomies.Create, .{
        .definition = taxonomies.example_definition,
    });
    _ = try SDK.dispatch(&admin, types.Create, .{ .definition =
        \\{"handle":"article","name":"Article","public":true,"fields":[
        \\{"name":"title","label":"Title","kind":"string","required":true},
        \\{"name":"topics","label":"Topics","kind":"terms","many":true,
        \\"options":{"taxonomy":"topics"}}]}
    });
    const tech = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Technology\"}",
        .status = "published",
    });
    const engineering = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Engineering\"}",
        .status = "published",
        .parent = tech.id,
    });
    const art = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Art\"}",
        .status = "published",
    });

    const filed = try std.fmt.allocPrint(
        harness.fixed.allocator(),
        "{{\"title\":\"Filed\",\"topics\":[\"{s}\"]}}",
        .{engineering.id},
    );
    const record = try SDK.dispatch(&admin, Create, .{
        .type = "article",
        .document = filed,
        .status = "published",
    });
    const painted = try std.fmt.allocPrint(
        harness.fixed.allocator(),
        "{{\"title\":\"Painted\",\"topics\":[\"{s}\"]}}",
        .{art.id},
    );
    _ = try SDK.dispatch(&admin, Create, .{
        .type = "article",
        .document = painted,
        .status = "published",
    });

    const under_tech = try SDK.dispatch(&admin, List, .{
        .type = "article",
        .filter_field = "topics",
        .filter_value = tech.id,
    });
    try std.testing.expectEqual(@as(usize, 1), under_tech.records.len);
    try std.testing.expectEqualStrings("Filed", under_tech.records[0].title);
    const under_art = try SDK.dispatch(&admin, List, .{
        .type = "article",
        .filter_field = "topics",
        .filter_value = art.id,
    });
    try std.testing.expectEqual(@as(usize, 1), under_art.records.len);

    const got = try SDK.dispatch(&admin, Get, .{ .id = record.id });
    try std.testing.expect(std.mem.indexOf(u8, got.document, engineering.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, got.document, tech.id) == null);

    const missing = SDK.dispatch(&admin, Create, .{
        .type = "article",
        .document = "{\"title\":\"Lost\",\"topics\":[\"nope\"]}",
    });
    try std.testing.expectError(error.Invalid, missing);
    try std.testing.expectError(
        error.Conflict,
        SDK.dispatch(&admin, term_operations.Purge, .{ .id = tech.id }),
    );

    const moved = try SDK.dispatch(&admin, term_operations.Save, .{
        .id = engineering.id,
        .document = "{\"name\":\"Engineering\"}",
        .parent = art.id,
    });
    try std.testing.expectEqualStrings(art.id, moved.parent.?);
    const under_tech_after = try SDK.dispatch(&admin, List, .{
        .type = "article",
        .filter_field = "topics",
        .filter_value = tech.id,
    });
    try std.testing.expectEqual(@as(usize, 0), under_tech_after.records.len);
    const under_art_after = try SDK.dispatch(&admin, List, .{
        .type = "article",
        .filter_field = "topics",
        .filter_value = art.id,
    });
    try std.testing.expectEqual(@as(usize, 2), under_art_after.records.len);
    const purged = try SDK.dispatch(&admin, term_operations.Purge, .{ .id = tech.id });
    try std.testing.expect(purged.purged);
}

test "a taxonomy applying to a type gives it an implicit terms field; detaching drops values" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try seed_admin_type(&harness);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    const term_operations = @import("term.zig");
    const applying =
        \\{"handle":"topics","name":"Topics","public":true,"title_field":"name",
        \\ "applies_to":["post"],
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true}]}
    ;
    _ = try SDK.dispatch(&admin, taxonomies.Create, .{ .definition = applying });
    const unknown_type = SDK.dispatch(&admin, taxonomies.Create, .{ .definition =
        \\{"handle":"tags","name":"Tags","applies_to":["nope"],
        \\ "fields":[{"name":"name","label":"Name","kind":"string"}]}
    });
    try std.testing.expectError(error.Invalid, unknown_type);

    const post = try SDK.dispatch(&admin, types.Get, .{ .type = "post" });
    const last = post.definition.fields[post.definition.fields.len - 1];
    try std.testing.expectEqualStrings("topics", last.name);
    try std.testing.expect(last.locked and last.many);
    try std.testing.expectEqualStrings("topics", last.options.taxonomy);

    const tech = try SDK.dispatch(&admin, term_operations.Create, .{
        .taxonomy = "topics",
        .document = "{\"name\":\"Technology\"}",
        .status = "published",
    });
    const filed = try std.fmt.allocPrint(
        harness.fixed.allocator(),
        "{{\"title\":\"Filed\",\"body\":\"x\",\"topics\":[\"{s}\"]}}",
        .{tech.id},
    );
    const record = try SDK.dispatch(&admin, Create, .{ .type = "post", .document = filed });
    const got = try SDK.dispatch(&admin, Get, .{ .id = record.id });
    try std.testing.expect(std.mem.indexOf(u8, got.document, tech.id) != null);

    const sent_back = try model.content_type.encode(harness.fixed.allocator(), post.definition);
    const kept = try SDK.dispatch(&admin, types.Update, .{
        .type = "post",
        .definition = sent_back,
    });
    try std.testing.expectEqual(@as(u32, 0), kept.values_dropped);
    const stored = try SDK.dispatch(&admin, types.Get, .{ .type = "post" });
    try std.testing.expectEqual(post.definition.fields.len, stored.definition.fields.len);

    const detached =
        \\{"handle":"topics","name":"Topics","public":true,"title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true}]}
    ;
    _ = try SDK.dispatch(&admin, taxonomies.Update, .{
        .taxonomy = "topics",
        .definition = detached,
    });
    const bare = try SDK.dispatch(&admin, types.Get, .{ .type = "post" });
    try std.testing.expectEqual(post.definition.fields.len - 1, bare.definition.fields.len);
    const after = try SDK.dispatch(&admin, Get, .{ .id = record.id });
    try std.testing.expect(std.mem.indexOf(u8, after.document, tech.id) == null);
    const purged = try SDK.dispatch(&admin, term_operations.Purge, .{ .id = tech.id });
    try std.testing.expect(purged.purged);
}
