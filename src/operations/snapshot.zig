const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const record = @import("record.zig");
const access = record.access;
const document_module = record.document;
const types = @import("content_type.zig");
const public = @import("../publr/operations/snapshot.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const snapshot = store.snapshots;

const Item = public.Item;

pub const namespace = public.namespace;

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
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max or in.before < 0) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const type_row = try record.domain.definition.find(ctx, row.type) orelse {
            return error.NotFound;
        };
        const rows = try snapshot.page(ctx.db, ctx.arena, row.id, .{
            .kind = in.kind,
            .before = in.before,
            .limit = in.limit,
            .documents = in.documents,
            .title_field = type_row.def.title_field,
        });
        const items = try ctx.arena.alloc(Item, rows.len);

        for (rows, items) |found, *item| {
            item.* = .{
                .seq = found.seq,
                .kind = found.kind,
                .at = found.at,
                .by = found.by,
                .title = found.title,
                .document = if (in.documents) .{
                    .text = try readable(ctx, type_row.def.fields, found.document),
                } else null,
            };
        }

        const full = rows.len == in.limit;

        return .{
            .snapshots = items,
            .next_before = if (full) rows[rows.len - 1].seq else 0,
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.seq < 1) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const type_row = try record.domain.definition.find(ctx, row.type) orelse {
            return error.NotFound;
        };
        const found = try snapshot.get(ctx.db, ctx.arena, row.id, in.seq) orelse {
            return error.NotFound;
        };
        var item = item_of(found);

        item.document = .{
            .text = try readable(ctx, type_row.def.fields, found.document),
        };

        return item;
    }
};

pub const Take = struct {
    pub const shape = public.Take;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.kind.len == 0 or in.kind.len > snapshot.kind_len_max) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const type_row = try types.find(ctx, row.type_id) orelse return error.NotFound;
        const live = store.values.live;
        const document = try document_module.document_of(ctx, row.id, live, type_row.def);
        const text = try std.json.Stringify.valueAlloc(ctx.arena, document, .{});
        const seq = try snapshot.take(
            ctx.db,
            row.id,
            in.kind,
            ctx.now_ms,
            ctx.author(),
            text,
        );

        return .{
            .seq = seq,
        };
    }
};

pub const Restore = struct {
    pub const shape = public.Restore;
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

        if (in.seq < 1) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const found = try snapshot.get(ctx.db, ctx.arena, row.id, in.seq);
        const item = found orelse return error.NotFound;
        const record_operations = @import("record.zig");
        const saved = try registry.SDK.dispatch(ctx, record_operations.Save, .{
            .id = row.id,
            .document = .{
                .text = item.document,
            },
            .expected_version = in.expected_version,
        });

        return .{
            .version = saved.version,
            .changed = saved.changed,
        };
    }
};

pub const Prune = struct {
    pub const shape = public.Prune;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const destroys = shape.destroys;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.kind.len == 0 or in.kind.len > snapshot.kind_len_max) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const removed = try snapshot.prune(ctx.db, row.id, in.kind, in.keep);

        return .{
            .removed = removed,
        };
    }
};

/// A snapshot's document as the caller reads it: a field they may not read left out.
fn readable(ctx: *Ctx, fields: []const model.field.Def, text: []const u8) Error![]const u8 {
    std.debug.assert(fields.len <= model.field.fields_max);

    const visibility = @import("document/visibility.zig");

    if (text.len == 0 or !visibility.any_hidden(fields)) {
        return text;
    }

    var parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, text, .{}) catch {
        return error.Invalid;
    };

    visibility.strip(ctx, fields, &parsed);

    return std.json.Stringify.valueAlloc(ctx.arena, parsed, .{}) catch error.OutOfMemory;
}

fn item_of(row: snapshot.Row) Item {
    std.debug.assert(row.seq >= 1);
    std.debug.assert(row.kind.len > 0);

    return .{
        .seq = row.seq,
        .kind = row.kind,
        .at = row.at,
        .by = row.by,
        .document = .{
            .text = row.document,
        },
    };
}

pub const operations = [_]type{ List, Get, Take, Restore, Prune };
