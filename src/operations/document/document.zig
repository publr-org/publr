//! A document: parsing and validating it, assembling it from rows, titles and slugs,
//! filters, and keeping the old live copy as a revision.

const std = @import("std");
const currencies = @import("../project/currencies.zig");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const slugs = @import("../../lib/text.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Def = store.definitions.Def;
const Record = store.documents.Record;
const document_rules = model.document;
const Value = std.json.Value;
pub const Problem = model.field.Problem;

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const values = Domain.values;
        const definitions = Domain.definition;

        /// The document text as a validated value; a new document (`fresh`) first takes
        /// the defaults of the fields it leaves out.
        pub fn parse_document(ctx: *Ctx, def: Def, text: []const u8, fresh: bool) Error!Value {
            std.debug.assert(def.fields.len <= model.field.fields_max);
            std.debug.assert(ctx.now_ms >= 0);

            if (text.len == 0 or text.len > documents.document_bytes_max) {
                return error.Invalid;
            }

            var parsed = @import("../../lib/json.zig").parse(
                std.json.Value,
                ctx.arena,
                text,
                .{},
            ) catch {
                return error.Invalid;
            };
            var problems: model.field.Problems = .{};
            const known = registry.Kinds.all;

            if (parsed == .object) {
                try model.normalize.apply(known, def.fields, ctx.arena, &parsed.object);
            }

            if (fresh and parsed == .object) {
                try model.defaults.apply(known, def.fields, ctx.arena, &parsed.object, ctx.now_ms);
            }

            const active = model.field_group.applies(def.group, .{
                .destination = if (comptime std.mem.eql(
                    u8,
                    Domain.namespace,
                    "term",
                )) .taxonomy else if (def.kind == .settings) .settings else .content,
                .type = def.handle,
            });
            var checked: [model.field.fields_max]model.field.Def = undefined;
            model.validate.validate_document(
                known,
                model.field_group.checked_fields(
                    def.fields,
                    active,
                    &checked,
                ),
                parsed,
                ctx.now_ms,
                &problems,
            );

            if (!problems.is_empty()) {
                return error.Invalid;
            }

            try currencies.refuse_others(ctx, def.fields, parsed);

            return parsed;
        }

        pub fn document_of(
            ctx: *Ctx,
            record_id: []const u8,
            slot: []const u8,
            def: Def,
        ) Error!std.json.Value {
            std.debug.assert(record_id.len > 0);
            std.debug.assert(def.fields.len <= model.field.fields_max);

            const rows = try values.read(ctx.db, ctx.arena, record_id, slot);

            return try document_rules.assemble(registry.Kinds.all, ctx.arena, def.fields, rows);
        }

        /// A value of a unique field is held by no other document of the definition:
        /// refused as a conflict when it is. Top-level single text or whole-number fields
        /// only, which is all a unique field can be; a pending copy is checked again when
        /// it goes live.
        pub fn refuse_taken_values(
            ctx: *Ctx,
            type_id: []const u8,
            def: Def,
            document: std.json.Value,
            own_id: ?[]const u8,
        ) Error!void {
            std.debug.assert(type_id.len > 0);
            std.debug.assert(document == .object);

            for (def.fields) |field| {
                if (!field.unique) {
                    continue;
                }

                const value = document.object.get(field.name) orelse continue;
                const name = field.name;
                const holder = switch (value) {
                    .string => |text| if (text.len == 0)
                        null
                    else
                        try values.find_by_text(ctx.db, ctx.arena, type_id, name, text),
                    .integer => |number| try values.find_by_integer(
                        ctx.db,
                        ctx.arena,
                        type_id,
                        name,
                        number,
                    ),
                    else => null,
                };

                if (holder) |other| {
                    if (own_id == null or !std.mem.eql(u8, other, own_id.?)) {
                        return error.Conflict;
                    }
                }
            }
        }

        /// A reference field that takes live documents only refuses a pointer at
        /// anything else.
        pub fn refuse_unpublished_targets(ctx: *Ctx, def: Def, document: Value) Error!void {
            std.debug.assert(document == .object);
            std.debug.assert(def.fields.len <= model.field.fields_max);

            const has_targets = model.field.contains_kind(def.fields, "reference") or
                model.field.contains_kind(def.fields, "user");

            if (!has_targets) {
                return;
            }

            const buffer = try ctx.arena.create([model.document.flat_max]model.document.Flat);
            const flattened = try model.document.flatten(
                registry.Kinds.all,
                def.fields,
                document,
                buffer,
            );

            for (flattened) |item| {
                if (item.column != .ref) {
                    continue;
                }
                const field = model.document.find_path(
                    def.fields,
                    item.field,
                ) orelse return error.Invalid;
                const reference = std.mem.eql(u8, field.kind, "reference");
                const user = std.mem.eql(u8, field.kind, "user");
                if (user or (reference and (field.options.reference.live_only or
                    field.options.reference.public_only)))
                {
                    try refuse_target(ctx, field.*, item.value.text);
                }
            }
        }

        fn refuse_target(ctx: *Ctx, field: model.field.Def, id: []const u8) Error!void {
            if (id.len > model.validate.id_len_max) {
                return error.Invalid;
            }

            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (std.mem.eql(u8, field.kind, "user")) {
                if (try store.users.find_by_id(ctx.db, ctx.arena, id) == null) {
                    return error.Invalid;
                }
                return;
            }

            if (id.len == 0) {
                return;
            }

            const target = try store.records.get(ctx.db, ctx.arena, id) orelse return error.Invalid;

            if (field.options.reference.public_only) {
                const target_type = try store.content_types.get_by_id(
                    ctx.db,
                    ctx.arena,
                    target.type_id,
                ) orelse return error.Invalid;
                if (!target_type.def.public or target_type.def.kind != .record) {
                    return error.Invalid;
                }
            }

            if (field.options.reference.live_only and !registry.Statuses.is_live(target.status)) {
                return error.Invalid;
            }
        }

        /// What purging a document does to the fields that point at it: refused as a
        /// conflict when any of them blocks, else the pointers of the fields that clear
        /// are removed and the rest stay as they are.
        pub fn unlink_or_block(ctx: *Ctx, target_id: []const u8) Error!void {
            std.debug.assert(target_id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const pointing = try values.referrers(ctx.db, ctx.arena, target_id);
            var clears = false;

            for (pointing) |referrer| {
                const source = referrer.record_id;
                const row = try documents.get(ctx.db, ctx.arena, source) orelse continue;
                const type_row = try definitions.find(ctx, row.type_id) orelse continue;
                const fields = type_row.def.fields;
                const field = document_rules.find_path(fields, referrer.field) orelse continue;

                switch (field.options.reference.on_delete) {
                    .block => return error.Conflict,
                    .clear => clears = true,
                    .keep => {},
                }
            }

            if (clears) {
                _ = try values.delete_references(ctx.db, target_id);
            }
        }

        /// The slug for a write: the document's own when set, else the current one on
        /// save, else derived from the slug field's source or the title; suffixed until
        /// unique per definition. Null when the definition has no slug field. Sets it
        /// into the document. A slug locked on publish keeps its current value on a live
        /// document whatever the document says.
        pub fn unique_slug(
            ctx: *Ctx,
            type_id: []const u8,
            def: Def,
            document: *std.json.Value,
            title: []const u8,
            own_id: ?[]const u8,
            live: bool,
        ) Error!?[]const u8 {
            std.debug.assert(document.* == .object);
            std.debug.assert(type_id.len > 0);

            const slug_field = document_rules.slug_field_of(def) orelse return null;
            const given = document.object.get(slug_field.name);
            const locked = live and slug_field.options.slug.lock_on_publish;
            var base: []const u8 = undefined;
            var given_text = false;

            if (locked and try current_slug(ctx, own_id, slug_field.name) != null) {
                const kept = (try current_slug(ctx, own_id, slug_field.name)).?;

                try put_slug(ctx, document, slug_field.name, kept);

                return kept;
            }

            if (given != null and given.? == .string and given.?.string.len > 0) {
                base = given.?.string;
                given_text = true;
            } else if (try current_slug(ctx, own_id, slug_field.name)) |kept| {
                try put_slug(ctx, document, slug_field.name, kept);

                return kept;
            } else {
                const source = document_rules.slug_source(def, slug_field, document.*, title);
                base = try slugs.slugify(ctx.arena, source);
            }

            var candidate = base;
            var attempt: u32 = 1;

            while (attempt <= slugs.attempts_max) : (attempt += 1) {
                const holder = try values.find_by_text(
                    ctx.db,
                    ctx.arena,
                    type_id,
                    slug_field.name,
                    candidate,
                );
                const taken_by_other = holder != null and
                    (own_id == null or !std.mem.eql(u8, holder.?, own_id.?));
                // A slug the site keeps is never anyone's: a derived one is numbered past it
                // (a given one was refused when the document was checked).
                const kept = model.field.options.contains(
                    slug_field.options.slug.reserved,
                    candidate,
                );

                if (!taken_by_other and !kept) {
                    try put_slug(ctx, document, slug_field.name, candidate);

                    return candidate;
                }

                if (given_text and slug_field.options.slug.refuse_taken) {
                    return error.Conflict;
                }

                candidate = try slugs.with_suffix(ctx.arena, base, attempt + 1);
            }

            return error.Conflict;
        }

        fn current_slug(ctx: *Ctx, own_id: ?[]const u8, path: []const u8) Error!?[]const u8 {
            std.debug.assert(path.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            const id = own_id orelse return null;
            const slot = slot_in_use(ctx, id);

            return try values.read_text(ctx.db, ctx.arena, id, slot, path);
        }

        fn put_slug(
            ctx: *Ctx,
            document: *std.json.Value,
            name: []const u8,
            slug: []const u8,
        ) Error!void {
            std.debug.assert(document.* == .object);
            std.debug.assert(slug.len > 0);

            const key = try ctx.arena.dupe(u8, name);

            try document.object.put(ctx.arena, key, .{ .string = slug });
        }

        /// Where a document's edits currently live: its pending copy when one exists,
        /// else live.
        pub fn slot_in_use(ctx: *Ctx, id: []const u8) []const u8 {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            const parked = values.has_slot(ctx.db, id, values.pending) catch false;

            return if (parked) values.pending else values.live;
        }

        /// Keep the live document as a revision before it is replaced.
        pub fn snapshot_live(ctx: *Ctx, row: Record, def: Def) Error!void {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const has_live = try values.has_slot(ctx.db, row.id, values.live);

            if (!has_live) {
                return;
            }

            const document = try document_of(ctx, row.id, values.live, def);
            const text = try std.json.Stringify.valueAlloc(ctx.arena, document, .{});

            _ = try store.snapshots.take(
                ctx.db,
                row.id,
                store.snapshots.revision,
                ctx.now_ms,
                ctx.caller.user_id(),
                text,
            );
        }

        pub fn filter_of(
            def: Def,
            field_name: ?[]const u8,
            value: ?[]const u8,
        ) Error!?store.documents.Filter {
            std.debug.assert(def.fields.len <= model.field.fields_max);
            std.debug.assert(def.handle.len > 0);

            const name = field_name orelse return null;
            const text = value orelse return error.Invalid;
            const found = document_rules.find_path(def.fields, name) orelse return error.Invalid;
            const kind = model.kinds.lookup(registry.Kinds.all, found.kind);

            return switch (model.kinds.column_of(kind.storage)) {
                .text => .{ .field = name, .text = text },
                .ref => .{ .field = name, .ref = text, .membership = kind.has.taxonomy },
                .int => .{
                    .field = name,
                    .int = document_rules.parse_int_like(text) orelse return error.Invalid,
                },
                .real => .{
                    .field = name,
                    .real = std.fmt.parseFloat(f64, text) catch return error.Invalid,
                },
                .long => error.Invalid,
            };
        }
    };
}

pub fn copy_problems(ctx: *Ctx, problems: *const model.field.Problems) Error![]const Problem {
    std.debug.assert(problems.len <= model.field.problems_max);
    std.debug.assert(ctx.now_ms >= 0);

    const copy = try ctx.arena.alloc(Problem, problems.len);

    for (problems.slice(), 0..) |problem, index| {
        copy[index] = .{
            .path = ctx.arena.dupe(u8, problem.path) catch return error.OutOfMemory,
            .message = problem.message,
        };
    }

    return copy;
}
