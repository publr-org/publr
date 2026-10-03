//! Create, get, save, list, referrers and validate: the bodies both domains share.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const access_module = @import("access.zig");
const document_module = @import("document.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Record = store.documents.Record;
const Order = store.documents.Order;
const Value = std.json.Value;

pub const Purpose = enum { delivery, edit };
pub const Problem = document_module.Problem;
pub const Created = struct { id: []const u8, status: []const u8, slug: ?[]const u8, version: i64 };
pub const Got = struct { record: Record, slot: []const u8, document: []const u8 };
pub const Saved = @import("save.zig").Saved;
pub const Referrer = struct { record_id: []const u8, field: []const u8 };
pub const Report = struct { valid: bool, problems: []const Problem };

/// What a list takes, whatever the domain calls its definitions.
pub const ListInput = struct {
    definition: ?[]const u8 = null,
    definitions: []const []const u8 = &.{},
    filters: []const []const u8 = &.{},
    search: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    filter_field: ?[]const u8 = null,
    filter_value: ?[]const u8 = null,
    /// Only these records, by id.
    ids: []const []const u8 = &.{},
    order: Order = .updated_desc,
    limit: u32 = 50,
    offset: u32 = 0,
};

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const values = Domain.values;
        const definitions = Domain.definition;
        const access = Domain.access;
        const document = Domain.document;
        const load = access.load;
        const notice_name = Domain.notice_name;
        const title_of = model.document.title_of;
        const slug_of = model.document.slug_of;

        pub fn create(
            ctx: *Ctx,
            granted: *const Grant,
            definition: []const u8,
            text: []const u8,
            wanted_status: ?[]const u8,
            wanted_app: ?[]const u8,
        ) Error!Created {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (definition.len > 64 << 10) {
                return error.Invalid;
            }

            const app = try app_of(ctx, wanted_app);

            const row = try definitions.find(ctx, definition) orelse return error.NotFound;

            if (!granted.allows_type(row.def.handle)) {
                return error.Denied;
            }

            try Domain.config.check_create(ctx, row);

            const status = wanted_status orelse registry.Statuses.initial().id;
            try access.check_status(row.def, status, granted);

            var parsed = try document.parse_document(ctx, row.def, text, true);
            const title = try title_of(row.def, parsed);
            const def = row.def;
            const slug = try document.unique_slug(ctx, row.id, def, &parsed, title, null, false);

            try document.refuse_taken_values(ctx, row.id, row.def, parsed, null);
            try document.refuse_unpublished_targets(ctx, row.def, parsed);
            try Domain.config.check_document(ctx, row.def, parsed);

            const id = try documents.insert(ctx.db, ctx.io, ctx.arena, .{
                .type_id = row.id,
                .created_by = ctx.caller.user_id(),
                .status = status,
                .app = app,
            }, ctx.now_ms);

            const known = registry.Kinds.all;

            try values.write(known, ctx.db, id, values.live, row.id, def.fields, parsed);
            ctx.notice(notice_name("created"), id);

            if (registry.Statuses.is_live(status)) {
                ctx.notice(notice_name("published"), id);
            }

            return .{ .id = id, .status = status, .slug = slug, .version = 1 };
        }

        /// The app a new document belongs to: the one asked for (empty: the project's own),
        /// else the app the request came through.
        fn app_of(ctx: *const Ctx, wanted: ?[]const u8) Error!?[]const u8 {
            std.debug.assert(ctx.app.len == 0 or model.app.valid_name(ctx.app));

            const app = wanted orelse ctx.app;

            if (app.len == 0) {
                return null;
            }

            if (!model.app.valid_name(app)) {
                return error.Invalid;
            }

            std.debug.assert(app.len <= model.app.name_len_max);

            return app;
        }

        pub fn get(
            ctx: *Ctx,
            granted: *const Grant,
            id: []const u8,
            purpose: Purpose,
            wanted_slot: ?[]const u8,
        ) Error!Got {
            std.debug.assert(granted.allows());

            if (id.len > 64 << 10) {
                return error.Invalid;
            }

            ctx.depend(Domain.depend_prefix, id);
            const record = try load(ctx, id, granted) orelse return error.NotFound;
            const type_row = try definitions.find(ctx, record.type_id) orelse return error.NotFound;
            const slot = try slot_for(ctx, record, purpose, wanted_slot);

            std.debug.assert(slot.len > 0);
            const parsed = try document.document_of(ctx, record.id, slot, type_row.def);
            const text = try std.json.Stringify.valueAlloc(ctx.arena, parsed, .{});
            var shown = record;

            if (!std.mem.eql(u8, slot, values.live)) {
                shown.title = title_of(type_row.def, parsed) catch "";
                shown.slug = slug_of(type_row.def, parsed);
            }

            return .{ .record = shown, .slot = slot, .document = text };
        }

        fn slot_for(
            ctx: *Ctx,
            row: Record,
            purpose: Purpose,
            wanted: ?[]const u8,
        ) Error![]const u8 {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            if (wanted) |slot| {
                if (ctx.caller == .anonymous and !std.mem.eql(u8, slot, values.live)) {
                    return error.NotFound;
                }

                const present = try values.has_slot(ctx.db, row.id, slot);

                return if (present) slot else error.NotFound;
            }

            if (purpose == .edit and row.changed and ctx.caller != .anonymous) {
                return values.pending;
            }

            return values.live;
        }

        pub const save = @import("save.zig").Of(Domain).save;

        pub fn list(ctx: *Ctx, granted: *const Grant, in: ListInput) Error![]const Record {
            if (in.definitions.len > 64 << 10) {
                return error.Invalid;
            }

            std.debug.assert(granted.allows());

            if (in.limit == 0 or in.limit > documents.list_max) {
                return error.Invalid;
            }

            if (in.definitions.len > documents.type_ids_max or in.ids.len > documents.list_max) {
                return error.Invalid;
            }

            const span = try access.visible_types(ctx, granted, in.definition, in.definitions);

            if (in.definition == null and in.definitions.len == 0) {
                ctx.depend("", Domain.namespace ++ "s");
            }

            for (span.briefs) |brief| {
                ctx.depend("type:", brief.handle);
            }

            if (span.briefs.len == 0) {
                return &.{};
            }

            const constraints = try constraints_of(ctx, in.filters);
            var statuses_buffer: [model.status.statuses_max][]const u8 = undefined;
            const query = try query_of(ctx, in, granted, span, constraints, &statuses_buffer);
            const rows = try documents.list(ctx.db, ctx.arena, query);
            var visible: std.ArrayList(Record) = .empty;

            for (rows) |record| {
                const grant_row: sdk.grant.Row = .{
                    .record_id = record.id,
                    .type_id = record.type_id,
                    .status = record.status,
                    .owner_id = record.created_by,
                };

                if (!granted.record_filter.accepts(ctx, grant_row)) {
                    continue;
                }

                ctx.depend(Domain.depend_prefix, record.id);
                try visible.append(ctx.arena, record);
            }

            return visible.items;
        }

        /// Every clause, checked and applied by the filter it names, added up.
        fn constraints_of(ctx: *Ctx, clauses: []const []const u8) Error!model.filter.Constraints {
            std.debug.assert(ctx.now_ms >= 0);

            if (clauses.len > model.filter.filters_max) {
                return error.Invalid;
            }

            const context: model.filter.Context = .{
                .user_id = ctx.caller.user_id(),
                .now_ms = ctx.now_ms,
            };
            const parsed = ctx.arena.alloc(model.filter.Clause, clauses.len) catch {
                return error.OutOfMemory;
            };

            for (clauses, parsed) |text, *clause| {
                clause.* = model.filter.parse_clause(text) orelse return error.Invalid;
            }

            var out: model.filter.Constraints = .{};

            registry.Filters.apply_all(parsed, context, &out) catch return error.Invalid;

            return out;
        }

        /// The store's question, from the input, the constraints and the definitions
        /// the list spans.
        fn query_of(
            ctx: *Ctx,
            in: ListInput,
            granted: *const Grant,
            span: access_module.Span,
            constraints: model.filter.Constraints,
            statuses_buffer: *[model.status.statuses_max][]const u8,
        ) Error!store.documents.Query {
            std.debug.assert(span.briefs.len > 0);
            std.debug.assert(in.limit > 0);

            const type_ids = ctx.arena.alloc([]const u8, span.briefs.len) catch {
                return error.OutOfMemory;
            };

            for (span.briefs, type_ids) |brief, *type_id| {
                type_id.* = brief.id;
            }

            const status = constraints.status;
            const exclude = constraints.status_exclude;

            return .{
                .type_ids = type_ids,
                .statuses = access.allowed_statuses(granted, status, exclude, statuses_buffer),
                .ids_json = if (in.ids.len == 0) null else try sdk.stringify(ctx.arena, in.ids),
                .changed = constraints.changed,
                .search = in.search,
                .filter = try slug_or_filter(span, in),
                .created_by = created_by_of(ctx, granted, constraints.created_by),
                .updated_by = author_of(constraints.updated_by),
                .created_after_ms = constraints.created_after_ms,
                .created_before_ms = constraints.created_before_ms,
                .updated_after_ms = constraints.updated_after_ms,
                .updated_before_ms = constraints.updated_before_ms,
                .app = if (constraints.app) |app| switch (app) {
                    .none => .none,
                    .name => |name| .{ .name = name },
                } else null,
                .order = in.order,
                .limit = in.limit,
                .offset = in.offset,
            };
        }

        /// A grant limited to the caller's own records asks the store for exactly those, so a
        /// limit and an offset count only what the caller may see. Asking for someone else's
        /// still reaches the store and finds nothing the grant lets through.
        fn created_by_of(
            ctx: *const Ctx,
            granted: *const Grant,
            requested: ?model.filter.Author,
        ) ?store.documents.Author {
            std.debug.assert(granted.allows());

            const me = ctx.caller.user_id() orelse return author_of(requested);

            if (!granted.record_filter.flags.own_only) {
                return author_of(requested);
            }

            if (requested) |asked| {
                if (!asked.exclude and !std.mem.eql(u8, asked.id, me)) {
                    return author_of(requested);
                }
            }

            std.debug.assert(me.len > 0);

            return .{ .id = me, .exclude = false };
        }

        fn author_of(author: ?model.filter.Author) ?store.documents.Author {
            std.debug.assert(documents.type_ids_max > 0);

            const wanted = author orelse return null;

            std.debug.assert(wanted.id.len > 0);

            return .{ .id = wanted.id, .exclude = wanted.exclude };
        }

        /// `slug` is a filter on the definition's slug field; it cannot be combined with
        /// another, and neither it nor a field filter has a meaning across definitions.
        fn slug_or_filter(span: access_module.Span, in: ListInput) Error!?store.documents.Filter {
            std.debug.assert(span.briefs.len > 0);
            std.debug.assert(in.limit > 0);

            const def = span.single orelse {
                if (in.slug != null or in.filter_field != null) {
                    return error.Invalid;
                }

                return null;
            };
            const slug = in.slug orelse {
                return document.filter_of(def, in.filter_field, in.filter_value);
            };

            if (slug.len == 0 or in.filter_field != null) {
                return error.Invalid;
            }

            const slug_field = model.document.slug_field_of(def) orelse return error.Invalid;

            return .{ .field = slug_field.name, .text = slug };
        }

        pub fn referrers(ctx: *Ctx, granted: *const Grant, id: []const u8) Error![]const Referrer {
            std.debug.assert(granted.allows());
            std.debug.assert(model.document.rows_max > 0);

            if (id.len == 0 or id.len > 128) {
                return error.Invalid;
            }

            const found = try values.referrers(ctx.db, ctx.arena, id);
            var visible: std.ArrayList(Referrer) = .empty;

            for (found) |item| {
                if (try load(ctx, item.record_id, granted) != null) {
                    const referrer: Referrer = .{
                        .record_id = item.record_id,
                        .field = item.field,
                    };

                    try visible.append(ctx.arena, referrer);
                }
            }

            std.debug.assert(visible.items.len <= found.len);

            return visible.items;
        }

        pub fn validate(
            ctx: *Ctx,
            granted: *const Grant,
            definition: []const u8,
            text: []const u8,
        ) Error!Report {
            if (definition.len > 64 << 10) {
                return error.Invalid;
            }

            std.debug.assert(granted.allows());

            const row = try definitions.find(ctx, definition) orelse return error.NotFound;

            if (!definitions.visible(granted, row.def)) {
                return error.NotFound;
            }

            var problems: model.field.Problems = .{};
            const copy_problems = document_module.copy_problems;
            const parsed = @import("../../lib/json.zig").parse(Value, ctx.arena, text, .{}) catch {
                problems.add("", "document is not valid JSON");

                return .{ .valid = false, .problems = try copy_problems(ctx, &problems) };
            };
            const known = registry.Kinds.all;

            const active = model.field_group.applies(row.def.group, .{
                .destination = if (comptime std.mem.eql(
                    u8,
                    Domain.namespace,
                    "term",
                )) .taxonomy else if (row.def.kind == .settings) .settings else .content,
                .type = row.def.handle,
            });
            var checked: [model.field.fields_max]model.field.Def = undefined;
            model.validate.validate_document(
                known,
                model.field_group.checked_fields(
                    row.def.fields,
                    active,
                    &checked,
                ),
                parsed,
                ctx.now_ms,
                &problems,
            );

            return .{ .valid = problems.is_empty(), .problems = try copy_problems(ctx, &problems) };
        }
    };
}
