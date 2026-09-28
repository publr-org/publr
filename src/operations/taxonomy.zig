const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const term = @import("term.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const content_type = model.content_type;
const definition = term.domain.definition;
const definition_module = @import("document/definition.zig");
const Def = content_type.Def;

pub const namespace: sdk.operation.Namespace = .{
    .name = "taxonomy",
    .summary = "Taxonomies: the classifications records are filed under",
    .details =
    \\A taxonomy is the schema of its terms, as a content type is the schema of its
    \\records: a handle, a name, whether it is public, and the fields a term carries
    \\(a name, a slug, a colour, a cover image: any field kind but `terms`). A
    \\`hierarchical` taxonomy lets a term have a parent term; a flat one does not. A
    \\content type opts into a taxonomy with a field of kind `terms` naming it, and
    \\each record then selects terms in that field. Definitions are passed as JSON.
    \\Signed-in users may read taxonomies; changing them needs an admin.
    ,
};

pub const Summary = definition_module.Summary;
pub const Problem = model.field.Problem;
pub const find = definition.find;
pub const visible = definition.visible;
pub const visible_type = definition.visible_type;
pub const brief_of = definition.brief_of;

const new_definition =
    \\{"handle":"regions","name":"Regions","title_field":"name",
    \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true}]}
;
pub const example_definition =
    \\{"handle":"topics","name":"Topics","public":true,"hierarchical":true,
    \\ "title_field":"name",
    \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
    \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
;
const example_id = "d4e5f60718293a4b5c6d7e8f";

pub const Create = struct {
    pub const name = "taxonomy.create";
    pub const description = "Create a taxonomy from a JSON definition";
    pub const details =
        \\Admins only. The definition takes the keys of a content type definition
        \\(`handle`, `name`, `public`, `title_field`, `statuses`, `fields`; see
        \\`content_type create`) plus `hierarchical` (default false: terms may have a
        \\parent term). Its kind is always `record`, it has no `url`, and no field of
        \\kind `terms`. Use `taxonomy validate` to see problems.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { definition: []const u8 };
    pub const Out = struct { id: []const u8, handle: []const u8 };
    pub const example: In = .{ .definition = new_definition };
    pub const example_out: Out = .{ .id = example_id, .handle = "regions" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .definition = "The taxonomy definition as JSON",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The new taxonomy's id",
        .handle = "Its handle",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.definition.len > content_type.definition_bytes_max + 1) {
            return error.Invalid;
        }

        const row = try definition.create(ctx, in.definition);

        return .{ .id = row.id, .handle = row.def.handle };
    }
};

pub const Update = struct {
    pub const name = "taxonomy.update";
    pub const description = "Change a taxonomy's definition; existing terms follow";
    pub const details =
        \\Admins only. Takes the taxonomy by handle or id and the full new definition.
        \\Existing terms follow the change as records follow a content type change: a
        \\removed field is refused while terms hold values for it unless `drop_content`
        \\is true; a field whose kind changes is converted when every value fits. Turning
        \\`hierarchical` off is refused while any term has a parent.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        taxonomy: []const u8,
        definition: []const u8,
        drop_content: bool = false,
    };
    pub const Out = struct {
        id: []const u8,
        handle: []const u8,
        terms_rewritten: u32,
        values_dropped: u32,
    };
    pub const example: In = .{ .taxonomy = "topics", .definition = example_definition };
    pub const example_out: Out = .{
        .id = example_id,
        .handle = "topics",
        .terms_rewritten = 0,
        .values_dropped = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .taxonomy = "Handle or id",
        .definition = "The complete new definition as JSON",
        .drop_content = "Delete the values of fields that the new definition removes",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The taxonomy's id",
        .handle = "Its handle",
        .terms_rewritten = "Terms whose values were converted or re-indexed",
        .values_dropped = "Values deleted for removed fields",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        try refuse_flattening(ctx, in.taxonomy, in.definition);
        try detach(ctx, in.taxonomy, in.definition);

        const updated = try definition.update(ctx, in.taxonomy, in.definition, in.drop_content);

        return .{
            .id = updated.id,
            .handle = updated.handle,
            .terms_rewritten = updated.rewritten,
            .values_dropped = updated.dropped,
        };
    }
};

/// A content type the taxonomy no longer applies to loses its records' terms of it: the
/// values and the memberships, as a removed field loses its values.
fn detach(ctx: *Ctx, handle_or_id: []const u8, text: []const u8) Error!void {
    if (handle_or_id.len > 64 << 10) {
        return error.Invalid;
    }

    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (text.len == 0 or text.len > content_type.definition_bytes_max) {
        return error.Invalid;
    }

    const row = try find(ctx, handle_or_id) orelse return error.NotFound;
    const wanted = try content_type.decode(ctx.arena, text);
    const content_types = @import("content_type.zig");

    for (row.def.applies_to) |handle| {
        if (model.taxonomy.applies(wanted, handle)) {
            continue;
        }

        const detached = try content_types.find_raw(ctx, handle) orelse continue;
        const store = @import("../store.zig");

        _ = try store.values.delete_field(ctx.db, detached.id, row.def.handle);
        _ = try store.record_terms.delete_field(ctx.db, detached.id, row.def.handle);
    }
}

/// A hierarchy is not taken away from terms that use it.
fn refuse_flattening(ctx: *Ctx, handle_or_id: []const u8, text: []const u8) Error!void {
    if (handle_or_id.len > 64 << 10) {
        return error.Invalid;
    }

    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (text.len == 0 or text.len > content_type.definition_bytes_max) {
        return error.Invalid;
    }

    const row = try find(ctx, handle_or_id) orelse return error.NotFound;
    const wanted = try content_type.decode(ctx.arena, text);

    if (row.def.hierarchical and !wanted.hierarchical) {
        if (try term.has_parents(ctx, row.id)) {
            return error.Conflict;
        }
    }
}

pub const Get = struct {
    pub const name = "taxonomy.get";
    pub const description = "Read a taxonomy's full definition";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { taxonomy: []const u8 };
    pub const Out = struct { id: []const u8, definition: Def, created_at: i64, updated_at: i64 };
    pub const example: In = .{ .taxonomy = "topics" };
    pub const example_out: Out = .{
        .id = example_id,
        .definition = model.taxonomy.test_topics,
        .created_at = 1789650000000,
        .updated_at = 1789650000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{ .taxonomy = "Handle or id" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        const row = try definition.get(ctx, granted, in.taxonomy);

        return .{
            .id = row.id,
            .definition = row.def,
            .created_at = row.created_at,
            .updated_at = row.updated_at,
        };
    }
};

pub const List = struct {
    pub const name = "taxonomy.list";
    pub const description = "List taxonomies";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { taxonomies: []const Summary };
    pub const example: In = .{};
    pub const example_out: Out = .{ .taxonomies = &.{.{
        .id = example_id,
        .handle = "topics",
        .name = "Topics",
        .kind = .record,
        .public = true,
        .system = false,
        .owner = "",
        .editor = "form",
        .fields = 2,
    }} };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .taxonomies = "Sorted by name",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(granted.allows());

        return .{ .taxonomies = try definition.list(ctx, granted) };
    }
};

pub const Delete = struct {
    pub const name = "taxonomy.delete";
    pub const description = "Delete a taxonomy; refuses while it has terms unless forced";
    pub const details =
        \\Admins only. With `force`, every term goes too, and with them every assignment
        \\of records to those terms; the records' `terms` fields keep pointing at ids
        \\that no longer exist until the records are saved again.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { taxonomy: []const u8, force: bool = false };
    pub const Out = struct { deleted: bool, terms_removed: u32 };
    pub const example: In = .{ .taxonomy = "tags" };
    pub const example_out: Out = .{ .deleted = true, .terms_removed = 0 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .taxonomy = "Handle or id",
        .force = "Also delete every term of the taxonomy",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        const deleted = try definition.delete(ctx, in.taxonomy, in.force);

        return .{ .deleted = deleted.deleted, .terms_removed = deleted.removed };
    }
};

pub const Validate = struct {
    pub const name = "taxonomy.validate";
    pub const description = "Check a JSON definition and list every problem without saving";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { definition: []const u8 };
    pub const Out = struct { valid: bool, problems: []const Problem };
    pub const example: In = .{
        .definition = "{\"handle\":\"topics\",\"name\":\"Topics\",\"kind\":\"settings\"," ++
            "\"fields\":[]}",
    };
    pub const example_out: Out = .{ .valid = false, .problems = &.{
        .{ .path = "kind", .message = "a taxonomy holds terms: its kind is record" },
    } };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        if (in.definition.len > content_type.definition_bytes_max + 1) {
            return error.Invalid;
        }

        const report = try definition.validate(ctx, in.definition);

        return .{ .valid = report.valid, .problems = report.problems };
    }
};

pub const operations = [_]type{ Create, Update, Get, List, Delete, Validate };

const registry = @import("../app/registry.zig");
const SDK = registry.SDK;

test "taxonomies: admins create, update and delete; editors read; the rules hold" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .role = .admin } });
    var editor = harness.ctx(.{ .user = .{ .id = "u_ed", .role = .editor } });
    var anon = harness.ctx(.anonymous);

    const created = try SDK.dispatch(&admin, Create, .{ .definition = example_definition });
    try std.testing.expectEqualStrings("topics", created.handle);
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&editor, Create, .{ .definition = example_definition }),
    );
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, List, .{}));

    const listed = try SDK.dispatch(&editor, List, .{});
    try std.testing.expectEqual(@as(usize, 1), listed.taxonomies.len);
    try std.testing.expectEqualStrings("Topics", listed.taxonomies[0].name);
    const got = try SDK.dispatch(&editor, Get, .{ .taxonomy = "topics" });
    try std.testing.expect(got.definition.hierarchical);
    try std.testing.expectEqualStrings(created.id, got.id);

    const with_url = try SDK.dispatch(&admin, Validate, Validate.example);
    try std.testing.expect(!with_url.valid);
    const settings_kind = SDK.dispatch(&admin, Create, .{
        .definition = "{\"handle\":\"tags\",\"name\":\"Tags\",\"kind\":\"settings\",\"fields\":[]}",
    });
    try std.testing.expectError(error.Invalid, settings_kind);
    const nested_terms = SDK.dispatch(&admin, Create, .{ .definition =
        \\{"handle":"tags","name":"Tags","fields":[{"name":"topics","label":"Topics",
        \\"kind":"terms","options":{"taxonomy":"topics"}}]}
    });
    try std.testing.expectError(error.Invalid, nested_terms);

    const renamed =
        \\{"handle":"topics","name":"Subjects","public":true,"hierarchical":true,
        \\ "title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
    ;
    const updated = try SDK.dispatch(&admin, Update, .{
        .taxonomy = "topics",
        .definition = renamed,
    });
    try std.testing.expectEqual(@as(u32, 0), updated.terms_rewritten);
    try std.testing.expectEqualStrings(
        "Subjects",
        (try SDK.dispatch(&editor, Get, .{ .taxonomy = created.id })).definition.name,
    );

    const content_types = @import("content_type.zig");
    try std.testing.expectError(
        error.NotFound,
        SDK.dispatch(&editor, content_types.Get, .{ .type = "topics" }),
    );

    try std.testing.expect((try SDK.dispatch(&admin, Delete, .{ .taxonomy = "topics" })).deleted);
    const gone = SDK.dispatch(&editor, Get, .{ .taxonomy = "topics" });
    try std.testing.expectError(error.NotFound, gone);
}
