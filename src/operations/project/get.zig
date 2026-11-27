//! `project.get`: anything the project stores read exactly as `project.put` takes it, with
//! its ids, and the ids of everything of a kind.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/project/get.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const stored_rows = store.stored_rows;

pub const Held = public.Held;
pub const Listed = public.Listed;

pub const Get = struct {
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const untrusted_callers = shape.untrusted_callers;
    pub const answer = shape.answer;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(public.listed_max > 0);

        const unit_kind = std.meta.stringToEnum(stored_rows.Kind, in.kind) orelse {
            return error.Invalid;
        };
        const rows_shape = stored_rows.shape_of(unit_kind);

        if (in.ids.len > public.ids_max) {
            return error.Invalid;
        }

        const held = try ctx.arena.alloc(Held, in.ids.len);

        for (in.ids, held) |id, *slot| {
            if (id.len == 0 or id.len > 256) {
                return error.Invalid;
            }

            const rows = try stored_rows.read(ctx.db, ctx.arena, rows_shape, id);
            const handle = try handle_of(ctx.arena, rows_shape, rows);

            slot.* = .{
                .id = id,
                .handle = handle,
                .rows = .{
                    .text = rows,
                },
            };
        }

        if (!in.every) {
            return .{
                .units = held,
            };
        }

        if (in.after.len > 256) {
            return error.Invalid;
        }

        const every = try listed(ctx, rows_shape, in.after);
        const full = every.len == public.listed_max;

        return .{
            .units = held,
            .every = every,
            .next = if (full) every[every.len - 1].id else "",
        };
    }
};

/// A page of every unit's id, after `after`.
fn listed(ctx: *Ctx, rows_shape: stored_rows.Shape, after: []const u8) Error![]const Listed {
    std.debug.assert(rows_shape.own.name.len > 0);
    std.debug.assert(after.len <= 256);

    const found = try stored_rows.list(ctx.db, ctx.arena, rows_shape, after, public.listed_max);
    const out = try ctx.arena.alloc(Listed, found.len);

    for (found, out) |one, *slot| {
        slot.* = .{
            .id = one.id,
            .handle = one.handle,
        };
    }

    std.debug.assert(out.len <= public.listed_max);

    return out;
}

/// A type's or a taxonomy's handle, from its own row in `rows`; empty when it is not there
/// and for any other kind.
fn handle_of(
    arena: std.mem.Allocator,
    rows_shape: stored_rows.Shape,
    rows: []const u8,
) Error![]const u8 {
    std.debug.assert(rows.len > 0);
    std.debug.assert(rows_shape.own.name.len > 0);

    if (!rows_shape.handled) {
        return "";
    }

    const Row = struct {
        handle: []const u8,
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, rows, .{}) catch {
        return error.Invalid;
    };
    const own = parsed.object.get(rows_shape.own.name) orelse return "";

    if (own != .array or own.array.items.len != 1) {
        return "";
    }

    const row = std.json.parseFromValueLeaky(Row, arena, own.array.items[0], .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;

    return row.handle;
}
