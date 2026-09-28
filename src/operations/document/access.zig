//! Which documents a caller may touch: loading one under a grant, and which statuses a
//! caller may use.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../app/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Def = store.definitions.Def;
const Record = store.documents.Record;
const Brief = store.definitions.Brief;

/// The definitions a list spans: the one named, the several named (every one must be
/// readable, or the list is `NotFound`), or, with none named, every readable one that
/// holds regular content.
pub const Span = struct {
    briefs: []const Brief,
    /// The one definition when the list covers exactly one: a slug or a field filter
    /// has a meaning there alone.
    single: ?Def,
};

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const definitions = Domain.definition;

        pub fn load(ctx: *Ctx, id: []const u8, granted: *const Grant) Error!?Record {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.now_ms >= 0);

            if (id.len == 0 or id.len > 128) {
                return null;
            }

            const row = try documents.get(ctx.db, ctx.arena, id);
            const found = row orelse return null;
            const type_row = try definitions.find(ctx, found.type_id) orelse return null;

            if (type_row.def.kind == .settings and ctx.caller.role() == .editor) {
                return error.Denied;
            }

            if (!definitions.visible(granted, type_row.def)) {
                return null;
            }

            const live_only = granted.record_filter.flags.live_only;

            if (live_only and !registry.Statuses.is_live(found.status)) {
                return null;
            }

            if (!granted.allows_status(found.status)) {
                return null;
            }

            const grant_row: sdk.grant.Row = .{
                .record_id = found.id,
                .type_id = found.type_id,
                .status = found.status,
                .owner_id = found.created_by,
            };

            if (!granted.record_filter.accepts(ctx, grant_row)) {
                return null;
            }

            return found;
        }

        pub fn check_status(def: Def, status: []const u8, granted: *const Grant) Error!void {
            std.debug.assert(def.handle.len > 0);

            if (registry.Statuses.find(status) == null) {
                return error.Invalid;
            }

            if (def.statuses.len > 0 and !contains(def.statuses, status)) {
                return error.Invalid;
            }

            if (!granted.allows_status(status)) {
                return error.Denied;
            }

            std.debug.assert(status.len > 0);
        }

        pub fn visible_types(
            ctx: *Ctx,
            granted: *const Grant,
            wanted: ?[]const u8,
            wanted_many: []const []const u8,
        ) Error!Span {
            std.debug.assert(granted.allows());
            std.debug.assert(wanted_many.len <= documents.type_ids_max);

            if (wanted != null and wanted_many.len > 0) {
                return error.Invalid;
            }

            var briefs: std.ArrayList(Brief) = .empty;
            var single: ?Def = null;

            if (wanted != null or wanted_many.len > 0) {
                const named: []const []const u8 = if (wanted) |one| &.{one} else wanted_many;

                for (named) |handle_or_id| {
                    const row = try definitions.find(ctx, handle_or_id) orelse {
                        return error.NotFound;
                    };

                    if (row.def.kind == .settings and ctx.caller.role() == .editor) {
                        return error.Denied;
                    }

                    if (!definitions.visible(granted, row.def)) {
                        return error.NotFound;
                    }

                    briefs.append(ctx.arena, definitions.brief_of(row)) catch {
                        return error.OutOfMemory;
                    };
                    single = if (named.len == 1) row.def else null;
                }

                return .{ .briefs = briefs.items, .single = single };
            }

            for (try Domain.definitions.list_briefs(ctx.db, ctx.arena)) |brief| {
                const listed = brief.kind == .record;

                if (listed and definitions.visible_type(granted, brief.handle, brief.public)) {
                    briefs.append(ctx.arena, brief) catch return error.OutOfMemory;
                }
            }

            if (briefs.items.len == 1) {
                const first = briefs.items[0].id;
                const row = try definitions.find(ctx, first) orelse return error.NotFound;
                single = row.def;
            }

            std.debug.assert((single != null) == (briefs.items.len == 1));

            return .{ .briefs = briefs.items, .single = single };
        }

        /// The statuses a list may show: the one requested, every listed one but the one
        /// requested (`exclude`), or, with none requested, the listed ones; always within
        /// what the grant allows, and live ones only for a caller who sees nothing else.
        pub fn allowed_statuses(
            granted: *const Grant,
            requested: ?[]const u8,
            exclude: bool,
            buffer: *[model.status.statuses_max][]const u8,
        ) ?[]const []const u8 {
            std.debug.assert(granted.allows());
            std.debug.assert(buffer.len == model.status.statuses_max);

            var count: u32 = 0;

            for (registry.Statuses.all) |status| {
                const live_ok = !granted.record_filter.flags.live_only or status.live;
                const requested_ok = if (requested) |wanted|
                    wanted_status(status, wanted, exclude)
                else
                    status.listed;

                if (live_ok and requested_ok and granted.allows_status(status.id)) {
                    buffer[count] = status.id;
                    count += 1;
                }
            }

            return buffer[0..count];
        }
    };
}

/// The status asked for, or, excluding it, any listed status but it.
fn wanted_status(status: model.status.Status, wanted: []const u8, exclude: bool) bool {
    std.debug.assert(status.id.len > 0);
    std.debug.assert(wanted.len > 0);

    const same = std.mem.eql(u8, wanted, status.id);

    return if (exclude) status.listed and !same else same;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(list.len <= model.content_type.statuses_max);
    std.debug.assert(item.len > 0);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}
