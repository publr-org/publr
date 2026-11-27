//! What of a record goes live: the combinations of the site's dimensions it holds back.

const std = @import("std");
const public = @import("../../publr/operations/record/hold_back.zig");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const site_dimensions = @import("../dimensions.zig");
const registry = @import("../../server/registry.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const live = model.dimension.live;

pub const HoldBack = struct {
    pub const shape = public.HoldBack;
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

        if (in.id.len == 0 or in.id.len > 128) {
            return error.Invalid;
        }

        const domain = record_operations.domain;
        const row = try domain.access.load(ctx, in.id, granted) orelse return error.NotFound;

        const held_back = try live.joined(ctx.arena, in.combinations) orelse {
            return error.Invalid;
        };

        for (in.combinations) |combination| {
            const read = model.dimension.parse(combination) orelse return error.Invalid;

            for (read.slice()) |pair| {
                const dimension = site_dimensions.find(ctx, pair.dimension) orelse {
                    return error.Invalid;
                };

                if (!try lists(ctx, dimension, pair.code)) {
                    return error.Invalid;
                }
            }
        }

        const type_row = try domain.definition.find(ctx, row.type_id) orelse return error.NotFound;

        if (!type_row.def.flow.is_live(row.status)) {
            try store.records.hold_back(ctx.db, row.id, held_back, .live);

            return .{
                .held_back = held_back,
                .changed = row.changed,
            };
        }

        return park(ctx, row, type_row.def, held_back);
    }

    /// A live record's: waiting with its pending changes until they are published. With
    /// none yet, the pending copy starts as the live one; back to what is live and with
    /// nothing else changed, nothing waits.
    fn park(
        ctx: *Ctx,
        row: store.records.Record,
        def: model.content_type.Def,
        held_back: []const u8,
    ) Error!Out {
        std.debug.assert(row.id.len > 0);
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const domain = record_operations.domain;
        const values = domain.values;
        const back_to_live = std.mem.eql(u8, held_back, row.held_back);

        if (!row.changed and back_to_live) {
            return .{
                .held_back = held_back,
                .changed = false,
            };
        }

        if (!row.changed) {
            const document = try domain.document.document_of(ctx, row.id, values.live, def);

            try values.write(
                registry.kinds(ctx),
                ctx,
                ctx.db,
                row.id,
                values.pending,
                row.type_id,
                def.fields,
                document,
            );
        }

        const parked: ?[]const u8 = if (back_to_live) null else held_back;
        const settled = back_to_live and try domain.crud.same_as_live(ctx, row.id);

        try store.records.hold_back(ctx.db, row.id, parked, .pending);

        if (settled) {
            try values.clear(ctx.db, row.id, values.pending);
        }

        _ = try store.records.save(ctx.db, row.id, ctx.author(), null, ctx.now_ms, !settled);

        return .{
            .held_back = held_back,
            .changed = !settled,
        };
    }
};

/// Whether `dimension` has a value at `code`.
fn lists(ctx: *Ctx, dimension: site_dimensions.Setting, code: []const u8) Error!bool {
    std.debug.assert(code.len > 0);
    std.debug.assert(dimension.name.len > 0);

    for (try site_dimensions.values_of(ctx, dimension)) |value| {
        if (std.mem.eql(u8, value.code, code)) {
            return true;
        }
    }

    return false;
}
