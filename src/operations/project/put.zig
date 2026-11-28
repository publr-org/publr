//! `project.put`: anything the project stores put exactly as another copy of it keeps it,
//! with its ids.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/project/put.zig");
const store = @import("../../store.zig");
const operation_define = @import("../../publr/plugin/operation_define.zig");
const record_operations = @import("../record.zig");
const term_operations = @import("../term.zig");
const changes = @import("changes.zig");
const media_edit = @import("../media/edit.zig");
const trash = @import("../trash.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const stored_rows = store.stored_rows;
const records = record_operations.domain.lifecycle;
const terms = term_operations.domain.lifecycle;

pub const units_max = public.units_max;

pub const Unit = public.Unit;

pub const Done = public.Done;

pub const Put = struct {
    pub const shape = public.Put;
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
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.units.len > units_max) {
            return error.Invalid;
        }

        const kinds = try ctx.arena.alloc(stored_rows.Kind, in.units.len);
        const befores = try ctx.arena.alloc(Before, in.units.len);
        const results = try ctx.arena.alloc(stored_rows.Put, in.units.len);

        for (in.units, kinds, befores) |unit, *kind_slot, *before| {
            kind_slot.* = try checked(unit);
            before.* = try landing(ctx, kind_slot.*, unit.id);

            // A file removed goes to the trash as `media.delete` puts it there.
            if (before.* == .record and before.record.file != null) {
                if (try removes(ctx.arena, unit.rows.text)) {
                    try media_edit.keep_in_trash(ctx, before.record.file.?);
                }
            }
        }

        for (in.units, kinds, results) |unit, unit_kind, *result| {
            const rows_shape = stored_rows.shape_of(unit_kind);

            result.* = try stored_rows.put(ctx.db, ctx.arena, rows_shape, unit.id, unit.rows.text);
        }

        // Types put in this call are read afresh; everything is in place before anything
        // lands, so a reference to a unit of the same call finds it live.
        ctx.forget_definitions();

        const done = try ctx.arena.alloc(Done, in.units.len);

        for (in.units, kinds, befores, results, done) |unit, unit_kind, before, result, *slot| {
            if (result.outcome != .unchanged) {
                try landed(ctx, unit.id, before);
                try file_landed(ctx, unit.id, before, result.outcome);
            }

            const by_handle = unit_kind == .content_type or unit_kind == .taxonomy;

            slot.* = .{
                .kind = unit.kind,
                .id = unit.id,
                .outcome = @tagName(result.outcome),
                .handle = if (by_handle and result.own.len > 0)
                    try handle_of(ctx.arena, result.own)
                else
                    "",
            };
        }

        return .{
            .put = done,
        };
    }
};

fn checked(unit: Unit) Error!stored_rows.Kind {
    std.debug.assert(units_max > 0);

    if (unit.id.len == 0 or unit.id.len > 256) {
        return error.Invalid;
    }

    return std.meta.stringToEnum(stored_rows.Kind, unit.kind) orelse error.Invalid;
}

const Before = union(enum) {
    none,
    record: Recorded,
    term: ?terms.Before,
    /// The collection the record was in, when it was there.
    internal: ?store.internal_records.Owner,
};

fn landing(ctx: *Ctx, kind: stored_rows.Kind, id: []const u8) Error!Before {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    return switch (kind) {
        .record => .{
            .record = .{
                .was = try records.landing(ctx, id),
                .file = try store.media.get(ctx.db, ctx.arena, id),
            },
        },
        .term => .{
            .term = try terms.landing(ctx, id),
        },
        .internal => .{
            .internal = try store.internal_records.owner_of(ctx.db, ctx.arena, id),
        },
        else => .none,
    };
}

/// What follows a unit written: records and terms land as a person's change; an internal
/// record raises its own keys and every key of its collection where it was and where it is:
/// a move does not say which values it was found by.
fn landed(ctx: *Ctx, id: []const u8, before: Before) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    switch (before) {
        .record => |was| return records.landed(ctx, id, was.was),
        .term => |was| return terms.landed(ctx, id, was),
        .internal => |was| {
            const now = try store.internal_records.owner_of(ctx.db, ctx.arena, id);

            for ([_]?store.internal_records.Owner{ was, now }) |each| {
                const collection = each orelse continue;

                for ([_]?[]const u8{ id, null }) |which| {
                    const plugin = collection.plugin;

                    changes.internal_changed(ctx, plugin, collection.kind, which) catch |err| {
                        if (err == error.OutOfMemory) {
                            return error.OutOfMemory;
                        }

                        ctx.dependency_failure = true;
                    };
                }
            }
        },
        .none => {},
    }
}

/// A record before it is put: as a document, and its row in the media library when it is a
/// file.
const Recorded = struct {
    was: ?records.Before,
    file: ?store.media.Row,
};

/// Whether the rows given remove the record: no row of its own.
fn removes(arena: std.mem.Allocator, rows: []const u8) Error!bool {
    std.debug.assert(rows.len > 0);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, rows, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    const own = parsed.object.get("records") orelse return true;

    return own != .array or own.array.items.len == 0;
}

/// What follows a file's record put: removed, its file set aside in the trash beside the
/// copy kept there; put again, its resized copies made anew (its focal point may have moved),
/// and a file it no longer names gone.
fn file_landed(ctx: *Ctx, id: []const u8, before: Before, outcome: stored_rows.Outcome) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(outcome != .unchanged);

    if (before != .record) {
        return;
    }

    const was = before.record.file orelse {
        return if (outcome == .added) came_back(ctx, id) else {};
    };

    if (outcome == .removed) {
        return trash.set_aside(ctx, was.storage_key);
    }

    const files = ctx.files orelse return;
    const now = try store.media.get(ctx.db, ctx.arena, id);

    files.clear_copies(was.storage_key);

    if (now == null or !std.mem.eql(u8, now.?.storage_key, was.storage_key)) {
        files.remove(.files, was.storage_key);
    }
}

/// A file put back where it had been removed (a removal rolled back): what the trash kept of
/// it goes, since it is in the library again.
fn came_back(ctx: *Ctx, id: []const u8) Error!void {
    std.debug.assert(id.len > 0);

    const now = try store.media.get(ctx.db, ctx.arena, id) orelse return;
    var dropped: u32 = 0;

    while (try store.trash.id_of(ctx.db, ctx.arena, "media", id)) |entry| {
        std.debug.assert(dropped < units_max);

        _ = try store.trash.delete(ctx.db, entry);
        dropped += 1;
    }

    if (dropped > 0) {
        if (ctx.files) |files| files.remove(.trash, now.storage_key);
    }
}

/// A type's or a taxonomy's handle, from its row.
fn handle_of(arena: std.mem.Allocator, own: []const u8) Error![]const u8 {
    std.debug.assert(own.len > 0);

    const Row = struct {
        handle: []const u8,
    };
    const rows = std.json.parseFromSliceLeaky([]const Row, arena, own, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;

    if (rows.len != 1) {
        return error.Invalid;
    }

    return rows[0].handle;
}
