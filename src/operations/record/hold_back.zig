//! What of a record goes live: the combinations of the site's dimensions it holds back.

const std = @import("std");
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
    pub const name = "record.hold_back";
    pub const description = "Choose which combinations of a record's dimensions go live";
    pub const details =
        \\Every combination of the site's dimensions a record has (Polish, Polish in
        \\variation B) goes live with it, but the ones it holds back, listed here in place of
        \\the ones before; none puts every one live, and one the site adds later goes live.
        \\Each is a combination of the site's values as a field's key names it: `language=pl`,
        \\`language=pl,variation=b`. Held back where the dimension has pages of its own, the
        \\record is not at that address (not listed, not found); held back where a visitor is
        \\given a value, they read it as if the other dimensions were at their main values. A
        \\value a field must hold is never required where it is held back. A live record's
        \\choice waits with its pending changes (`changed`, `pending_held_back` in
        \\`record get`) until `record publish`, which checks it, or `record discard_changes`;
        \\any other record's takes effect at once (`held_back`, `;` between).
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        combinations: []const []const u8 = &.{},
    };
    pub const Out = struct {
        held_back: []const u8,
        changed: bool,
    };
    pub const example: In = .{
        .id = record_operations.example_draft_id,
        .combinations = &.{"language=pl"},
    };
    pub const example_out: Out = .{
        .held_back = "language=pl",
        .changed = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .combinations = "Each combination held back (`language=pl`); none to put every one live",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .held_back = "What the record holds back once its changes are published, `;` between",
        .changed = "Whether it waits as pending changes: a live record's, until `record publish`",
    };

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
