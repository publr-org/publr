//! The definitions of a domain (content types, taxonomies): find, visibility, and the
//! create/update/get/list/delete/validate bodies. An update makes the existing documents
//! follow the new definition.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const document_module = @import("document.zig");
const trash = @import("../trash.zig");

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
    /// The app it lives in; empty for a Global type.
    app: []const u8 = "",
    /// The menu items its list sits under, the first that exists.
    menu_parents: []const []const u8 = &.{},
    /// `.menu = .none`: left out of the menu; its pages still open.
    menu_hidden: bool = false,
    /// Its default view: where its list starts.
    view: content_type.View = .{},
    /// An icon of the set; empty for none.
    icon: []const u8 = "",
};
/// Which page of definitions a list answers.
pub const Window = struct {
    offset: u32 = 0,
    limit: u32 = 50,
};

pub const Listed = struct {
    summaries: []const Summary,
    total: u32,
};

const list_chunk: u32 = 100;
/// The longest name or id a definition has.
const key_len_max: u32 = 256;

fn summary_of(arena: std.mem.Allocator, brief: anytype) Error!Summary {
    std.debug.assert(brief.id.len > 0);
    std.debug.assert(brief.handle.len > 0);

    return .{
        .id = try arena.dupe(u8, brief.id),
        .handle = try arena.dupe(u8, brief.handle),
        .name = try arena.dupe(u8, brief.name),
        .kind = brief.kind,
        .public = brief.public,
        .system = brief.system,
        .owner = try arena.dupe(u8, brief.owner),
        .editor = try arena.dupe(u8, brief.editor),
        .fields = @intCast(brief.fields_len),
        .app = try arena.dupe(u8, brief.app),
        .menu_parents = brief.menu.parents,
        .menu_hidden = brief.menu.hidden,
        .view = brief.view,
        .icon = try arena.dupe(u8, brief.icon),
    };
}

pub const Updated = struct {
    id: []const u8,
    handle: []const u8,
    rewritten: u32,
    dropped: u32,
};
/// What a delete did: whether it went, how many documents went with it, and its trash entry.
pub const Deleted = struct {
    deleted: bool,
    handle: []const u8,
    removed: u32,
    trash: []const u8 = "",
};
pub const Report = struct {
    valid: bool,
    problems: []const Problem,
};

pub fn Of(comptime Domain: type) type {
    return struct {
        const definitions = Domain.definitions;
        const documents = Domain.documents;
        const values = Domain.values;
        const document = Domain.document;
        const copy_problems = document_module.copy_problems;
        const namespace = Domain.config.definition_namespace;

        /// The definition as every reader wants it: with what the domain adds.
        pub fn find(ctx: *Ctx, handle_or_id: []const u8) Error!?Row {
            if (handle_or_id.len > 64 << 10) {
                return error.Invalid;
            }

            std.debug.assert(ctx.now_ms >= 0);

            var key_buffer: [160]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buffer, "{s}:{s}", .{
                Domain.config.noun,
                handle_or_id,
            }) catch "";

            const cache = ctx.definitions orelse return find_uncached(ctx, handle_or_id);
            const arena = cache.arena_for(ctx.arena, ctx.scratch_set_aside) orelse {
                return find_uncached(ctx, handle_or_id);
            };

            if (key.len == 0) {
                return find_uncached(ctx, handle_or_id);
            }

            if (cache.get(arena, key)) |kept| {
                const found: *const Row = @ptrCast(@alignCast(kept));

                return found.*;
            }

            // Decoded into the request's arena, so a page read on the scratch keeps it too.
            var reading = ctx.*;

            reading.arena = arena;
            defer ctx.next_operation_id = reading.next_operation_id;

            const expanded = try find_uncached(&reading, handle_or_id) orelse return null;
            const kept = try arena.create(Row);

            kept.* = expanded;
            cache.put(arena, key, kept);

            return expanded;
        }

        fn find_uncached(ctx: *Ctx, handle_or_id: []const u8) Error!?Row {
            std.debug.assert(handle_or_id.len <= 64 << 10);
            std.debug.assert(ctx.now_ms >= 0);

            const row = try find_raw(ctx, handle_or_id) orelse return null;
            var expanded = try Domain.config.expand_def(ctx, row);
            const added = @import("../status.zig").added_statuses(ctx);
            const handle = expanded.def.handle;

            const flow = expanded.def.flow;

            expanded.def.flow = try model.flow.with_added(ctx.arena, handle, flow, added);
            try resolve_aliases(ctx, &expanded.def.flow);

            return expanded;
        }

        /// A type's statuses standing in for another plugin's (`.alias`) given that one's
        /// meaning, when the site knows it.
        fn resolve_aliases(ctx: *Ctx, flow: *model.flow.Flow) Error!void {
            std.debug.assert(flow.statuses.len <= model.status.statuses_max);
            std.debug.assert(ctx.now_ms >= 0);

            for (flow.statuses) |own| {
                if (own.alias.len > 0) {
                    break;
                }
            } else return;

            const known = try @import("../status.zig").known(ctx);
            const statuses = ctx.arena.dupe(model.status.Status, flow.statuses) catch {
                return error.OutOfMemory;
            };

            for (statuses) |*own| {
                const resolved = @import("../status.zig").find_in(known, own.id) orelse continue;

                own.label = resolved.label;
                own.color = resolved.color;
                own.live = resolved.live;
            }

            flow.statuses = statuses;
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

            return visible_type(granted, brief_of(.{
                .id = def.handle,
                .def = def,
                .created_at = 0,
                .updated_at = 0,
            }));
        }

        /// A type in the grant's reach: public when only public ones are, one of its types,
        /// no plugin's outside its plugins, and living in or shared with the app read for.
        pub fn visible_type(granted: *const Grant, brief: Brief) bool {
            std.debug.assert(granted.allows());
            std.debug.assert(brief.handle.len > 0);

            if (granted.public_only_on(brief.handle) and !brief.public) {
                return false;
            }

            const shared = model.content_type.shared_of(.{
                .handle = brief.handle,
                .name = brief.name,
                .app = brief.app,
                .shared = brief.shared,
                .fields = &.{},
            });

            return granted.allows_type(brief.handle) and granted.allows_owner(brief.owner) and
                granted.allows_placement(brief.app, shared);
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
                .app = row.def.app,
                .shared = row.def.shared,
            };
        }

        pub fn create(ctx: *Ctx, definition: []const u8) Error!Row {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (definition.len > content_type.definition_bytes_max + 1) {
                return error.Invalid;
            }

            const def = try parse_and_validate(ctx, definition);
            const id = try definitions.insert(ctx.db, ctx.arena, def, ctx.now_ms);

            return .{
                .id = id,
                .def = def,
                .created_at = ctx.now_ms,
                .updated_at = ctx.now_ms,
            };
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

            for (plan.unvaried) |path| {
                const held = try values.count_variants(ctx.db, row.id, path);

                if (held > 0 and !drop_content) {
                    return error.Conflict;
                }

                dropped += held;
            }

            const rewritten = if (plan.needs_rewrite)
                try rewrite_all(ctx, row.id, row.def, def)
            else
                0;
            const filled = try backfill_slugs(ctx, row.id, row.def, def);
            const updated = try definitions.update(ctx.db, ctx.arena, row.id, def, ctx.now_ms);

            std.debug.assert(updated);

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

        /// A page of the definitions the caller sees, by name, and how many it sees in all.
        /// Read a chunk at a time into the scratch; only the page is kept.
        pub fn list(ctx: *Ctx, granted: *const Grant, window: Window) Error!Listed {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(granted.allows());

            const scratch = try ctx.scratch();
            var key_name: [key_len_max]u8 = undefined;
            var key_name_len: u32 = 0;
            var key_id: [key_len_max]u8 = undefined;
            var key_id_len: u32 = 0;
            var summaries: std.ArrayList(Summary) = .empty;
            var seen: u32 = 0;

            while (true) {
                const begun = scratch.mark();
                defer scratch.rewind(begun);

                const briefs = try definitions.briefs_after(ctx.db, scratch.allocator(), .{
                    .name = key_name[0..key_name_len],
                    .id = key_id[0..key_id_len],
                }, list_chunk);

                for (briefs) |brief| {
                    if (!visible_type(granted, brief)) {
                        continue;
                    }

                    if (seen >= window.offset and summaries.items.len < window.limit) {
                        try summaries.append(ctx.arena, try summary_of(ctx.arena, brief));
                    }

                    seen += 1;
                }

                if (briefs.len < list_chunk) {
                    break;
                }

                const last = briefs[briefs.len - 1];

                std.debug.assert(last.name.len <= key_len_max and last.id.len <= key_len_max);

                @memcpy(key_name[0..last.name.len], last.name);
                key_name_len = @intCast(last.name.len);
                @memcpy(key_id[0..last.id.len], last.id);
                key_id_len = @intCast(last.id.len);
            }

            return .{
                .summaries = summaries.items,
                .total = seen,
            };
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

            const trash_id = try keep(ctx, row.id, row.def.name, held);

            const deleted = try definitions.delete(ctx.db, row.id);

            return .{
                .deleted = deleted,
                .handle = row.def.handle,
                .removed = held,
                .trash = trash_id,
            };
        }

        /// A copy of the definition and all it holds, kept in the trash before it goes:
        /// its documents with their values and terms, their search text and snapshots, and
        /// its field group.
        fn keep(ctx: *Ctx, id: []const u8, name: []const u8, held: u32) Error![]const u8 {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const types = comptime std.mem.eql(u8, namespace, "content_type");
            const what = if (types) "Content type" else "Taxonomy";
            const holds = if (types) "records" else "terms";
            const label = std.fmt.allocPrint(ctx.arena, "{s} {s}, and its {d} {s}", .{
                what,
                name,
                held,
                holds,
            }) catch return error.OutOfMemory;

            return trash.keep(ctx, .{
                .kind = namespace,
                .key = id,
                .label = label,
                .roots = try roots_of(ctx, id),
            });
        }

        /// What a copy of the definition holds, for a trash entry: its row (its documents,
        /// values and terms follow by key), their search text and snapshots, its field group.
        pub fn roots_of(ctx: *Ctx, id: []const u8) Error![]const store.trash_copy.Root {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const names = definitions.names;
            const key = std.fmt.allocPrint(ctx.arena, "[\"{s}\"]", .{id}) catch {
                return error.OutOfMemory;
            };
            const of_type: store.trash_copy.Root = .{
                .table = names.documents,
                .column = "type_id",
                .keys = key,
            };
            const held_ids = store.trash_copy.keys_of(ctx.db, ctx.arena, of_type, "id") catch {
                return error.Invalid;
            };
            const roots = [_]store.trash_copy.Root{
                .{
                    .table = names.definitions,
                    .column = "id",
                    .keys = key,
                },
                .{
                    .table = names.search,
                    .column = "type_id",
                    .keys = key,
                },
                .{
                    .table = "snapshots",
                    .column = "record",
                    .keys = held_ids,
                },
                .{
                    .table = "field_groups",
                    .column = "owner",
                    .keys = key,
                },
            };

            return ctx.arena.dupe(store.trash_copy.Root, &roots) catch error.OutOfMemory;
        }

        /// Deletes a definition and all it holds, its copy kept by the caller already.
        pub fn drop_kept(ctx: *Ctx, id: []const u8) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            _ = try definitions.delete(ctx.db, id);
        }

        pub fn validate(ctx: *Ctx, definition: []const u8) Error!Report {
            std.debug.assert(ctx.now_ms >= 0);

            if (definition.len > content_type.definition_bytes_max + 1) {
                return error.Invalid;
            }

            var problems: model.field.Problems = .{};
            const def = content_type.decode(ctx.arena, definition) catch {
                problems.add("", "definition is not valid JSON for a definition");

                return .{
                    .valid = false,
                    .problems = try copy_problems(ctx, &problems),
                };
            };

            content_type.validate_def(registry.Kinds.all, def, &problems);

            if (!problems.is_empty()) {
                return .{
                    .valid = false,
                    .problems = try copy_problems(ctx, &problems),
                };
            }

            check_statuses(def, &problems);
            try Domain.config.check_def(ctx, def, &problems);

            return .{
                .valid = problems.is_empty(),
                .problems = try copy_problems(ctx, &problems),
            };
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

                if (def.kind == .media) {
                    problems.add("kind", "media types are declared in code, not by hand");
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
            std.debug.assert(def.handle.len > 0);
            std.debug.assert(def.statuses.len <= content_type.statuses_max);

            for (def.statuses) |id| {
                if (def.flow.find(id) == null) {
                    problems.add("statuses", "unknown status");
                }
            }
        }
    };
}
