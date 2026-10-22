//! Create, get, save, list, referrers and validate: the bodies both domains share.

const std = @import("std");
const field_conditions = @import("field_conditions.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const access_module = @import("access.zig");
const document_module = @import("document.zig");
const statuses = @import("../status.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Record = store.documents.Record;
const Order = store.documents.Order;
const Value = std.json.Value;

pub const Purpose = enum { delivery, edit };
pub const Problem = document_module.Problem;
pub const Created = struct {
    id: []const u8,
    status: []const u8,
    slug: ?[]const u8,
    version: i64,
};
pub const Got = struct {
    record: Record,
    slot: []const u8,
    document: []const u8,
};
pub const Saved = @import("save.zig").Saved;
pub const Referrer = struct {
    record_id: []const u8,
    field: []const u8,
};
pub const Report = struct {
    valid: bool,
    problems: []const Problem,
};

/// What a list takes, whatever the domain calls its definitions.
pub const ListInput = struct {
    definition: ?[]const u8 = null,
    definitions: []const []const u8 = &.{},
    filters: []const []const u8 = &.{},
    search: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    filter_field: ?[]const u8 = null,
    filter_value: ?[]const u8 = null,
    /// With `filter_field`: any of these values (references or text).
    filter_values: []const []const u8 = &.{},
    /// Only these records, by id.
    ids: []const []const u8 = &.{},
    /// Never records in these statuses, whatever the filters ask.
    exclude_statuses: []const []const u8 = &.{},
    order: Order = .updated_desc,
    /// Ordered by a field of the one definition instead: `total`, `-total` descending.
    sort: ?[]const u8 = null,
    limit: u32 = 50,
    offset: u32 = 0,
    /// `slug` matches this variant's slug (`slug@pl`) first, the main one when none does.
    variant: []const u8 = "",
};

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const values = Domain.values;
        const definitions = Domain.definition;
        const access = Domain.access;
        const document = Domain.document;
        const load = access.load;
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

            const row = try definitions.find(ctx, definition) orelse return error.NotFound;

            if (!definitions.visible(granted, row.def)) {
                return error.NotFound;
            }

            if (!granted.allows_type(row.def.handle)) {
                return error.Denied;
            }

            const app = try app_of(ctx, row.def, wanted_app);

            try Domain.config.check_create(ctx, row);

            const requests = Domain.lifecycle.requests;
            const initial = row.def.flow.initial().id;
            const wanted = wanted_status orelse initial;
            const held_back = row.def.flow.is_live(wanted) and
                !requests.may_publish(ctx, row.def.handle);

            // A plugin without `.publish` makes it in the first status; a person is refused.
            if (held_back and !plugin_running(ctx)) {
                return error.Denied;
            }

            const status = if (held_back) initial else wanted;

            try access.check_status(row.def, status, granted);

            var parsed = try document.parse_document(ctx, row.def, text, true);
            const title = try document_module.titled(ctx, row.def, parsed);
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

            try values.write(known, ctx, ctx.db, id, values.live, row.id, def.fields, parsed);
            ctx.publishes = ctx.publishes or row.def.flow.is_live(status);

            return .{
                .id = id,
                .status = status,
                .slug = slug,
                .version = 1,
            };
        }

        /// The app a new document of a design type belongs to (each app has its own
        /// templates, patterns and moodboard): the one asked for, else the app the request
        /// came through. A document of any other type has none: its type says where it lives.
        fn app_of(
            ctx: *const Ctx,
            def: model.content_type.Def,
            wanted: ?[]const u8,
        ) Error!?[]const u8 {
            std.debug.assert(ctx.app.len == 0 or model.app.valid_name(ctx.app));
            std.debug.assert(def.handle.len > 0);

            if (!model.design.is_design(def.handle)) {
                const asked = wanted orelse "";

                return if (asked.len == 0) null else error.Invalid;
            }

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

            return .{
                .record = shown,
                .slot = slot,
                .document = text,
            };
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

            std.debug.assert(purpose == .edit or purpose == .delivery);

            if (row.changed and reads_latest(ctx)) {
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
            var query = try query_of(ctx, in, granted, span, constraints, .{
                .known = try statuses.known(ctx),
                .buffer = &statuses_buffer,
            });

            if (query.statuses != null and query.statuses.?.len == 0) {
                return &.{};
            }

            var rows = try documents.list(ctx.db, ctx.arena, query);

            // A record not translated into the variant keeps its main slug there too.
            if (rows.len == 0 and in.slug != null and in.variant.len > 0) {
                const renamed = ctx.arena.dupe(store.documents.Filter, query.filters) catch {
                    return error.OutOfMemory;
                };

                renamed[0].field = model.variant.split(renamed[0].field).name;
                query.filters = renamed;
                rows = try documents.list(ctx.db, ctx.arena, query);
            }

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

        /// How many records the list's conditions keep, its limit and offset aside, before
        /// a grant's own per-record checks.
        pub fn count(ctx: *Ctx, granted: *const Grant, in: ListInput) Error!u32 {
            std.debug.assert(granted.allows());
            std.debug.assert(in.limit > 0);

            if (in.definitions.len > documents.type_ids_max or in.ids.len > documents.list_max) {
                return error.Invalid;
            }

            const span = try access.visible_types(ctx, granted, in.definition, in.definitions);

            if (span.briefs.len == 0) {
                return 0;
            }

            const constraints = try constraints_of(ctx, in.filters);
            var statuses_buffer: [model.status.statuses_max][]const u8 = undefined;
            const query = try query_of(ctx, in, granted, span, constraints, .{
                .known = try statuses.known(ctx),
                .buffer = &statuses_buffer,
            });

            if (query.statuses != null and query.statuses.?.len == 0) {
                return 0;
            }

            return documents.count(ctx.db, ctx.arena, query);
        }

        /// The query a write over every document the conditions keep reads them through, a
        /// part at a time (`documents.matching`); null when the caller sees none of them.
        /// The grant's own per-record checks are the caller's to make on each.
        pub fn matching_query(
            ctx: *Ctx,
            granted: *const Grant,
            in: ListInput,
        ) Error!?store.documents.Query {
            std.debug.assert(granted.allows());
            std.debug.assert(in.limit > 0);

            if (in.definitions.len > documents.type_ids_max) {
                return error.Invalid;
            }

            const span = try access.visible_types(ctx, granted, in.definition, in.definitions);

            if (span.briefs.len == 0) {
                return null;
            }

            const constraints = try constraints_of(ctx, in.filters);
            const statuses_buffer = ctx.arena.create([model.status.statuses_max][]const u8) catch {
                return error.OutOfMemory;
            };
            const known = try statuses.known(ctx);
            var query = try query_of(ctx, in, granted, span, constraints, .{
                .known = known,
                .buffer = statuses_buffer,
            });

            // Records named are found in any status the caller may see, archived or deleted
            // too: someone picked them where they are.
            if (in.ids.len > 0 and constraints.status == null) {
                const split = try live_split(ctx, granted, span, known);

                query.statuses = any_status(granted, .{
                    .live_only = split.live_only,
                    .known = known,
                    .buffer = statuses_buffer,
                }, in.exclude_statuses);
            }

            if (query.statuses != null and query.statuses.?.len == 0) {
                return null;
            }

            return query;
        }

        const AnyStatus = struct {
            /// Every type the query spans is read live only.
            live_only: bool,
            known: []const model.status.Status,
            buffer: *[model.status.statuses_max][]const u8,
        };

        fn any_status(
            granted: *const Grant,
            statuses_in: AnyStatus,
            excluded: []const []const u8,
        ) []const []const u8 {
            std.debug.assert(granted.allows());
            std.debug.assert(statuses_in.known.len <= model.status.statuses_max);

            var kept: u32 = 0;

            for (statuses_in.known) |status| {
                const live_ok = !statuses_in.live_only or status.live;

                if (live_ok and granted.allows_status(status.id)) {
                    statuses_in.buffer[kept] = status.id;
                    kept += 1;
                }
            }

            return without(statuses_in.buffer, kept, excluded);
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
            var parsed: std.ArrayList(model.filter.Clause) = .empty;

            // A clause on the records' own fields is the store's (`field_conditions`).
            for (clauses) |text| {
                if (!field_conditions.is_field(text)) {
                    const clause = model.filter.parse_clause(text) orelse return error.Invalid;

                    parsed.append(ctx.arena, clause) catch return error.OutOfMemory;
                }
            }

            var out: model.filter.Constraints = .{};

            registry.Filters.apply_all(parsed.items, context, &out) catch {
                return error.Invalid;
            };

            return out;
        }

        /// The store's question, from the input, the constraints and the definitions
        /// the list spans.
        fn query_of(
            ctx: *Ctx,
            in: ListInput,
            granted_in: *const Grant,
            span: access_module.Span,
            constraints: model.filter.Constraints,
            listed: access_module.Statuses,
        ) Error!store.documents.Query {
            std.debug.assert(span.briefs.len > 0);
            std.debug.assert(in.limit > 0);

            // Each type by its own grant: drafts where it reads them, live records elsewhere.
            const split = try live_split(ctx, granted_in, span, listed.known);
            var narrowed = granted_in.*;

            narrowed.record_filter.flags.live_only = split.live_only;

            const granted = &narrowed;

            const type_ids = ctx.arena.alloc([]const u8, span.briefs.len) catch {
                return error.OutOfMemory;
            };

            for (span.briefs, type_ids) |brief, *type_id| {
                type_id.* = brief.id;
            }

            const status = constraints.status;
            const exclude = constraints.status_exclude;
            const allowed = access.allowed_statuses(granted, status, exclude, listed);

            return .{
                .type_ids = type_ids,
                .statuses = if (allowed) |kept|
                    without(listed.buffer, @intCast(kept.len), in.exclude_statuses)
                else
                    null,
                .live_type_ids = split.type_ids,
                .live_statuses = split.statuses,
                .ids_json = if (in.ids.len == 0) null else try sdk.stringify(ctx.arena, in.ids),
                .changed = constraints.changed,
                .requested = constraints.requested,
                .search = in.search,
                .filters = try field_conditions.filters_of(
                    ctx.arena,
                    span.single,
                    try slug_or_filter(ctx.arena, span, in),
                    in.filters,
                    ctx.now_ms,
                ),
                .sort = try field_conditions.sort_of(span.single, in.sort),
                .created_by = created_by_of(ctx, granted, constraints.created_by),
                .updated_by = author_of(constraints.updated_by),
                .created_after_ms = constraints.created_after_ms,
                .created_before_ms = constraints.created_before_ms,
                .updated_after_ms = constraints.updated_after_ms,
                .updated_before_ms = constraints.updated_before_ms,
                .app = if (constraints.app) |app| switch (app) {
                    .none => .none,
                    .name => |name| .{
                        .name = name,
                    },
                } else null,
                .latest = reads_latest(ctx),
                .order = in.order,
                .limit = in.limit,
                .offset = in.offset,
            };
        }

        /// Which of the span's types the grant reads live only: every one (`live_only`), or
        /// some, kept to their live statuses while the rest show drafts too.
        const LiveSplit = struct {
            live_only: bool,
            type_ids: []const []const u8 = &.{},
            statuses: []const []const u8 = &.{},
        };

        fn live_split(
            ctx: *Ctx,
            granted: *const Grant,
            span: access_module.Span,
            known: []const model.status.Status,
        ) Error!LiveSplit {
            std.debug.assert(span.briefs.len > 0);
            std.debug.assert(known.len <= model.status.statuses_max);

            var live_types: std.ArrayList([]const u8) = .empty;

            for (span.briefs) |brief| {
                if (granted.live_only_on(brief.handle, brief.public)) {
                    live_types.append(ctx.arena, brief.id) catch return error.OutOfMemory;
                }
            }

            if (live_types.items.len == 0 or live_types.items.len == span.briefs.len) {
                return .{
                    .live_only = live_types.items.len > 0,
                };
            }

            var live: std.ArrayList([]const u8) = .empty;

            for (known) |status| {
                if (status.live and granted.allows_status(status.id)) {
                    live.append(ctx.arena, status.id) catch return error.OutOfMemory;
                }
            }

            return .{
                .live_only = false,
                .type_ids = live_types.items,
                .statuses = live.items,
            };
        }

        /// Whose reads see each record's latest copy (its pending changes, else its live
        /// document): anyone signed in, the admin and the API, unless the read is for a page
        /// drawn for a visitor (`delivery`), which sees live copies only. A preview is not
        /// delivery: it reads the latest.
        pub fn reads_latest(ctx: *const Ctx) bool {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(!(ctx.delivery and ctx.preview));

            return !ctx.delivery and ctx.caller != .anonymous;
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

            return .{
                .id = me,
                .exclude = false,
            };
        }

        fn author_of(author: ?model.filter.Author) ?store.documents.Author {
            std.debug.assert(documents.type_ids_max > 0);

            const wanted = author orelse return null;

            std.debug.assert(wanted.id.len > 0);

            return .{
                .id = wanted.id,
                .exclude = wanted.exclude,
            };
        }

        /// `slug` is a filter on the definition's slug field; it cannot be combined with
        /// another, and neither it nor a field filter has a meaning across definitions.
        fn slug_or_filter(
            arena: std.mem.Allocator,
            span: access_module.Span,
            in: ListInput,
        ) Error!?store.documents.Filter {
            std.debug.assert(span.briefs.len > 0);
            std.debug.assert(in.limit > 0);

            const def = span.single orelse {
                if (in.slug != null or in.filter_field != null) {
                    return error.Invalid;
                }

                return null;
            };

            if (in.filter_values.len > 0) {
                const field = in.filter_field orelse return error.Invalid;

                if (in.filter_value != null or in.slug != null or in.filter_values.len > 1024) {
                    return error.Invalid;
                }

                const given = sdk.stringify(arena, in.filter_values) catch {
                    return error.OutOfMemory;
                };

                return .{
                    .field = field,
                    .operator = .any_of,
                    .values_json = given,
                };
            }

            const slug = in.slug orelse {
                return document.filter_of(def, in.filter_field, in.filter_value);
            };

            if (slug.len == 0 or in.filter_field != null) {
                return error.Invalid;
            }

            const slug_field = model.document.slug_field_of(def) orelse return error.Invalid;
            const varied = in.variant.len > 0 and slug_field.variants;

            return .{
                .field = if (varied)
                    try model.variant.key_of(arena, slug_field.name, in.variant)
                else
                    slug_field.name,
                .text = slug,
            };
        }

        pub fn referrers(ctx: *Ctx, granted: *const Grant, id: []const u8) Error![]const Referrer {
            std.debug.assert(granted.allows());
            std.debug.assert(model.document.rows_max > 0);

            if (id.len == 0 or id.len > 128) {
                return error.Invalid;
            }

            const found = try values.referrers(ctx.db, ctx.arena, id, .live);
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

                return .{
                    .valid = false,
                    .problems = try copy_problems(ctx, &problems),
                };
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
            model.validate.validate_document(
                known,
                try model.field_group.checked_fields(
                    ctx.arena,
                    row.def.fields,
                    active,
                ),
                parsed,
                ctx.now_ms,
                &problems,
            );

            return .{
                .valid = problems.is_empty(),
                .problems = try copy_problems(ctx, &problems),
            };
        }
    };
}

/// The statuses kept in `buffer`, those excluded taken out, in place.
fn without(
    buffer: *[model.status.statuses_max][]const u8,
    kept_len: u32,
    excluded: []const []const u8,
) []const []const u8 {
    std.debug.assert(kept_len <= model.status.statuses_max);
    std.debug.assert(excluded.len <= model.status.statuses_max);

    var len: u32 = 0;

    for (buffer[0..kept_len]) |status| {
        const dropped = for (excluded) |name| {
            if (std.mem.eql(u8, name, status)) {
                break true;
            }
        } else false;

        if (!dropped) {
            buffer[len] = status;
            len += 1;
        }
    }

    return buffer[0..len];
}

/// Whether a plugin's code made the call: an installed plugin, or a compiled-in one's
/// operation, hook or job.
fn plugin_running(ctx: *const Ctx) bool {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(ctx.plugin.len <= 64);

    return ctx.caller == .plugin or ctx.plugin_called;
}
