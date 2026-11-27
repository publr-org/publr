const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/content_type.zig");
const model = @import("../model.zig");
const record = @import("record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const content_type = model.content_type;
const definition = record.domain.definition;
const definition_module = @import("document/definition.zig");
const Def = content_type.Def;

pub const namespace = public.namespace;

pub const Summary = definition_module.Summary;
pub const Problem = model.field.Problem;
pub const find = definition.find;
pub const find_raw = definition.find_raw;
pub const visible = definition.visible;
pub const visible_type = definition.visible_type;
pub const brief_of = definition.brief_of;

pub const example_definition = public.example_definition;

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

        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        const updated = try definition.update(ctx, in.type, in.definition, in.drop_content);

        return .{
            .id = updated.id,
            .handle = updated.handle,
            .records_rewritten = updated.rewritten,
            .values_dropped = updated.dropped,
        };
    }
};

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
        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        const row = try definition.get(ctx, granted, in.type);

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
            .types = listed.summaries,
            .total = listed.total,
        };
    }
};

pub const Delete = struct {
    pub const shape = public.Delete;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        const deleted = try definition.delete(ctx, in.type, in.force);

        return .{
            .deleted = deleted.deleted,
            .handle = deleted.handle,
            .records_removed = deleted.removed,
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

test "definition input limits are checked before preparation and domain checks" {
    const registry = @import("../server/registry.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var ctx = harness.ctx(.system);
    const field_text = "{\"name\":\"name\",\"label\":\"Name\",\"kind\":\"string\"}";
    const too_many_fields = "{\"handle\":\"bad\",\"name\":\"Bad\",\"fields\":[" ++
        repeated(64, field_text ++ ",") ++ field_text ++ "]}";
    const too_many_statuses = "{\"handle\":\"bad\",\"name\":\"Bad\",\"fields\":[],\"statuses\":[" ++
        repeated(64, "\"draft\",") ++ "\"draft\"]}";

    for ([_][]const u8{ too_many_fields, too_many_statuses }) |input_text| {
        try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&ctx, Create, .{
            .definition = try content_type.read(ctx.arena, input_text),
        }));
        try std.testing.expectEqual(@as(u32, 0), ctx.db.transaction_depth);
    }
}

/// `text` written `count` times over.
inline fn repeated(comptime count: u32, comptime text: []const u8) *const [count * text.len]u8 {
    const copies: [count][text.len]u8 = @splat(text[0..text.len].*);
    return @ptrCast(&copies);
}
