const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/taxonomy.zig");
const model = @import("../model.zig");
const term = @import("term.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const content_type = model.content_type;
const definition = term.domain.definition;
const definition_module = @import("document/definition.zig");
const Def = content_type.Def;

pub const namespace = public.namespace;

pub const Summary = definition_module.Summary;
pub const Problem = model.field.Problem;
pub const find = definition.find;
pub const visible = definition.visible;
pub const visible_type = definition.visible_type;
pub const brief_of = definition.brief_of;

pub const example_definition = public.example_definition;

pub const Create = struct {
    pub const shape = public.Create;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const find_words = shape.find_words;
    pub const hint = shape.hint;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const row = try definition.create(ctx, in.definition);

        return .{
            .id = row.id,
            .handle = row.def.handle,
        };
    }
};

pub const Update = struct {
    pub const shape = public.Update;
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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        try refuse_flattening(ctx, in.taxonomy, in.definition);

        const updated = try definition.update(ctx, in.taxonomy, in.definition, in.drop_content);

        return .{
            .id = updated.id,
            .handle = updated.handle,
            .terms_rewritten = updated.rewritten,
            .values_dropped = updated.dropped,
        };
    }
};

/// A hierarchy is not taken away from terms that use it.
fn refuse_flattening(ctx: *Ctx, handle_or_id: []const u8, wanted: Def) Error!void {
    if (handle_or_id.len > 64 << 10) {
        return error.Invalid;
    }

    std.debug.assert(ctx.db.transaction_depth >= 1);

    const row = try find(ctx, handle_or_id) orelse return error.NotFound;

    if (row.def.hierarchical and !wanted.hierarchical) {
        if (try term.has_parents(ctx, row.id)) {
            return error.Conflict;
        }
    }
}

pub const Get = struct {
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const field_docs = shape.field_docs;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(granted.allows());

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const listed = try definition.list(ctx, granted, .{
            .offset = in.offset,
            .limit = in.limit,
        });

        return .{
            .taxonomies = listed.summaries,
            .total = listed.total,
        };
    }
};

pub const Delete = struct {
    pub const shape = public.Delete;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.taxonomy.len > 64 << 10) {
            return error.Invalid;
        }

        const deleted = try definition.delete(ctx, in.taxonomy, in.force);

        return .{
            .deleted = deleted.deleted,
            .handle = deleted.handle,
            .terms_removed = deleted.removed,
            .trash = deleted.trash,
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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        const report = try definition.validate(ctx, in.definition);

        return .{
            .valid = report.valid,
            .problems = report.problems,
        };
    }
};

pub const operations = [_]type{ Create, Update, Get, List, Delete, Validate };

const registry = @import("../server/registry.zig");
const SDK = registry.SDK;

test "taxonomies: admins create, update and delete; editors read; the rules hold" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    var anon = harness.ctx(.anonymous);

    const created = try SDK.dispatch(&admin, Create, .{
        .definition = example_definition,
    });
    try std.testing.expectEqualStrings("topics", created.handle);
    try std.testing.expectError(
        error.Denied,
        SDK.dispatch(&editor, Create, .{
            .definition = example_definition,
        }),
    );
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, List, .{}));

    const listed = try SDK.dispatch(&editor, List, .{});
    try std.testing.expectEqual(@as(usize, 1), listed.taxonomies.len);
    try std.testing.expectEqualStrings("Topics", listed.taxonomies[0].name);
    const read = try SDK.dispatch(&editor, Get, .{
        .taxonomy = "topics",
    });
    try std.testing.expect(read.definition.hierarchical);
    try std.testing.expectEqualStrings(created.id, read.id);

    const with_url = try SDK.dispatch(&admin, Validate, Validate.example);
    try std.testing.expect(!with_url.valid);
    const settings_kind = SDK.dispatch(&admin, Create, .{
        .definition = .{
            .handle = "tags",
            .name = "Tags",
            .kind = .settings,
            .fields = &.{},
        },
    });
    try std.testing.expectError(error.Invalid, settings_kind);
    const nested_terms = SDK.dispatch(&admin, Create, .{
        .definition = try model.content_type.read(
            admin.arena,
            \\{"handle":"tags","name":"Tags","fields":[{"name":"topics","label":"Topics",
            \\"kind":"terms","options":{"taxonomy":"topics"}}]}
            ,
        ),
    });
    try std.testing.expectError(error.Invalid, nested_terms);

    const renamed =
        \\{"handle":"topics","name":"Subjects","public":true,"hierarchical":true,
        \\ "title_field":"name",
        \\ "fields":[{"name":"name","label":"Name","kind":"string","validation":{"required":true}},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
    ;
    const updated = try SDK.dispatch(&admin, Update, .{
        .taxonomy = "topics",
        .definition = try model.content_type.read(admin.arena, renamed),
    });
    try std.testing.expectEqual(@as(u32, 0), updated.terms_rewritten);
    try std.testing.expectEqualStrings(
        "Subjects",
        (try SDK.dispatch(&editor, Get, .{
            .taxonomy = created.id,
        })).definition.name,
    );

    const content_types = @import("content_type.zig");
    try std.testing.expectError(
        error.NotFound,
        registry.SDK.dispatch(&editor, content_types.Get, .{
            .type = "topics",
        }),
    );

    try std.testing.expect((try SDK.dispatch(&admin, Delete, .{
        .taxonomy = "topics",
    })).deleted);
    const gone = SDK.dispatch(&editor, Get, .{
        .taxonomy = "topics",
    });
    try std.testing.expectError(error.NotFound, gone);
}
