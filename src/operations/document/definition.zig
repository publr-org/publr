//! The definitions of a domain (content types, taxonomies): find, visibility, and the
//! create/update/get/list/delete/validate bodies. An update makes the existing documents
//! follow the new definition.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const document_module = @import("document.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const content_type = model.content_type;
const evolution = model.evolution;
const Def = store.definitions.Def;
const Row = store.definitions.Row;
const Brief = store.definitions.Brief;

pub const Problem = model.field.Problem;
pub const Summary = struct {
    id: []const u8,
    handle: []const u8,
    name: []const u8,
    kind: content_type.Kind,
    public: bool,
    system: bool,
    owner: []const u8,
    editor: []const u8,
    fields: u32,
};
pub const Updated = struct { id: []const u8, handle: []const u8, rewritten: u32, dropped: u32 };
pub const Deleted = struct { deleted: bool, removed: u32 };
pub const Report = struct { valid: bool, problems: []const Problem };

pub fn Of(comptime Domain: type) type {
    return struct {
        const definitions = Domain.definitions;
        const documents = Domain.documents;
        const values = Domain.values;
        const document = Domain.document;
        const copy_problems = document_module.copy_problems;
        const notice = Domain.config.definition_namespace;

        /// The definition as every reader wants it: with what the domain adds.
        pub fn find(ctx: *Ctx, handle_or_id: []const u8) Error!?Row {
            if (handle_or_id.len > 64 << 10) {
                return error.Invalid;
            }

            std.debug.assert(ctx.now_ms >= 0);

            const row = try find_raw(ctx, handle_or_id) orelse return null;

            return try Domain.config.expand_def(ctx, row);
        }

        /// The definition as stored.
        pub fn find_raw(ctx: *Ctx, handle_or_id: []const u8) Error!?Row {
            if (handle_or_id.len > 64 << 10) {
                return error.Invalid;
            }

            std.debug.assert(ctx.now_ms >= 0);

            if (handle_or_id.len == 0) {
                return null;
            }

            const by_handle = try definitions.get_by_handle(ctx.db, ctx.arena, handle_or_id);

            if (by_handle) |row| {
                return row;
            }

            return definitions.get_by_id(ctx.db, ctx.arena, handle_or_id);
        }

        pub fn visible(granted: *const Grant, def: Def) bool {
            std.debug.assert(granted.allows());
            std.debug.assert(def.handle.len > 0);

            return visible_type(granted, def.handle, def.public, def.owner);
        }

        /// A type in the grant's reach: public when only public ones are, one of its types,
        /// and no plugin's outside its plugins.
        pub fn visible_type(
            granted: *const Grant,
            handle: []const u8,
            public: bool,
            owner: []const u8,
        ) bool {
            std.debug.assert(granted.allows());
            std.debug.assert(handle.len > 0);

            if (granted.record_filter.flags.public_types_only and !public) {
                return false;
            }

            return granted.allows_type(handle) and granted.allows_owner(owner);
        }

        /// A loaded definition as the list sees it.
        pub fn brief_of(row: Row) Brief {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(row.def.fields.len <= model.field.fields_max);

            return .{
                .id = row.id,
                .handle = row.def.handle,
                .name = row.def.name,
                .kind = row.def.kind,
                .public = row.def.public,
                .system = row.def.system,
                .owner = row.def.owner,
                .editor = row.def.editor,
                .fields_len = @intCast(row.def.fields.len),
            };
        }

        pub fn create(ctx: *Ctx, definition: []const u8) Error!Row {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (definition.len > content_type.definition_bytes_max + 1) {
                return error.Invalid;
            }

            const def = try parse_and_validate(ctx, definition);
            const id = try definitions.insert(ctx.db, ctx.arena, def, ctx.now_ms);

            ctx.notice(notice ++ ".created", def.handle);

            return .{ .id = id, .def = def, .created_at = ctx.now_ms, .updated_at = ctx.now_ms };
        }

        pub fn update(
            ctx: *Ctx,
            handle_or_id: []const u8,
            definition: []const u8,
            drop_content: bool,
        ) Error!Updated {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (handle_or_id.len > 64 << 10) {
                return error.Invalid;
            }

            const row = try find_raw(ctx, handle_or_id) orelse return error.NotFound;
            const def = if (row.def.system and ctx.caller != .system)
                try parse_addition(ctx, row.def, definition)
            else
                try parse_and_validate(ctx, definition);
            const known = registry.Kinds.all;
            const plan = try evolution.plan(known, ctx.arena, row.def.fields, def.fields);

            if (!plan.allowed) {
                return error.Invalid;
            }

            var dropped: u32 = 0;

            for (plan.removed) |path| {
                const held = try values.count_field(ctx.db, row.id, path);

                if (held > 0 and !drop_content) {
                    return error.Conflict;
                }

                dropped += try values.delete_field(ctx.db, row.id, path);
            }

            const rewritten = if (plan.needs_rewrite)
                try rewrite_all(ctx, row.id, row.def, def)
            else
                0;
            const filled = try backfill_slugs(ctx, row.id, row.def, def);
            const updated = try definitions.update(ctx.db, ctx.arena, row.id, def, ctx.now_ms);

            std.debug.assert(updated);
            ctx.notice(notice ++ ".updated", def.handle);

            return .{
                .id = row.id,
                .handle = def.handle,
                .rewritten = rewritten + filled,
                .dropped = dropped,
            };
        }

        pub fn get(ctx: *Ctx, granted: *const Grant, handle_or_id: []const u8) Error!Row {
            if (handle_or_id.len > 64 << 10) {
                return error.Invalid;
            }

            std.debug.assert(granted.allows());

            const row = try find(ctx, handle_or_id) orelse return error.NotFound;

            if (!visible(granted, row.def)) {
                return error.NotFound;
            }

            return row;
        }

        pub fn list(ctx: *Ctx, granted: *const Grant) Error![]const Summary {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(granted.allows());

            const briefs = try definitions.list_briefs(ctx.db, ctx.arena);
            var summaries: std.ArrayList(Summary) = .empty;

            for (briefs) |brief| {
                if (!visible_type(granted, brief.handle, brief.public, brief.owner)) {
                    continue;
                }

                try summaries.append(ctx.arena, .{
                    .id = brief.id,
                    .handle = brief.handle,
                    .name = brief.name,
                    .kind = brief.kind,
                    .public = brief.public,
                    .system = brief.system,
                    .owner = brief.owner,
                    .editor = brief.editor,
                    .fields = brief.fields_len,
                });
            }

            std.debug.assert(summaries.items.len <= briefs.len);

            return summaries.items;
        }

        pub fn delete(ctx: *Ctx, handle_or_id: []const u8, force: bool) Error!Deleted {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (handle_or_id.len > 64 << 10) {
                return error.Invalid;
            }

            const row = try find_raw(ctx, handle_or_id) orelse return error.NotFound;

            if (row.def.system and ctx.caller != .system) {
                return error.Denied;
            }

            const held = try documents.count_by_type(ctx.db, row.id);

            if (held > 0 and !force) {
                return error.Conflict;
            }

            const deleted = try definitions.delete(ctx.db, row.id);
            ctx.notice(notice ++ ".deleted", row.def.handle);

            return .{ .deleted = deleted, .removed = held };
        }

        pub fn validate(ctx: *Ctx, definition: []const u8) Error!Report {
            std.debug.assert(ctx.now_ms >= 0);

            if (definition.len > content_type.definition_bytes_max + 1) {
                return error.Invalid;
            }

            var problems: model.field.Problems = .{};
            const def = content_type.decode(ctx.arena, definition) catch {
                problems.add("", "definition is not valid JSON for a definition");

                return .{ .valid = false, .problems = try copy_problems(ctx, &problems) };
            };

            content_type.validate_def(registry.Kinds.all, def, &problems);

            if (!problems.is_empty()) {
                return .{ .valid = false, .problems = try copy_problems(ctx, &problems) };
            }

            check_statuses(def, &problems);
            try Domain.config.check_def(ctx, def, &problems);

            return .{ .valid = problems.is_empty(), .problems = try copy_problems(ctx, &problems) };
        }

        /// A slug field that just appeared: existing documents get theirs from its source
        /// (or the title), unique per definition, in every slot they have.
        fn backfill_slugs(ctx: *Ctx, type_id: []const u8, old: Def, new: Def) Error!u32 {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(type_id.len > 0);

            const slug_field = model.document.slug_field_of(new) orelse return 0;

            if (model.document.slug_field_of(old) != null) {
                return 0;
            }

            var offset: u32 = 0;
            var filled: u32 = 0;

            while (true) {
                const rows = try documents.list(ctx.db, ctx.arena, .{
                    .type_ids = &.{type_id},
                    .order = .created_desc,
                    .limit = documents.list_max,
                    .offset = offset,
                });

                for (rows) |record| {
                    const slots = try values.slots_of(ctx.db, ctx.arena, record.id);

                    for (slots) |slot| {
                        var parsed = try document.document_of(ctx, record.id, slot, new);
                        const title = model.document.title_of(new, parsed) catch continue;
                        const own = record.id;
                        const doc = &parsed;

                        _ = try document.unique_slug(ctx, type_id, new, doc, title, own, false);

                        const known = registry.Kinds.all;

                        const fields = new.fields;

                        try values.write(known, ctx.db, record.id, slot, type_id, fields, parsed);
                    }

                    filled += 1;
                }

                if (rows.len < documents.list_max) {
                    break;
                }

                offset += documents.list_max;
            }

            std.debug.assert(model.field.is_slug(slug_field.kind));

            return filled;
        }

        fn rewrite_all(ctx: *Ctx, type_id: []const u8, old: Def, new: Def) Error!u32 {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(type_id.len > 0);

            var offset: u32 = 0;
            var rewritten: u32 = 0;

            while (true) {
                const rows = try documents.list(ctx.db, ctx.arena, .{
                    .type_ids = &.{type_id},
                    .order = .created_desc,
                    .limit = documents.list_max,
                    .offset = offset,
                });

                for (rows) |row| {
                    const slots = try values.slots_of(ctx.db, ctx.arena, row.id);

                    for (slots) |slot| {
                        try rewrite_slot(ctx, type_id, row.id, slot, old, new);
                    }

                    rewritten += 1;
                }

                if (rows.len < documents.list_max) {
                    return rewritten;
                }

                offset += documents.list_max;
            }
        }

        fn rewrite_slot(
            ctx: *Ctx,
            type_id: []const u8,
            record_id: []const u8,
            slot: []const u8,
            old: Def,
            new: Def,
        ) Error!void {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(slot.len > 0);

            const known = registry.Kinds.all;
            const rows = try values.read(ctx.db, ctx.arena, record_id, slot);
            const parsed = try model.document.assemble(known, ctx.arena, old.fields, rows);
            const converted = evolution.convert_document(
                known,
                ctx.arena,
                old.fields,
                new.fields,
                parsed,
            ) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Conflict,
                };
            };

            try values.write(known, ctx.db, record_id, slot, type_id, new.fields, converted);
        }

        fn parse_and_validate(ctx: *Ctx, definition: []const u8) Error!Def {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(content_type.definition_bytes_max > 0);

            if (definition.len == 0 or definition.len > content_type.definition_bytes_max) {
                return error.Invalid;
            }

            const given = try content_type.decode(ctx.arena, definition);
            const def = try Domain.config.prepare_def(ctx, given);
            var problems: model.field.Problems = .{};

            content_type.validate_def(registry.Kinds.all, def, &problems);

            if (!problems.is_empty()) {
                return error.Invalid;
            }

            check_statuses(def, &problems);
            try Domain.config.check_def(ctx, def, &problems);

            if (ctx.caller != .system) {
                if (def.system or def.owner.len > 0) {
                    problems.add("system", "system definitions are declared in code, not by hand");
                }

                for (def.fields) |candidate| {
                    if (candidate.locked) {
                        problems.add(candidate.name, "locked fields are declared in code");
                    }
                }
            }

            if (!problems.is_empty()) {
                return error.Invalid;
            }

            return def;
        }

        /// A system definition edited by hand: everything declared stays as declared;
        /// only fields added by hand (after the locked ones) may change.
        fn parse_addition(ctx: *Ctx, current: Def, definition: []const u8) Error!Def {
            std.debug.assert(current.system);
            std.debug.assert(ctx.caller != .system);

            if (definition.len == 0 or definition.len > content_type.definition_bytes_max) {
                return error.Invalid;
            }

            const decoded = try content_type.decode(ctx.arena, definition);
            const given = try Domain.config.prepare_def(ctx, decoded);
            const unlocked = @import("../../sdk/plugin/types.zig").unlocked_of(current).len;
            const locked = current.fields.len - unlocked;

            if (given.fields.len < locked) {
                return error.Invalid;
            }

            for (given.fields[locked..]) |candidate| {
                if (candidate.locked) {
                    return error.Invalid;
                }
            }

            var def = current;
            const fields = try ctx.arena.alloc(model.field.Def, given.fields.len);

            @memcpy(fields[0..locked], current.fields[0..locked]);
            @memcpy(fields[locked..], given.fields[locked..]);
            def.fields = fields;
            def.group = given.group;

            var problems: model.field.Problems = .{};

            content_type.validate_def(registry.Kinds.all, def, &problems);

            if (!problems.is_empty()) {
                return error.Invalid;
            }

            try Domain.config.check_def(ctx, def, &problems);

            if (!problems.is_empty()) {
                return error.Invalid;
            }

            return def;
        }

        fn check_statuses(def: Def, problems: *model.field.Problems) void {
            std.debug.assert(registry.Statuses.all.len > 0);
            std.debug.assert(def.statuses.len <= content_type.statuses_max);

            for (def.statuses) |id| {
                if (registry.Statuses.find(id) == null) {
                    problems.add("statuses", "unknown status");
                }
            }
        }
    };
}
