//! `project.put`: anything the project stores put exactly as another copy of it keeps it,
//! with its ids.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const operation_define = @import("../../sdk/plugin/operation_define.zig");
const record_operations = @import("../record.zig");
const term_operations = @import("../term.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const stored_rows = store.stored_rows;
const records = record_operations.domain.lifecycle;
const terms = term_operations.domain.lifecycle;

/// Units one call puts, at most.
pub const units_max: u32 = 10_000;

/// One thing the project stores: its kind, its id, its rows by table (`{}`: not there).
pub const Unit = struct {
    kind: []const u8,
    id: []const u8,
    rows: []const u8,
};

/// A unit put, and what became of it: `added`, `replaced`, `removed` or `unchanged`.
pub const Done = struct {
    kind: []const u8,
    id: []const u8,
    outcome: []const u8,
    /// A content type's or taxonomy's handle; empty for anything else.
    handle: []const u8 = "",
};

pub const Put = struct {
    pub const name = "project.put";
    pub const description = "Put anything the project stores exactly as another copy of it " ++
        "keeps it, with its ids";
    pub const details =
        \\For plugins that keep copies of a project in step (a rollback, a promotion, a
        \\merge): each unit's stored rows as JSON objects by column, by table, `{}` to
        \\remove it. Kinds and their tables: `record` (`records`, `record_values`,
        \\`record_terms`), `term` (`terms`, `term_values`), `internal` (`internal_records`,
        \\`internal_record_values`), `content_type` and `taxonomy` (its row and its
        \\`field_groups` row), `field_group` (a custom field group, by its handle), `role`
        \\(`roles`, `role_grants`), `user` (`users`, `user_roles`, `user_values`,
        \\`user_search`, `identities`) and `plugin` (an installed plugin's
        \\`sandboxed_plugins` row: its versions and grants, never its files). Ids, versions
        \\and timestamps are kept as given; a BLOB is hex; search text of records and terms
        \\is made again. A unit already as given is not written. Records and terms then land
        \\as a person making the same change would: slugs and unique values free,
        \\references live, the replaced live document kept as a revision, the change's
        \\events raised. A refused check fails the whole call. Only plugins call it
        \\(administrators too); a plugin needs the `project.put` permission. Rows only:
        \\files (plugins' modules, apps, `publr.zon`) are not put.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const untrusted_callers = false;
    pub const answer: ?operation_define.Answer = .plugin_calls;
    pub const open = true;
    pub const In = struct {
        units: []const Unit = &.{},
    };
    pub const Out = struct {
        put: []const Done,
    };
    pub const example: In = .{
        .units = &.{.{
            .kind = "record",
            .id = record_operations.example_draft_id,
            .rows = "{\"records\":[{\"id\":\"c3d4e5f60718293a4b5c6d7e\",\"status\":" ++
                "\"published\"}],\"record_values\":[]}",
        }},
    };
    pub const example_out: Out = .{
        .put = &.{.{
            .kind = "record",
            .id = record_operations.example_draft_id,
            .outcome = "replaced",
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .units = "Each `kind`, `id` and `rows` (its rows by table; `{}` removes it)",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .put = "Each unit's `kind`, `id`, `outcome` (added, replaced, removed or " ++
            "unchanged) and, for a content type or taxonomy, its `handle`",
    };

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
        }

        for (in.units, kinds, results) |unit, unit_kind, *result| {
            const shape = stored_rows.shape_of(unit_kind);

            result.* = try stored_rows.put(ctx.db, ctx.arena, shape, unit.id, unit.rows);
        }

        // Types put in this call are read afresh; everything is in place before anything
        // lands, so a reference to a unit of the same call finds it live.
        ctx.forget_definitions();

        const done = try ctx.arena.alloc(Done, in.units.len);

        for (in.units, kinds, befores, results, done) |unit, unit_kind, before, result, *slot| {
            if (result.outcome != .unchanged) {
                try landed(ctx, unit.id, before);
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
    record: ?records.Before,
    term: ?terms.Before,
};

fn landing(ctx: *Ctx, kind: stored_rows.Kind, id: []const u8) Error!Before {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    return switch (kind) {
        .record => .{
            .record = try records.landing(ctx, id),
        },
        .term => .{
            .term = try terms.landing(ctx, id),
        },
        else => .none,
    };
}

/// What follows a unit written: records and terms land as a person's change.
fn landed(ctx: *Ctx, id: []const u8, before: Before) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    switch (before) {
        .record => |was| return records.landed(ctx, id, was),
        .term => |was| return terms.landed(ctx, id, was),
        .none => {},
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
