//! `publr.record.define(Document, .{ .name, .internal, .fields, .title_field, .public, .roles,
//! .url, .indexed, .scope })`: a plugin's record type from its document struct. Content types and
//! internal records are one list (`.records`); the type says which it is. Its words are its
//! doc comments: the struct's `///` is the type's name and description, each field's its
//! label and help.
const queue = @import("../../sdk/plugin/queue.zig");
const guest = @import("../../sdk/plugin/guest.zig");
const std = @import("std");
const public_operation = @import("../operation.zig");
const behind_of = @import("../../sdk/plugin/context.zig").behind_of;
const content_type = @import("../../model/content_type.zig");
const field_model = @import("../../model/field.zig");
const internal_record = @import("../../model/internal_record.zig");
const record_typed = @import("../../operations/record/typed.zig");
const internal_operations = @import("../operations/internal.zig");
const many_max = internal_operations.many_max;
const plugin_define = @import("define.zig");
const words = @import("words.zig");
const conditions = @import("../../model/conditions.zig");
const record_menu = @import("../../sdk/plugin/record_menu.zig");
const remote_fields = @import("../../sdk/plugin/remote_fields.zig");
const rows_module = @import("../../sdk/plugin/rows.zig");

pub const Scope = enum { project, app };

/// A reference to a record of any type, stored and sent as its id. A field narrows the
/// types with `.options = .{ .to = &.{"products.variant"} }`. As an operation's input core
/// reads it before `run`, and a record holding one reads it back the same way: `type` its
/// type, `value` the record when the caller may read that type (else null), `missing` when
/// the record is gone.
pub const AnyRef = struct {
    id: []const u8,
    type: []const u8 = "",
    /// The record's fields, when the caller may read it: `ref.value.?.as(Tea, arena)`.
    value: ?public_operation.Json = null,
    /// The record it pointed at is gone; the reference stays, marked so.
    missing: bool = false,

    pub const reference = true;
    /// Handed over with what core read for it; JSON writes its id alone.
    pub const publr_form = .lone;

    const Resolved = struct {
        id: []const u8,
        type: []const u8 = "",
        value: ?public_operation.Json = null,
        missing: bool = false,
    };

    /// An id, as callers send and records keep it, or the object core hands on.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!AnyRef {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);

        return jsonParseFromValue(allocator, value, options) catch error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!AnyRef {
        if (source == .string) {
            if (source.string.len == 0) {
                return error.UnexpectedToken;
            }

            return .{
                .id = source.string,
            };
        }

        const resolved = try std.json.innerParseFromValue(Resolved, allocator, source, options);

        if (resolved.id.len == 0) {
            return error.UnexpectedToken;
        }

        return .{
            .id = resolved.id,
            .type = resolved.type,
            .value = resolved.value,
            .missing = resolved.missing,
        };
    }

    /// The id alone, whatever was read: a reference keeps and sends only that.
    pub fn jsonStringify(self: AnyRef, writer: anytype) !void {
        std.debug.assert(self.id.len > 0);

        return writer.write(self.id);
    }

    /// The record `id` names, read as the caller may.
    fn read(ctx: *PluginCtx, id: []const u8) Error!AnyRef {
        std.debug.assert(ctx.now().ms >= 0);

        if (id.len == 0 or id.len > 128) {
            return error.Invalid;
        }

        const reach = try ctx.call(record_operations.Reach, .{
            .id = id,
        });

        // Another plugin's internal record: there, of its type; what it holds is read
        // through `internal.*`.
        if (reach.internal) {
            return .{
                .id = id,
                .type = reach.type,
            };
        }

        const reason = reach.reason orelse {
            // Not published yet, for a caller who reads live records only: its type alone.
            const got = ctx.call(record_operations.Get, .{
                .id = id,
            }) catch |err| switch (err) {
                error.NotFound => return .{
                    .id = id,
                    .type = reach.type,
                },
                else => return err,
            };

            return .{
                .id = id,
                .type = got.record.type,
                .value = got.document,
            };
        };

        return .{
            .id = id,
            .type = reach.type,
            .missing = reason == .deleted,
        };
    }

    /// Every `AnyRef` among `value`'s fields, and in its lists of them, read: an operation's
    /// input before `run`, and a record holding one when it is read back.
    pub fn read_all(ctx: *PluginCtx, value: anytype) Error!void {
        std.debug.assert(ctx.now().ms >= 0);

        inline for (
            comptime std.meta.fieldNames(@TypeOf(value.*)),
            comptime std.meta.fieldTypes(@TypeOf(value.*)),
        ) |field_name, FieldType| {
            if (comptime FieldType == AnyRef) {
                @field(value, field_name) = try read(ctx, @field(value, field_name).id);
            } else if (comptime FieldType == []const AnyRef) {
                const list = @field(value, field_name);
                const loaded = ctx.arena().alloc(AnyRef, list.len) catch return error.OutOfMemory;

                for (list, loaded) |item, *target| {
                    target.* = try read(ctx, item.id);
                }

                @field(value, field_name) = loaded;
            }
        }
    }
};

// Options by name: the compiler finds a name among an enum's tags without reading them.
const Option = enum {
    name,
    internal,
    fields,
    title_field,
    public,
    url,
    indexed,
    scope,
    validate,
    status,
    editor,
    plural_name,
    kind,
    menu,
    data_view,
    append_only,
    expires,
    roles,
    taxonomies,
};

const record_flow = @import("record_flow.zig");
const flow_model = @import("../../model/flow.zig");
const status_module = @import("../../model/status.zig");
const record_operations = @import("../../operations/record.zig");
const mod_reads = @import("../../sdk/plugin/mod_reads.zig");
const PluginCtx = @import("../../sdk/plugin/context.zig").PluginCtx;
const sdk = @import("../../sdk.zig");
const Error = @import("../operation.zig").Error;

/// What one field's declaration may take to evaluate: its overrides, the parts of its options
/// and validation (each a few dozen, nested once), its kind's checks.
pub const field_branches_max: u32 = 600;

/// What one field of `.fields` takes: `publr.field.Overrides`, a group or repeater's own
/// `.fields`, and a dimension's field option by its owner's name.
const Overrides = @import("../field_options.zig").Overrides;

pub fn define(comptime Document: type, comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        std.debug.assert(@typeInfo(Document) == .@"struct");

        for (std.meta.fieldNames(Options)) |given| {
            if (!@hasField(Option, given)) {
                @compileError("record " ++ options.name ++ ": no option `" ++ given ++ "`");
            }
        }

        const full_name = @hasField(Options, "name") and content_type.valid_handle(options.name) and
            std.mem.indexOfScalar(u8, options.name, '.') != null;

        if (!full_name) {
            @compileError("a record needs `.name`, its plugin's name and its own: " ++
                "`.name = \"guestbook.entry\"`");
        }

        const internal = @hasField(Options, "internal") and options.internal;
        const stored = if (internal) own_part(options.name) else options.name;

        if (@hasField(Options, "taxonomies") and internal) {
            @compileError("record " ++ options.name ++ ": `.taxonomies` is for content; an " ++
                "internal record is bookkeeping, filed by its own fields");
        }

        if (@hasField(Options, "expires") and !internal) {
            @compileError("record " ++ options.name ++ ": `.expires` is for internal records " ++
                "(`.internal = true`); content goes to the trash");
        }

        const Kept = Store(Document, stored, internal);

        check_named_fields(Document, options);

        return struct {
            pub const publr_record_definition = true;
            pub const Doc = Document;
            pub const given = options;
            pub const type_name = options.name;
            /// What the record is stored as: a content type by its full name, an internal
            /// collection by its own part (the plugin keeps it).
            pub const stored_name = stored;
            pub const is_internal = internal;
            /// The record's status as its code reads it: its list's, or `.other`.
            pub const Status = record_flow.Held(record_flow.List(options));
            /// One record as read: `{ id, version, status, changed, value }`.
            pub const Held = if (internal) Kept.Item else Content(Document, Status);
            /// An operation input naming one; an internal collection's names it
            /// `internal:<collection>`, read from the plugin's own.
            pub const Ref = record_typed.Ref(
                Document,
                if (internal) record_typed.internal_prefix ++ stored else stored,
            );
            /// Every transition on records of the type, as one hook point.
            pub const any_transition = record_flow.AnyTransition(options.name);
            /// Each transition's own hook point: `Posts.transitions.publish`.
            pub const transitions: record_flow.TransitionHooks(options) = .{};

            /// The record, its pending changes included; not found when it is another type's
            /// or in the trash, unless `.{ .trashed = true }`. Internal records have no trash.
            /// A dimension's read option reads each field in it (`.{ .language = "pl" }`).
            pub fn get(any_ctx: anytype, id: []const u8, get_options: anytype) Error!Held {
                std.debug.assert(options.name.len > 0);

                if (comptime internal) {
                    comptime check_internal_get(options.name, @TypeOf(get_options));

                    // An id comes from the caller's input: an empty one names no record.
                    if (id.len == 0) {
                        return error.NotFound;
                    }

                    return Kept.get(queue.base_of(any_ctx), id);
                }

                return held_of(try get_typed(Kept, any_ctx, id, get_options));
            }

            /// The one record whose unique or indexed `field` holds `value`, or null; two
            /// make a conflict.
            pub fn find_one(
                any_ctx: anytype,
                comptime field: std.meta.FieldEnum(Document),
                value: anytype,
            ) Error!?Held {
                const ctx = queue.base_of(any_ctx);
                const found = try Kept.find_one(ctx, @tagName(field), value) orelse return null;

                std.debug.assert(found.id.len > 0);

                return if (comptime internal) found else held_of(found);
            }

            /// A walk over every record whose indexed `field` holds `value`, the oldest first:
            /// `while (try lines.next()) |line|`, a page held at a time however many there are
            /// (`publr.Rows`). `.newest()`, `.first(n)`, `.as(Wanted)` shape it before the
            /// first row; `.count()`, `.any()`, `.one()` answer without walking. Internal
            /// records only.
            pub fn where(
                any_ctx: anytype,
                comptime field: std.meta.FieldEnum(Document),
                value: anytype,
            ) Walk(Document) {
                comptime if (!internal) {
                    @compileError("record " ++ options.name ++ ": `where` walks internal " ++
                        "records; content is read with a query");
                };

                return .{
                    .ctx = queue.base_of(any_ctx),
                    .field = @tagName(field),
                    .value = filter_of(value),
                };
            }

            /// A walk over every record of the type, the oldest first: `where` with no
            /// field. Internal records only.
            pub fn all(any_ctx: anytype) Walk(Document) {
                comptime if (!internal) {
                    @compileError("record " ++ options.name ++ ": `all` walks internal " ++
                        "records; content is read with a query");
                };

                return .{
                    .ctx = queue.base_of(any_ctx),
                    .field = null,
                    .value = null,
                };
            }

            /// A walk whose rows hold the fields `Wanted` names.
            pub fn Walk(comptime Wanted: type) type {
                return rows_module.Rows(Document, stored, Wanted);
            }

            /// A page of the records whose indexed `field` holds `value`: `which` says how
            /// many (50, at most 200), from where, and from which end
            /// (`.{ .limit = 10, .oldest = true }`). Internal records only.
            pub fn page(
                any_ctx: anytype,
                comptime field: std.meta.FieldEnum(Document),
                value: anytype,
                which: Page,
            ) Error![]const Kept.Found {
                const ctx = queue.base_of(any_ctx);
                const text = try filter_text(ctx, value);

                comptime std.debug.assert(internal);

                return Kept.page_of(ctx, Document, @tagName(field), text, which);
            }

            /// `page`, each record with only the fields `Wanted` names: a struct of some of
            /// the document's fields, so a list that shows two fields reads two.
            pub fn page_of(
                any_ctx: anytype,
                comptime Wanted: type,
                comptime field: std.meta.FieldEnum(Document),
                value: anytype,
                which: Page,
            ) Error![]const Kept.FoundOf(Wanted) {
                const ctx = queue.base_of(any_ctx);
                const text = try filter_text(ctx, value);

                comptime std.debug.assert(internal);

                return Kept.page_of(ctx, Wanted, @tagName(field), text, which);
            }

            /// Writes the fields `changes` names onto the record `held` read; the others keep
            /// what they hold. A conflict only when one of those fields changed since `held`
            /// was read; another field's change is kept. Never changes status.
            pub fn save(any_ctx: anytype, held: Held, changes: anytype) Error!void {
                const ctx = queue.base_of(any_ctx);

                comptime check_changes(Document, options.name, @TypeOf(changes));
                std.debug.assert(held.id.len > 0);

                const now = try Kept.get(ctx, held.id);

                inline for (comptime std.meta.fieldNames(@TypeOf(changes))) |field| {
                    const was = @field(held.value, field);
                    const is = @field(now.value, field);

                    if (!try same(ctx, was, is)) {
                        return error.Conflict;
                    }
                }

                try Kept.save(ctx, held.id, changes);
            }

            /// Several records by id; one the caller cannot read, or in the trash, is left
            /// out, so the answer may be shorter and is in no promised order.
            pub fn many(any_ctx: anytype, ids: []const []const u8) Error![]const Held {
                const ctx = queue.base_of(any_ctx);
                const items = try Kept.many(ctx, ids);

                std.debug.assert(items.len <= ids.len);

                if (comptime internal) {
                    return items;
                }

                var found: std.ArrayList(Held) = .empty;

                for (items) |item| {
                    if (!std.mem.eql(u8, item.status, "trashed")) {
                        found.append(ctx.arena(), held_of(item)) catch return error.OutOfMemory;
                    }
                }

                return found.items;
            }

            fn held_of(item: Kept.Item) Held {
                std.debug.assert(item.id.len > 0);
                std.debug.assert(item.status.len > 0);

                return .{
                    .id = item.id,
                    .version = item.version,
                    .status = record_flow.held_status(
                        record_flow.List(options),
                        options.name,
                        item.status,
                    ),
                    .changed = item.changed,
                    .value = item.value,
                };
            }

            /// A new record, in its flow's starting status; its id.
            pub fn create(any_ctx: anytype, value: Document) Error![]const u8 {
                std.debug.assert(options.name.len > 0);

                return Kept.create(queue.base_of(any_ctx), value);
            }

            /// Many new internal records at once, in as few calls as the pages they fill:
            /// their ids, in order.
            pub fn create_many(
                any_ctx: anytype,
                values: []const Document,
            ) Error![]const []const u8 {
                comptime if (!internal) {
                    @compileError("record " ++ options.name ++
                        ": `create_many` keeps internal records");
                };

                return Kept.create_many(queue.base_of(any_ctx), values);
            }

            /// Empties optional fields of an internal record:
            /// `Visits.clear(ctx, held, .{ .note, .seen_at })`. Each holds nothing afterwards;
            /// the other fields keep theirs. `save` never does this: a field it gives as
            /// `null` is left as it was.
            pub fn clear(any_ctx: anytype, held: Held, comptime fields: anytype) Error!void {
                comptime if (!internal) {
                    @compileError("record " ++ options.name ++
                        ": `clear` empties fields of internal records");
                };
                std.debug.assert(held.id.len > 0);

                return Kept.clear(queue.base_of(any_ctx), held.id, fields);
            }

            /// Writes each of `changes` onto the record of the same place in `ids`, in as few
            /// calls as the pages they fill; the other fields keep theirs. No stale check:
            /// for records this write's own code just read or made.
            pub fn save_many(
                any_ctx: anytype,
                ids: []const []const u8,
                changes: anytype,
            ) Error!void {
                comptime if (!internal) {
                    @compileError("record " ++ options.name ++
                        ": `save_many` writes internal records");
                };

                return Kept.save_many(queue.base_of(any_ctx), ids, changes);
            }

            /// Erases an internal record for good; content leaves by the `trash` transition.
            pub fn delete(any_ctx: anytype, held: Held) Error!void {
                comptime if (!internal) {
                    @compileError("record " ++ options.name ++ ": content is never deleted; " ++
                        "`transition(ctx, held, .trash)`");
                };
                std.debug.assert(held.id.len > 0);

                try Kept.delete(queue.base_of(any_ctx), held.id);
            }

            /// Moves the record by one of its flow's transitions, named: `.publish` (a name
            /// not in the flow fails the build). Refused unless the record is in one of the
            /// transition's `from` statuses, which also catches a record moved since `held`
            /// was read, and the caller passes its `.authorize`. `.pending` when the caller
            /// may only draft: a person makes the transition later.
            pub fn transition(
                any_ctx: anytype,
                held: Held,
                comptime named: @TypeOf(.enum_literal),
            ) Error!Transitioned {
                comptime record_flow.check_named(options, @tagName(named));
                comptime std.debug.assert(!internal);

                return transition_of(any_ctx, held.id, @tagName(named), type_name);
            }

            /// `transition` at a moment, made then as the person behind the call, with the
            /// rights they hold then: `Posts.record.transition_at(ctx, post, .publish, at)`.
            /// Each its own entry, beside any scheduled before. Refused without a person
            /// behind it.
            pub fn transition_at(
                any_ctx: anytype,
                held: Held,
                comptime named: @TypeOf(.enum_literal),
                at: words.Time,
            ) Error!void {
                const ctx = queue.base_of(any_ctx);

                comptime record_flow.check_named(options, @tagName(named));
                comptime std.debug.assert(!internal);
                std.debug.assert(held.id.len > 0);

                _ = try ctx.call(record_operations.TransitionAt, .{
                    .id = held.id,
                    .transition = @tagName(named),
                    .at = at.ms,
                });
            }
        };
    }
}

/// A stored record type's reads and writes, as ordinary operations through `ctx.call`, so a
/// native and an installed plugin take the same path and checks: content through `record.*`
/// (`name` its type), internal records through `internal.*` (`name` its collection). Reads
/// ignore fields `Document` does not name; a save writes only the fields it is given. Content
/// starts in its flow's start.
pub fn Store(
    comptime Document: type,
    comptime name: []const u8,
    comptime internal: bool,
) type {
    comptime std.debug.assert(@typeInfo(Document) == .@"struct");
    comptime std.debug.assert(name.len > 0);

    return struct {
        /// One record as stored: content also has its status, as text, and whether it has
        /// pending changes.
        pub const Item = if (internal) struct {
            id: []const u8,
            version: i64,
            value: Document,
        } else struct {
            id: []const u8,
            version: i64,
            status: []const u8,
            changed: bool,
            value: Document,
        };

        /// A record as the host lays it out in an installed plugin's own layout: its document
        /// read by the host, once, never as text here.
        const Shaped = struct {
            id: []const u8,
            version: i64,
            created_at: i64 = 0,
            document: Document,
        };

        const ShapedRow = struct {
            id: []const u8,
            type: []const u8,
            version: i64,
            status: []const u8,
            changed: bool,
        };

        /// Whether reads come laid out by the host: an installed plugin's.
        const shaped = guest.mode == .sandboxed;

        fn shaped_item(ctx: *PluginCtx, got: Shaped) Error!Item {
            var value = got.document;

            std.debug.assert(got.id.len > 0);

            try AnyRef.read_all(ctx, &value);

            return .{
                .id = got.id,
                .version = got.version,
                .value = value,
            };
        }

        fn shaped_content(ctx: *PluginCtx, row: ShapedRow, document: Document) Error!Item {
            var value = document;

            std.debug.assert(row.id.len > 0);

            try AnyRef.read_all(ctx, &value);

            return .{
                .id = row.id,
                .version = row.version,
                .status = row.status,
                .changed = row.changed,
                .value = value,
            };
        }

        /// A content record laid out by the host, its document read there.
        fn shaped_get(ctx: *PluginCtx, id: []const u8, pairs: []const Pair) Error!Item {
            const Got = struct {
                record: ShapedRow,
                document: Document,
            };
            const asked: record_operations.Get.In = .{
                .id = id,
                .type = name,
                .purpose = .edit,
                .dimensions = .{
                    .pairs = pairs,
                },
            };
            const got = try behind_of(ctx).read_shaped(
                record_operations.Get.In,
                Got,
                record_operations.Get.name,
                &asked,
            );

            std.debug.assert(id.len > 0);

            if (!std.mem.eql(u8, got.record.type, name)) {
                return error.NotFound;
            }

            return shaped_content(ctx, got.record, got.document);
        }

        /// Content records by id laid out by the host, their documents read there.
        fn shaped_many(ctx: *PluginCtx, ids: []const []const u8) Error![]const Item {
            return shaped_listed(ctx, ids, .delivery);
        }

        /// `shaped_many`, for `purpose`: `.edit` reads a record's pending changes, as `get`.
        fn shaped_listed(
            ctx: *PluginCtx,
            ids: []const []const u8,
            purpose: record_operations.Purpose,
        ) Error![]const Item {
            std.debug.assert(ids.len <= record_operations.list_max);

            const Listed = struct {
                records: []const ShapedRow,
                documents: []const Document,
            };
            const asked: record_operations.List.In = .{
                .type = name,
                .ids = ids,
                .limit = @intCast(ids.len),
                .documents = true,
                .expand = false,
                .purpose = purpose,
            };
            const listed = try behind_of(ctx).read_shaped(
                record_operations.List.In,
                Listed,
                record_operations.List.name,
                &asked,
            );
            const items = ctx.arena().alloc(Item, listed.records.len) catch {
                return error.OutOfMemory;
            };

            if (listed.documents.len != listed.records.len) {
                return error.Invalid;
            }

            for (listed.records, listed.documents, items) |row, document, *target| {
                target.* = try shaped_content(ctx, row, document);
            }

            return items;
        }

        /// One record found, with when it was made.
        pub const Found = FoundOf(Document);

        /// One record found with only the fields `Wanted` names.
        pub fn FoundOf(comptime Wanted: type) type {
            return struct {
                id: []const u8,
                version: i64,
                created_at: i64,
                value: Wanted,

                /// What a collection of them is called in the log.
                pub const publr_name = name ++ " records";
            };
        }

        /// A page of the records whose indexed `field` holds `value`, each with only the
        /// fields `Wanted` names (a struct of some of the document's fields; the document
        /// itself for all of them). Internal records only.
        pub fn page_of(
            any_ctx: anytype,
            comptime Wanted: type,
            field: []const u8,
            value: []const u8,
            options: Page,
        ) Error![]const FoundOf(Wanted) {
            const ctx: *PluginCtx = queue.base_of(any_ctx);

            comptime std.debug.assert(internal);
            std.debug.assert(field.len > 0);

            const asked: internal_operations.Find.In = .{
                .kind = name,
                .field = field,
                .value = value,
                .limit = options.limit,
                .offset = options.offset,
                .oldest = options.oldest,
                .after = options.after,
                .fields = comptime projected(Document, Wanted),
            };

            return found_of(ctx, Wanted, &asked);
        }

        /// The records of `ids` (up to 200), each with only the fields `Wanted` names, in
        /// one read; an id with no record is left out. Their references come as ids, unread.
        /// Internal records only.
        pub fn many_of(
            any_ctx: anytype,
            comptime Wanted: type,
            ids: []const []const u8,
        ) Error![]const FoundOf(Wanted) {
            const ctx: *PluginCtx = queue.base_of(any_ctx);

            comptime std.debug.assert(internal);
            std.debug.assert(ids.len <= many_max);

            if (ids.len == 0) {
                return &.{};
            }

            const asked: internal_operations.Find.In = .{
                .kind = name,
                .ids = ids,
                .limit = @intCast(ids.len),
                .fields = comptime projected(Document, Wanted),
            };

            return found_of(ctx, Wanted, &asked);
        }

        /// What `internal.find` answers `asked`, each record's fields read as `Wanted`.
        pub fn found_of(
            ctx: *PluginCtx,
            comptime Wanted: type,
            asked: *const internal_operations.Find.In,
        ) Error![]const FoundOf(Wanted) {
            std.debug.assert(asked.limit > 0);

            // A read of many is one call already: inside a modifier too it is made at
            // once and laid out, never noted to be answered later.
            if (comptime shaped) {
                const noting = behind_of(ctx).reads;

                behind_of(ctx).reads = null;
                defer behind_of(ctx).reads = noting;

                return page_laid(ctx, Wanted, asked);
            }

            // Compiled in, the page's JSON and what reading it takes go back with the
            // step: the caller keeps the records as its own structs alone.
            var step = store_step(ctx, []const FoundOf(Wanted));
            defer step.end();

            const page = try ctx.call(internal_operations.Find, asked.*);
            const found = ctx.arena().alloc(FoundOf(Wanted), page.records.len) catch {
                return error.OutOfMemory;
            };

            for (page.records, found) |record, *target| {
                target.* = .{
                    .id = record.id,
                    .version = record.version,
                    .created_at = record.created_at,
                    .value = record.document.as(Wanted, ctx.arena()) catch return error.Invalid,
                };
            }

            return carried([]const FoundOf(Wanted), &step, found);
        }

        /// A page laid out by the host in an installed plugin's own layout.
        fn page_laid(
            ctx: *PluginCtx,
            comptime Wanted: type,
            asked: *const internal_operations.Find.In,
        ) Error![]const FoundOf(Wanted) {
            const Answered = struct {
                records: []const struct {
                    id: []const u8,
                    version: i64,
                    created_at: i64 = 0,
                    document: Wanted,
                },
            };
            const page = try behind_of(ctx).read_shaped(
                internal_operations.Find.In,
                Answered,
                internal_operations.Find.name,
                asked,
            );
            const found = ctx.arena().alloc(FoundOf(Wanted), page.records.len) catch {
                return error.OutOfMemory;
            };

            std.debug.assert(asked.limit > 0);

            for (page.records, found) |record, *target| {
                target.* = .{
                    .id = record.id,
                    .version = record.version,
                    .created_at = record.created_at,
                    .value = record.document,
                };
            }

            return found;
        }

        /// The record, content with its pending changes; not found when it is another
        /// type's.
        pub fn get(ctx: *PluginCtx, id: []const u8) Error!Item {
            return get_in(ctx, id, &.{});
        }

        /// The record as `get` reads it, content in the combination `pairs` names, each by a
        /// dimension's name or its read option's.
        pub fn get_in(ctx: *PluginCtx, id: []const u8, pairs: []const Pair) Error!Item {
            // An id comes from the caller's input: an empty one names no record.
            if (id.len == 0) {
                return error.NotFound;
            }

            std.debug.assert(!internal or pairs.len == 0);

            if (comptime internal) {
                if (comptime shaped) {
                    // A modifier's reads by id are noted and read together, laid out.
                    if (behind_of(ctx).reads) |reads| {
                        return batched_get(ctx, reads, id);
                    }

                    const asked: internal_operations.Get.In = .{
                        .kind = name,
                        .id = id,
                    };

                    return shaped_item(ctx, try behind_of(ctx).read_shaped(
                        internal_operations.Get.In,
                        Shaped,
                        internal_operations.Get.name,
                        &asked,
                    ));
                }

                var step = store_step(ctx, Item);
                defer step.end();

                const got = try ctx.call(internal_operations.Get, .{
                    .kind = name,
                    .id = id,
                });

                return carried(Item, &step, .{
                    .id = got.id,
                    .version = got.version,
                    .value = try decode(ctx, got.document),
                });
            } else {
                if (comptime shaped) laid: {
                    // A modifier's reads by id are noted and read together, laid out; one
                    // in a dimension's combination is noted and answered on its own.
                    if (behind_of(ctx).reads) |reads| {
                        if (pairs.len > 0) {
                            break :laid;
                        }

                        return batched_get(ctx, reads, id);
                    }

                    return shaped_get(ctx, id, pairs);
                }

                var step = store_step(ctx, Item);
                defer step.end();

                const got = try ctx.call(record_operations.Get, .{
                    .id = id,
                    .type = name,
                    .purpose = .edit,
                    .dimensions = .{
                        .pairs = pairs,
                    },
                });

                if (!std.mem.eql(u8, got.record.type, name)) {
                    return error.NotFound;
                }

                return carried(Item, &step, .{
                    .id = got.record.id,
                    .version = got.record.version,
                    .status = got.record.status,
                    .changed = got.record.changed,
                    .value = try decode(ctx, got.document),
                });
            }
        }

        /// `get` inside a modifier that runs over a batch: the id is noted and the pass
        /// told to wait (`error.NotYet`); between passes every id noted of this type is read
        /// in one call, laid out as `Document`, and the next pass is answered from those.
        fn batched_get(ctx: *PluginCtx, reads: *mod_reads.Reads, id: []const u8) Error!Item {
            std.debug.assert(id.len > 0);

            const typed = try reads.typed_of(name, &batch_settle);

            if (typed.items == null) {
                const list = ctx.arena().create(std.ArrayList(Item)) catch {
                    return error.OutOfMemory;
                };

                list.* = .empty;
                typed.items = list;
                typed.reader = ctx;
            }

            const at = try typed.where(ctx.arena(), id);
            const list: *const std.ArrayList(Item) = @ptrCast(@alignCast(typed.items.?));

            std.debug.assert(at < list.items.len);

            return list.items[at];
        }

        /// The ids a batch noted and has not read, read a page at a time with no modifier
        /// noting: each record is kept where `batched_get` finds it, or how its read ended.
        fn batch_settle(typed: *mod_reads.Typed, arena: std.mem.Allocator) Error!void {
            const ctx: *PluginCtx = @ptrCast(@alignCast(typed.reader.?));
            const list: *std.ArrayList(Item) = @ptrCast(@alignCast(typed.items.?));
            const noting = behind_of(ctx).reads;

            std.debug.assert(typed.pending().len > 0);

            behind_of(ctx).reads = null;
            defer behind_of(ctx).reads = noting;

            while (typed.pending().len > 0) {
                const pending = typed.pending();
                const page = pending[0..@min(pending.len, record_operations.list_max)];

                for (try batch_read(ctx, page)) |item| {
                    const at: u32 = @intCast(list.items.len);

                    list.append(arena, item) catch return error.OutOfMemory;
                    typed.found.put(arena, item.id, .{
                        .at = at,
                    }) catch return error.OutOfMemory;
                }

                for (page) |id| {
                    if (!typed.found.contains(id)) {
                        try batch_alone(ctx, typed, list, arena, id);
                    }
                }

                typed.asked += @intCast(page.len);
            }
        }

        /// The records of `ids` as `get` reads them, in one call: content with its pending
        /// changes, an internal record as kept.
        fn batch_read(ctx: *PluginCtx, ids: []const []const u8) Error![]const Item {
            std.debug.assert(ids.len > 0);
            std.debug.assert(ids.len <= record_operations.list_max);

            if (comptime internal) {
                const found = try many_of(ctx, Document, ids);
                const items = ctx.arena().alloc(Item, found.len) catch return error.OutOfMemory;

                for (found, items) |record, *item| {
                    item.* = .{
                        .id = record.id,
                        .version = record.version,
                        .value = record.value,
                    };
                    try AnyRef.read_all(ctx, &item.value);
                }

                return items;
            }

            // A list that fails (a grant that reaches gets but no lists) leaves each id to
            // be read on its own.
            return shaped_listed(ctx, ids, .edit) catch |err| switch (err) {
                error.OutOfMemory, error.Throttled, error.Unavailable => err,
                else => &.{},
            };
        }

        /// One id the batch's read did not answer, read on its own: a record the list does
        /// not reach is still read, and one that is not there is kept as that.
        fn batch_alone(
            ctx: *PluginCtx,
            typed: *mod_reads.Typed,
            list: *std.ArrayList(Item),
            arena: std.mem.Allocator,
            id: []const u8,
        ) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(behind_of(ctx).reads == null);

            const answer: mod_reads.Typed.Answer = if (comptime internal) .{
                .failed = error.NotFound,
            } else if (shaped_get(ctx, id, &.{})) |item| found: {
                list.append(arena, item) catch return error.OutOfMemory;

                break :found .{
                    .at = @intCast(list.items.len - 1),
                };
            } else |err| switch (err) {
                error.OutOfMemory, error.Throttled, error.Unavailable => return err,
                else => .{
                    .failed = err,
                },
            };

            typed.found.put(arena, id, answer) catch return error.OutOfMemory;
        }

        /// The one record whose `field` holds `value`, or null; two make a conflict.
        pub fn find_one(ctx: *PluginCtx, field: []const u8, value: anytype) Error!?Item {
            const text = try filter_text(ctx, value);

            if (comptime internal) {
                if (comptime shaped) laid: {
                    // A modifier's reads are noted and answered together, as JSON.
                    if (behind_of(ctx).reads != null) {
                        break :laid;
                    }

                    const asked: internal_operations.FindOne.In = .{
                        .kind = name,
                        .field = field,
                        .value = text,
                    };
                    const One = struct {
                        record: ?Shaped = null,
                    };
                    const one = try behind_of(ctx).read_shaped(
                        internal_operations.FindOne.In,
                        One,
                        internal_operations.FindOne.name,
                        &asked,
                    );

                    return if (one.record) |got| try shaped_item(ctx, got) else null;
                }

                var step = store_step(ctx, Item);
                defer step.end();

                const found = try ctx.call(internal_operations.FindOne, .{
                    .kind = name,
                    .field = field,
                    .value = text,
                });
                const record = found.record orelse return null;

                return try carried(Item, &step, .{
                    .id = record.id,
                    .version = record.version,
                    .value = try decode(ctx, record.document),
                });
            } else {
                const listed = try ctx.call(record_operations.List, .{
                    .type = name,
                    .filter_field = field,
                    .filter_value = text,
                    .limit = 2,
                });

                std.debug.assert(listed.records.len <= 2);

                if (listed.records.len > 1) {
                    return error.Conflict;
                }

                if (listed.records.len == 0) {
                    return null;
                }

                return try get(ctx, listed.records[0].id);
            }
        }

        /// The records of these ids, content live; an id with no record readable is left
        /// out, so the answer may be shorter and is in no promised order.
        pub fn many(ctx: *PluginCtx, ids: []const []const u8) Error![]const Item {
            std.debug.assert(ids.len <= record_operations.list_max);

            if (comptime internal) {
                // One read for all of them, never one an id.
                const found = try many_of(ctx, Document, ids);
                const items = ctx.arena().alloc(Item, found.len) catch return error.OutOfMemory;

                for (found, items) |record, *item| {
                    item.* = .{
                        .id = record.id,
                        .version = record.version,
                        .value = record.value,
                    };
                    try AnyRef.read_all(ctx, &item.value);
                }

                return items;
            }

            if (ids.len == 0) {
                return &.{};
            }

            // A read of many is one call already: inside a modifier too it is made at
            // once and laid out, never noted to be answered later.
            if (comptime shaped) {
                const noting = behind_of(ctx).reads;

                behind_of(ctx).reads = null;
                defer behind_of(ctx).reads = noting;

                return shaped_many(ctx, ids);
            }

            var step = store_step(ctx, []const Item);
            defer step.end();

            const listed = try ctx.call(record_operations.List, .{
                .type = name,
                .ids = ids,
                .limit = @intCast(ids.len),
                .documents = true,
                .expand = false,
            });
            const items = ctx.arena().alloc(Item, listed.records.len) catch {
                return error.OutOfMemory;
            };

            for (listed.records, listed.documents, items) |row, document, *target| {
                target.* = .{
                    .id = row.id,
                    .version = row.version,
                    .status = row.status,
                    .changed = row.changed,
                    .value = try decode(ctx, document),
                };
            }

            return carried([]const Item, &step, items);
        }

        /// A new record holding `value`, content in its flow's starting status; its id.
        pub fn create(ctx: *PluginCtx, value: Document) Error![]const u8 {
            // An installed plugin hands the record over as it lies: the host writes its JSON.
            if (comptime guest.mode == .sandboxed) {
                if (behind_of(ctx).memo) |memo| {
                    memo.forget();
                }

                const id = if (comptime internal) made: {
                    const Sent = struct {
                        kind: []const u8,
                        document: Document,
                    };
                    const Create = internal_operations.Create;

                    break :made (try behind_of(ctx).call_shaped(Sent, Create.Out, Create.name, &.{
                        .kind = name,
                        .document = value,
                    })).id;
                } else made: {
                    const Sent = struct {
                        type: []const u8,
                        document: Document,
                    };
                    const Create = record_operations.Create;

                    break :made (try behind_of(ctx).call_shaped(Sent, Create.Out, Create.name, &.{
                        .type = name,
                        .document = value,
                    })).id;
                };

                std.debug.assert(id.len > 0);

                return id;
            }

            // Compiled in, the document's JSON goes back with the step: the id is kept.
            var step = ctx.scope();
            defer step.end();

            const document = try encode(ctx, value);
            const id = if (comptime internal)
                (try ctx.call(internal_operations.Create, .{
                    .kind = name,
                    .document = document,
                })).id
            else
                (try ctx.call(record_operations.Create, .{
                    .type = name,
                    .document = document,
                })).id;

            std.debug.assert(id.len > 0);

            return step.keep(id);
        }

        /// Many new internal records at once, a page a call: their ids, in order.
        pub fn create_many(ctx: *PluginCtx, values: []const Document) Error![]const []const u8 {
            comptime std.debug.assert(internal);

            const ids = ctx.arena().alloc([]const u8, values.len) catch return error.OutOfMemory;
            var start: usize = 0;

            while (start < values.len) {
                const end = @min(values.len, start + many_max);

                // An installed plugin sends the records as they lie: the host writes their JSON.
                if (comptime guest.mode == .sandboxed) {
                    const Sent = struct {
                        kind: []const u8,
                        documents: []const Document,
                    };

                    if (behind_of(ctx).memo) |memo| {
                        memo.forget();
                    }

                    // Each page's call works in memory of its own, given back before the
                    // next: only the ids are carried out.
                    var step = ctx.scope();
                    defer step.end();

                    const CreateMany = internal_operations.CreateMany;
                    const api = behind_of(ctx);
                    const made = try api.call_shaped(Sent, CreateMany.Out, CreateMany.name, &.{
                        .kind = name,
                        .documents = values[start..end],
                    });

                    if (made.ids.len != end - start) {
                        return error.Invalid;
                    }

                    for (ids[start..end], made.ids) |*kept, id| {
                        kept.* = try step.keep(id);
                    }

                    start = end;
                    continue;
                }

                // Compiled in, each page's JSON goes back before the next is written.
                var step = ctx.scope();
                defer step.end();

                const documents = ctx.arena().alloc(public_operation.Json, end - start) catch {
                    return error.OutOfMemory;
                };

                for (values[start..end], documents) |value, *document| {
                    document.* = try encode(ctx, value);
                }

                const made = try ctx.call(internal_operations.CreateMany, .{
                    .kind = name,
                    .documents = documents,
                });

                if (made.ids.len != documents.len) {
                    return error.Invalid;
                }

                for (ids[start..end], made.ids) |*kept, id| {
                    kept.* = try step.keep(id);
                }

                start = end;
            }

            std.debug.assert(start == values.len);

            return ids;
        }

        /// Writes each of `changes` (a slice, each naming some of the document's fields) onto
        /// the record at the same place in `ids`, a page a call; the other fields keep theirs.
        pub fn save_many(
            ctx: *PluginCtx,
            ids: []const []const u8,
            changes: anytype,
        ) Error!void {
            comptime std.debug.assert(internal);
            std.debug.assert(ids.len == changes.len);

            var start: usize = 0;

            while (start < ids.len) {
                const end = @min(ids.len, start + many_max);

                if (comptime guest.mode == .sandboxed) {
                    const One = struct {
                        id: []const u8,
                        document: std.meta.Elem(@TypeOf(changes)),
                    };
                    const Sent = struct {
                        kind: []const u8,
                        records: []const One,
                    };
                    const SaveMany = internal_operations.SaveMany;

                    // Each page's call works in memory of its own, given back before the next.
                    var step = ctx.scope();
                    defer step.end();

                    const records = ctx.arena().alloc(One, end - start) catch {
                        return error.OutOfMemory;
                    };

                    for (ids[start..end], changes[start..end], records) |id, fields, *one| {
                        if (id.len == 0) {
                            return error.NotFound;
                        }

                        one.* = .{
                            .id = id,
                            .document = fields,
                        };
                    }

                    if (behind_of(ctx).memo) |memo| {
                        memo.forget();
                    }

                    _ = try behind_of(ctx).call_shaped(Sent, SaveMany.Out, SaveMany.name, &.{
                        .kind = name,
                        .records = records,
                    });
                    start = end;
                    continue;
                }

                // Compiled in, each page's JSON goes back before the next is written.
                var step = ctx.scope();
                defer step.end();

                const Written = internal_operations.SaveMany.Written;
                const written = ctx.arena().alloc(Written, end - start) catch {
                    return error.OutOfMemory;
                };

                for (ids[start..end], changes[start..end], written) |id, fields, *one| {
                    if (id.len == 0) {
                        return error.NotFound;
                    }

                    one.* = .{
                        .id = id,
                        .document = try encode(ctx, fields),
                    };
                }

                _ = try ctx.call(internal_operations.SaveMany, .{
                    .kind = name,
                    .records = written,
                });
                start = end;
            }

            std.debug.assert(start == ids.len);
        }

        /// Writes `fields`, naming some of the document's fields; the others keep theirs.
        pub fn save(ctx: *PluginCtx, id: []const u8, fields: anytype) Error!void {
            std.debug.assert(name.len > 0);

            // An id comes from the caller's input: an empty one names no record.
            if (id.len == 0) {
                return error.NotFound;
            }

            // Fields given as values the compiler alone knows (`.{ .state = .placed }`) have no
            // layout to hand over: those are written as JSON here, as before.
            if (comptime guest.mode == .sandboxed and laid_out(@TypeOf(fields))) {
                if (behind_of(ctx).memo) |memo| {
                    memo.forget();
                }

                if (comptime internal) {
                    const Sent = struct {
                        kind: []const u8,
                        id: []const u8,
                        document: @TypeOf(fields),
                    };
                    const Save = internal_operations.Save;

                    _ = try behind_of(ctx).call_shaped(Sent, Save.Out, Save.name, &.{
                        .kind = name,
                        .id = id,
                        .document = fields,
                    });
                } else {
                    const Sent = struct {
                        id: []const u8,
                        document: @TypeOf(fields),
                        type: []const u8,
                    };
                    const Save = record_operations.Save;

                    _ = try behind_of(ctx).call_shaped(Sent, Save.Out, Save.name, &.{
                        .id = id,
                        .document = fields,
                        .type = name,
                    });
                }

                return;
            }

            var step = ctx.scope();
            defer step.end();

            const document = try encode(ctx, fields);

            if (comptime internal) {
                _ = try ctx.call(internal_operations.Save, .{
                    .kind = name,
                    .id = id,
                    .document = document,
                });
            } else {
                _ = try ctx.call(record_operations.Save, .{
                    .id = id,
                    .document = document,
                    .type = name,
                });
            }
        }

        /// Empties optional fields of an internal record, by name; the others keep theirs.
        pub fn clear(ctx: *PluginCtx, id: []const u8, comptime fields: anytype) Error!void {
            comptime std.debug.assert(internal);

            const names = comptime cleared_names(Document, name, fields);

            if (id.len == 0) {
                return error.NotFound;
            }

            // An installed plugin's reads are kept between calls: what it read is stale now.
            if (comptime guest.mode == .sandboxed) {
                if (behind_of(ctx).memo) |memo| {
                    memo.forget();
                }
            }

            _ = try ctx.call(internal_operations.Save, .{
                .kind = name,
                .id = id,
                .document = try encode(ctx, .{}),
                .clear = names,
            });
        }

        pub fn delete(ctx: *PluginCtx, id: []const u8) Error!void {
            comptime std.debug.assert(internal);
            // An id comes from the caller's input: an empty one names no record.
            if (id.len == 0) {
                return error.NotFound;
            }

            const deleted = try ctx.call(internal_operations.Delete, .{
                .kind = name,
                .id = id,
            });

            if (!deleted.deleted) {
                return error.NotFound;
            }
        }

        /// The stored document as it is kept, its references ids.
        fn unread(ctx: *PluginCtx, document: public_operation.Json) Error!Document {
            std.debug.assert(name.len > 0);

            return document.as(Document, ctx.arena()) catch error.Invalid;
        }

        /// The stored document, each reference to any record read as an input's is.
        fn decode(ctx: *PluginCtx, document: public_operation.Json) Error!Document {
            std.debug.assert(name.len > 0);

            var value = document.as(Document, ctx.arena()) catch return error.Invalid;

            try AnyRef.read_all(ctx, &value);

            return value;
        }
    };
}

/// Which page of a list a read answers: every list read is a page, `limit` at most 200.
pub const Page = struct {
    limit: u32 = 50,
    offset: u32 = 0,
    /// The oldest first (the order they were made in) instead of the newest.
    oldest: bool = false,
    /// A walk's page: the records after this id, in the order of ids (`""` for the first).
    after: ?[]const u8 = null,
};

/// The fields a read asks for: `Wanted`'s, each one of `Document`'s with its type; none
/// named when the whole document is wanted.
pub fn projected(comptime Document: type, comptime Wanted: type) []const []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Wanted) == .@"struct");

        if (Wanted == Document) {
            return &.{};
        }

        const info = @typeInfo(Wanted).@"struct";

        for (info.field_names, info.field_types) |field_name, Field| {
            if (!@hasField(Document, field_name)) {
                @compileError("a page of " ++ @typeName(Document) ++ " has no field ." ++
                    field_name);
            }

            if (@FieldType(Document, field_name) != Field) {
                @compileError("." ++ field_name ++ " is read as the document keeps it: " ++
                    @typeName(@FieldType(Document, field_name)));
            }
        }

        return info.field_names;
    }
}

/// Whether a value of `Shape` exists at run time with every field in it.
fn laid_out(comptime Shape: type) bool {
    comptime std.debug.assert(Shape != void);

    return switch (@typeInfo(Shape)) {
        .enum_literal, .comptime_int, .comptime_float, .null, .undefined, .type => false,
        .optional => |info| laid_out(info.child),
        .pointer => |info| laid_out(info.child),
        .array => |info| laid_out(info.child),
        .@"struct" => |info| for (info.field_types, info.field_attrs) |Field, attrs| {
            if (attrs.@"comptime" or !laid_out(Field)) {
                break false;
            }
        } else true,
        else => true,
    };
}

/// Compiled in: memory of its own for one read of a store, when what it answers can be
/// copied whole out of it (`sdk/moved.zig`); otherwise the step holds nothing and the read
/// works in the memory it began in. An installed plugin's reads come laid out by the host:
/// the few it still reads as JSON work where they are.
fn store_step(ctx: *PluginCtx, comptime Value: type) PluginCtx.Scope {
    std.debug.assert(ctx.now().ms >= 0);

    if (comptime guest.mode == .sandboxed or !sdk.moved.plain(Value)) {
        return .{
            .outer = ctx.arena(),
            .held = null,
        };
    }

    return ctx.scope();
}

/// What a store's step read, copied whole to the memory the step began in: the caller
/// keeps the value alone, never the JSON it was read from.
fn carried(comptime Value: type, step: *PluginCtx.Scope, value: Value) Error!Value {
    step.leave();

    if (comptime guest.mode == .sandboxed) {
        return value;
    }

    // Only a step whose answer can be copied whole holds memory of its own.
    std.debug.assert(step.held == null or comptime sdk.moved.plain(Value));

    if (step.held == null) {
        return value;
    }

    return sdk.moved.copy(Value, step.outer, value);
}

/// `value` as a record's document, a field holding nothing left out: JSON in Publr, bytes
/// read where they lie in an installed plugin's module.
fn encode(ctx: *PluginCtx, value: anytype) Error!public_operation.Json {
    std.debug.assert(ctx.now().ms >= 0);

    return public_operation.Json.document(ctx.arena(), value) catch error.OutOfMemory;
}

/// A value as a lookup matches it: text as it is, integers in decimal, `true`/`false`, a
/// choice by name.
/// `filter_text`'s value as a walk keeps it: a number stays one until the rows are read.
fn filter_of(value: anytype) rows_module.Filter {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => .{
            .number = @intCast(value),
        },
        .bool => .{
            .text = if (value) "true" else "false",
        },
        .@"enum" => .{
            .text = @tagName(value),
        },
        // A `publr.Account` is found by its id, as it is kept.
        .@"struct" => if (comptime @import("../account_ref.zig").is_account(@TypeOf(value)) or
            @import("ledger_define.zig").ref_kind(@TypeOf(value)) != null)
            .{
                .text = value.id,
            }
        else
            @compileError("find a record by text, a number, an enum or a publr.Account"),
        else => .{
            .text = @as([]const u8, value),
        },
    };
}

fn filter_text(ctx: *PluginCtx, value: anytype) Error![]const u8 {
    std.debug.assert(ctx.now().ms >= 0);

    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => std.fmt.allocPrint(ctx.arena(), "{d}", .{value}) catch {
            return error.OutOfMemory;
        },
        .bool => if (value) "true" else "false",
        .@"enum" => @tagName(value),
        // A `publr.Account` is found by its id, as it is kept.
        .@"struct" => if (comptime @import("../account_ref.zig").is_account(@TypeOf(value)) or
            @import("ledger_define.zig").ref_kind(@TypeOf(value)) != null)
            value.id
        else
            @compileError("find a record by text, a number, an enum or a publr.Account"),
        else => @as([]const u8, value),
    };
}

/// A content record by id through its `Store` (`Typed`), its pending changes included; not found
/// in the trash unless `.{ .trashed = true }`. A plugin's own records and another's alike.
pub fn get_typed(
    comptime Typed: type,
    any_ctx: anytype,
    id: []const u8,
    get_options: anytype,
) Error!Typed.Item {
    const Options = @TypeOf(get_options);
    var pairs: [read_options_max]Pair = undefined;
    var count: u32 = 0;
    var trashed = false;

    // An id comes from the caller's input: an empty one names no record.
    if (id.len == 0) {
        return error.NotFound;
    }

    comptime std.debug.assert(std.meta.fieldNames(Options).len <= read_options_max + 1);

    // `.trashed`, and each other a dimension's read option with the code to read in.
    inline for (comptime std.meta.fieldNames(Options)) |option| {
        if (comptime std.mem.eql(u8, option, "trashed")) {
            trashed = @field(get_options, option);
        } else {
            pairs[count] = .{
                .dimension = option,
                .code = @field(get_options, option),
            };
            count += 1;
        }
    }

    const found = try Typed.get_in(queue.base_of(any_ctx), id, pairs[0..count]);

    if (std.mem.eql(u8, found.status, "trashed") and !trashed) {
        return error.NotFound;
    }

    return found;
}

/// The read options one `get` names at most: a value names at most four dimensions.
pub const read_options_max: u32 = model_dimension.key_pairs_max;

const Pair = model_dimension.Pair;
const model_dimension = @import("../model/dimension.zig");

/// An internal record is bookkeeping, one value per field: `get` takes nothing after the id.
fn check_internal_get(comptime record: []const u8, comptime Options: type) void {
    comptime {
        if (std.meta.fieldNames(Options).len > 0) {
            @compileError("record " ++ record ++ ": an internal record's `get` takes `.{}`; " ++
                "it has no trash, and no values per dimension");
        }
    }
}

/// Moves the record `id` by the transition named `name`. `.pending` when the caller may
/// only draft: a person makes the transition later.
pub fn transition_named(any_ctx: anytype, id: []const u8, name: []const u8) Error!Transitioned {
    return transition_of(any_ctx, id, name, null);
}

/// `transition_named` on a record of `handle`, when the caller names its type: a plugin's
/// own type moves whoever the request is for.
fn transition_of(
    any_ctx: anytype,
    id: []const u8,
    name: []const u8,
    handle: ?[]const u8,
) Error!Transitioned {
    const ctx = queue.base_of(any_ctx);

    // An id comes from the caller's input: an empty one names no record.
    if (id.len == 0) {
        return error.NotFound;
    }

    std.debug.assert(name.len > 0);

    const moved = try ctx.call(record_operations.Transition, .{
        .id = id,
        .transition = name,
        .type = handle,
    });

    return if (moved.pending) .pending else .done;
}

/// `save`'s changes name fields of the record's document.
fn check_changes(
    comptime Document: type,
    comptime record: []const u8,
    comptime Changes: type,
) void {
    comptime {
        std.debug.assert(record.len > 0);

        if (@typeInfo(Changes) != .@"struct") {
            @compileError("record " ++ record ++ ": `save` takes the changes as " ++
                "`.{ .name = value }`");
        }

        for (std.meta.fieldNames(Changes)) |name| {
            field_named(Document, record, name);
        }
    }
}

/// The names `clear` was given (`.{ .note, .seen_at }`), each an optional field of the
/// document: a field that must hold something cannot be emptied.
fn cleared_names(
    comptime Document: type,
    comptime record: []const u8,
    comptime fields: anytype,
) []const []const u8 {
    comptime {
        std.debug.assert(record.len > 0);

        var names: []const []const u8 = &.{};

        for (fields) |field| {
            const field_name = @tagName(field);

            field_named(Document, record, field_name);

            if (@typeInfo(@FieldType(Document, field_name)) != .optional) {
                @compileError("record " ++ record ++ ": `" ++ field_name ++ "` always holds " ++
                    "a value; `clear` empties optional fields");
            }

            names = names ++ [_][]const u8{field_name};
        }

        return names;
    }
}

/// Whether two values of a field are the same, as they are stored.
fn same(ctx: anytype, left: anytype, right: anytype) Error!bool {
    const arena = ctx.arena();
    const Json = public_operation.Json;
    const left_written = (Json.of(arena, left) catch return error.OutOfMemory).written();
    const right_written = (Json.of(arena, right) catch return error.OutOfMemory).written();

    std.debug.assert(left_written.len > 0);

    return std.mem.eql(u8, left_written, right_written);
}

/// What a transition answers: made, or waiting for a person.
pub const Transitioned = enum { done, pending };

/// A content record as its code reads it.
pub fn Content(comptime Document: type, comptime Status: type) type {
    return struct {
        id: []const u8,
        version: i64,
        status: Status,
        changed: bool,
        value: Document,
    };
}

pub fn is_definition(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_record_definition");
}

/// A record's declaration as its own declaration: worked out where it is first read, each
/// record on its own, however many a plugin has.
pub fn Declared(comptime Definition: type, comptime Docs: type) type {
    return struct {
        pub const def = content_type_of(Definition, Docs);
    };
}

/// A content type record's declaration, its words from the doc comments.
pub fn content_type_of(comptime Definition: type, comptime Docs: type) content_type.Def {
    comptime {
        std.debug.assert(!Definition.is_internal);

        const options = Definition.given;
        const Options = @TypeOf(options);
        const Document = Definition.Doc;
        const name = Definition.type_name;
        _ = plugin_define.words(Docs, @typeName(Document)) orelse
            @compileError("record " ++ name ++ ": " ++ @typeName(Document) ++ " needs a `///` " ++
                "comment: its first line is the type's name, the rest what it is for");
        const label = label_of(plugin_define.first(Docs, @typeName(Document)).?);
        var fields: []const field_model.Def = &.{};

        // Each field copies its overrides, its options' and its validation's parts, once.
        @setEvalBranchQuota(1000 + std.meta.fieldNames(Document).len * field_branches_max);

        overrides_named(Document, name, options);

        for (std.meta.fieldNames(Document)) |field_name| {
            fields = fields ++ [_]field_model.Def{field_of(Definition, Docs, field_name)};
        }

        return .{
            .handle = name,
            .name = label,
            .description = plugin_define.rest(Docs, @typeName(Document)).?,
            .public = @hasField(Options, "public") and options.public,
            .roles = if (@hasField(Options, "roles")) options.roles else &.{},
            .url = if (@hasField(Options, "url")) options.url else "",
            .editor = if (@hasField(Options, "editor")) options.editor else "form",
            .plural_name = if (@hasField(Options, "plural_name")) options.plural_name else "",
            .icon = record_menu.icon_of(Definition) orelse "",
            .kind = if (@hasField(Options, "kind")) options.kind else .record,
            .system = true,
            .title_field = title_field_of(Document, options),
            .fields = fields,
            .statuses = status_ids_of(Definition),
            .flow = flow_of(Definition, Docs),
            .menu = record_menu.menu_of(Definition),
            .view = record_menu.view_of(Definition, record_flow.status_id, fields),
            .taxonomies = taxonomies_of(Definition),
        };
    }
}

/// `.taxonomies = &.{ "blog.topic", "tags" }`: the type's own taxonomies by handle, there
/// while the plugin declares them.
fn taxonomies_of(comptime Definition: type) []const content_type.Classified {
    comptime {
        const options = Definition.given;
        var list: []const content_type.Classified = &.{};

        if (!@hasField(@TypeOf(options), "taxonomies")) {
            return list;
        }

        if (options.taxonomies.len > content_type.taxonomies_max) {
            @compileError("record " ++ Definition.type_name ++ ": at most 64 taxonomies");
        }

        for (options.taxonomies) |handle| {
            if (!content_type.valid_handle(handle)) {
                @compileError("record " ++ Definition.type_name ++ ": `.taxonomies` names " ++
                    "taxonomies by handle, `blog.topic` or `tags`: " ++ handle);
            }

            for (list) |earlier| {
                if (std.mem.eql(u8, earlier.taxonomy, handle)) {
                    @compileError("record " ++ Definition.type_name ++ ": `.taxonomies` " ++
                        "names " ++ handle ++ " twice");
                }
            }

            list = list ++ [_]content_type.Classified{.{
                .taxonomy = handle,
                .locked = true,
            }};
        }

        const done = list;

        return done;
    }
}

/// `.register_fields` entries: field groups on users, media or any type, placed by
/// `.location` (core's rules, groups of rules as ACF writes them), named under the plugin.
pub fn field_groups_of(comptime Plugin: type) []const content_type.Def {
    comptime {
        const plugin = Plugin.manifest.name;
        var groups: []const content_type.Def = &.{};

        std.debug.assert(plugin.len > 0);

        for (Plugin.options.register_fields, 0..) |entry, index| {
            const Fields = entry.fields;
            const numbered = plugin ++ "_" ++ std.fmt.comptimePrint("{d}", .{index});
            const handle = if (index == 0) plugin else numbered;
            const Pseudo = struct {
                pub const Doc = Fields;
                pub const type_name = handle;
                pub const owner_plugin = Plugin.manifest.name;
                pub const own_kinds = @import("field_kind_define.zig").definitions_of(Plugin);
                pub const given = .{
                    .name = handle,
                };
            };
            _ = plugin_define.words(Plugin.docs, @typeName(Fields)) orelse
                @compileError("plugin " ++ plugin ++ ": " ++ @typeName(Fields) ++ " needs a " ++
                    "`///` comment: the group's name in the admin");
            var fields: []const field_model.Def = &.{};

            for (std.meta.fieldNames(Fields)) |field_name| {
                fields = fields ++ [_]field_model.Def{field_of(Pseudo, Plugin.docs, field_name)};
            }

            groups = groups ++ [_]content_type.Def{.{
                .handle = handle,
                .name = label_of(plugin_define.first(Plugin.docs, @typeName(Fields)).?),
                .fields = fields,
                .group = .{
                    .location = location_of(entry.location),
                },
            }};
        }

        const done = groups;

        return done;
    }
}

/// A field group's `.location` as written, `.{ .{ .rules = .{ .{ .field, .value } } } }`, as
/// core's rules: groups of rules, any group matching.
fn location_of(comptime given: anytype) conditions.Set {
    comptime {
        var groups: []const conditions.Group = &.{};

        std.debug.assert(given.len <= conditions.groups_max);

        for (0..given.len) |index| {
            const group = given[index];
            var rules: []const conditions.Rule = &.{};

            for (0..group.rules.len) |position| {
                const rule = group.rules[position];

                rules = rules ++ [_]conditions.Rule{.{
                    .field = rule.field,
                    .operator = if (@hasField(@TypeOf(rule), "operator")) rule.operator else .equal,
                    .value = if (@hasField(@TypeOf(rule), "value")) rule.value else "",
                }};
            }

            const kept = rules;

            groups = groups ++ [_]conditions.Group{.{
                .rules = kept,
            }};
        }

        const done = groups;

        return done;
    }
}

/// The plugin a record's name is under: `orders` of `orders.order`.
fn own_plugin(comptime name: []const u8) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        return name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    }
}

/// An internal record's collection.
pub fn collection_of(comptime Definition: type) internal_record.Collection {
    comptime {
        std.debug.assert(Definition.is_internal);

        const options = Definition.given;
        const Options = @TypeOf(options);
        const scope: Scope = if (@hasField(Options, "scope")) options.scope else .project;

        return .{
            .kind = Definition.stored_name,
            .indexed = indexed_of(options) ++ unique_unindexed(Definition),
            .append_only = @hasField(Options, "append_only") and options.append_only,
            .expires = if (@hasField(Options, "expires")) expires_of(options.expires) else null,
            .shared = scope == .project,
            .fields = remote_fields.declared_of(
                Definition.type_name,
                Definition.Doc,
            ),
            .rules = rules_of(Definition),
            .computed = @import("record_computed.zig").names_of(Definition),
        };
    }
}

/// An internal record's top-level fields with rules: those `.fields` gives a `.validation`,
/// and every provider field (its value names a provider of its contract).
fn rules_of(comptime Definition: type) []const field_model.Def {
    comptime {
        const Document = Definition.Doc;
        const given = Definition.given;
        var rules: []const field_model.Def = &.{};

        std.debug.assert(Definition.is_internal);

        for (std.meta.fieldNames(Document), std.meta.fieldTypes(Document)) |name, Field| {
            const optional = @typeInfo(Field) == .optional;
            const Inner = if (optional) @typeInfo(Field).optional.child else Field;
            const overrides = if (@hasField(@TypeOf(given), "fields") and
                @hasField(@TypeOf(given.fields), name))
                @field(given.fields, name)
            else
                .{};
            const provider = @import("../provider_ref.zig").is_provider_ref(Inner);

            // Worked out by its plugin, never written by a caller: no rule to check.
            if (@import("record_computed.zig").is_computed(Definition, name)) {
                continue;
            }

            const shown_to_some = @hasField(@TypeOf(overrides), "visibility");

            if (!provider and !shown_to_some and !@hasField(@TypeOf(overrides), "validation")) {
                continue;
            }

            var def: field_model.Def = .{
                .name = name,
                .label = name,
                .kind = if (@hasField(@TypeOf(overrides), "kind"))
                    overrides.kind
                else
                    kind_of(Definition.type_name, name, Inner),
                .locked = true,
                .many = is_list(Inner) and !is_rows(Inner),
            };

            def.options.number.decimals = places_of(Inner);

            if (provider) {
                def.options.provider = .{
                    .contract = Inner.provider_contract,
                };
            }

            apply(Definition.type_name, &def, overrides);

            // Its plugin reads it whoever else may not.
            if (def.visibility.hidden()) {
                def.visibility.plugin = own_plugin(Definition.type_name);
            }

            const done = def;

            rules = rules ++ [_]field_model.Def{done};
        }

        const kept = rules;

        return kept;
    }
}

/// A unique field `.indexed` leaves out: indexed too, as it is found by its value.
fn unique_unindexed(comptime Definition: type) []const []const u8 {
    comptime {
        const indexed = indexed_of(Definition.given);
        var names: []const []const u8 = &.{};

        std.debug.assert(Definition.is_internal);

        for (rules_of(Definition)) |rule| {
            if (!rule.validation.unique) {
                continue;
            }

            for (indexed) |name| {
                if (std.mem.eql(u8, name, rule.name)) {
                    break;
                }
            } else {
                names = names ++ [_][]const u8{rule.name};
            }
        }

        const done = names;

        return done;
    }
}

/// `.expires = .{ .after_days = 30, .from = .updated }` as written; `.from` is `.updated`
/// when left out.
fn expires_of(comptime given: anytype) internal_record.Expires {
    comptime {
        if (given.after_days == 0) {
            @compileError("`.expires.after_days` is 1 or more");
        }

        return .{
            .after_days = given.after_days,
            .from = if (@hasField(@TypeOf(given), "from")) given.from else .updated,
        };
    }
}

/// The plugin's own field kind whose value `Inner` is (`sampler.weight` for a `Weight`), for a
/// group it places (`.register_fields`); null otherwise. Only a struct names its kind: a
/// plain value (text, a number) is a plain field.
fn own_kind_of(comptime Definition: type, comptime Inner: type) ?[]const u8 {
    comptime {
        if (!@hasDecl(Definition, "own_kinds")) {
            return null;
        }

        std.debug.assert(Definition.owner_plugin.len > 0);

        for (Definition.own_kinds) |Kind| {
            if (@typeInfo(Inner) == .@"struct" and Kind.Shape == Inner) {
                return Definition.owner_plugin ++ "." ++ Kind.verb;
            }
        }

        return null;
    }
}

pub fn field_of(
    comptime Definition: type,
    comptime Docs: type,
    comptime name: []const u8,
) field_model.Def {
    return field_in(Definition, Definition.Doc, Definition.given, Docs, name);
}

/// A field of `Owner` (the document, or a repeater's row) with `given`'s overrides; a list of
/// structs is a repeater, its row's fields declared the same way.
fn field_in(
    comptime Definition: type,
    comptime Owner: type,
    comptime given: anytype,
    comptime Docs: type,
    comptime name: []const u8,
) field_model.Def {
    comptime {
        const info = @typeInfo(Owner).@"struct";
        const index = std.meta.fieldIndex(Owner, name).?;
        const Field = info.field_types[index];
        const attrs = info.field_attrs[index];
        const key = @typeName(Owner) ++ "." ++ name;
        _ = plugin_define.words(Docs, key) orelse @compileError("record " ++
            Definition.type_name ++ ": field `" ++ name ++ "` needs a `///` comment");
        const optional = @typeInfo(Field) == .optional;
        const Inner = if (optional) @typeInfo(Field).optional.child else Field;
        const overrides = if (@hasField(@TypeOf(given), "fields") and
            @hasField(@TypeOf(given.fields), name))
            @field(given.fields, name)
        else
            .{};
        const own_kind = own_kind_of(Definition, Inner);
        const kind_given = @hasField(@TypeOf(overrides), "kind");
        const rows = is_rows(Inner);
        const group = !kind_given and own_kind == null and is_group(Inner);
        var def: field_model.Def = .{
            .name = name,
            .label = label_of(plugin_define.first(Docs, key).?),
            .help = plugin_define.rest(Docs, key).?,
            .kind = if (kind_given)
                overrides.kind
            else if (own_kind) |kind|
                kind
            else if (rows)
                "repeater"
            else if (group)
                "group"
            else
                kind_of(Definition.type_name, name, Inner),
            .validation = .{
                .required = !optional and attrs.defaultValue(Field) == null,
            },
            .locked = true,
            .many = is_list(Inner) and !rows,
            .default = default_of(Field, attrs),
        };

        def.options.number.decimals = places_of(Inner);

        if (rows or group) {
            const Row = if (rows) std.meta.Elem(Inner) else Inner;
            var sub: []const field_model.Def = &.{};

            overrides_named(Row, Definition.type_name, overrides);

            for (std.meta.fieldNames(Row)) |row_field_name| {
                const made = field_in(Definition, Row, overrides, Docs, row_field_name);

                sub = sub ++ [_]field_model.Def{made};
            }

            def.fields = sub;
        }

        if (kind_needs_targets(Inner)) {
            def.options.to = &.{target_of(Inner)};
        }

        if (@import("../provider_ref.zig").is_provider_ref(Inner)) {
            def.options.provider = .{
                .contract = Inner.provider_contract,
            };
        }

        if (@typeInfo(Inner) == .@"enum") {
            def.options.choices = std.meta.fieldNames(Inner);
        }

        if (std.meta.fieldNames(@TypeOf(overrides)).len > 0) {
            apply(Definition.type_name, &def, overrides);
        }

        // Its plugin reads it whoever else may not: the one declaring the type.
        if (def.visibility.hidden()) {
            def.visibility.plugin = own_plugin(Definition.type_name);
        }

        const done = def;

        return done;
    }
}

fn apply(
    comptime record_name: []const u8,
    comptime def: *field_model.Def,
    comptime given: anytype,
) void {
    comptime {
        std.debug.assert(record_name.len > 0);

        const Given = @TypeOf(given);

        // Any other name given a value of an enum is a dimension's field option, offered by
        // the plugin owning the dimension (`.translatable = .required`). A repeater's
        // `fields` are its rows' overrides, taken where the rows are made.
        for (std.meta.fieldNames(Given)) |name| {
            if (@hasField(Overrides, name) or std.mem.eql(u8, name, "fields")) {
                continue;
            }

            if (@typeInfo(@TypeOf(@field(given, name))) != .enum_literal) {
                @compileError("record " ++ record_name ++ ": field `" ++ def.name ++
                    "` has no option `" ++ name ++ "`");
            }

            def.wrapped = def.wrapped ++ &[_]field_model.Wrapped{.{
                .option = name,
                .value = @tagName(@field(given, name)),
            }};
        }

        // A group sets what it names; the rest keeps what the struct field gave (a field
        // that may be left out stays not required unless `.validation` says otherwise).
        for (std.meta.fieldNames(Overrides), std.meta.fieldTypes(Overrides)) |name, Member| {
            if (!@hasField(Given, name)) {
                continue;
            }

            if (@typeInfo(Member) == .@"struct") {
                apply_group(record_name, def, name, @field(given, name));
            } else {
                const typed: Member = @field(given, name);

                @field(def, name) = typed;
            }
        }
    }
}

/// The parts of `group` (`options`, `validation`, `visibility`) that `values` names, each
/// read in the public shape and made into core's.
fn apply_group(
    comptime record_name: []const u8,
    comptime def: *field_model.Def,
    comptime group: []const u8,
    comptime values: anytype,
) void {
    comptime {
        const Public = @FieldType(Overrides, group);

        std.debug.assert(record_name.len > 0);
        std.debug.assert(@hasField(field_model.Def, group));

        for (std.meta.fieldNames(@TypeOf(values))) |part| {
            if (!@hasField(Public, part)) {
                @compileError("record " ++ record_name ++ ": field `" ++ def.name ++
                    "` has no option `." ++ group ++ "." ++ part ++ "`");
            }

            const Target = @TypeOf(@field(@field(def, group), part));
            const typed = coerced(@FieldType(Public, part), @field(values, part), 0);

            @field(@field(def, group), part) = field_model.given.converted(Target, typed, 0);
        }
    }
}

/// An anonymous struct literal turned into `Target`, field by field, at every level.
fn coerced(comptime Target: type, comptime value: anytype, comptime depth: u32) Target {
    comptime {
        std.debug.assert(depth < 8);

        const Given = @TypeOf(value);

        if (Given == Target or @typeInfo(Target) != .@"struct" or @typeInfo(Given) != .@"struct") {
            return value;
        }

        var result: Target = .{};

        for (std.meta.fieldNames(Given)) |name| {
            const Field = @TypeOf(@field(result, name));

            @field(result, name) = coerced(Field, @field(value, name), depth + 1);
        }

        const done = result;

        return done;
    }
}

/// The field kind a Zig type stores as: text, whole numbers, numbers, yes or no, a moment,
/// money, a choice, a reference, or a list of references.
fn kind_of(
    comptime record_name: []const u8,
    comptime name: []const u8,
    comptime Type: type,
) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        if (is_list(Type) and is_reference(std.meta.Elem(Type))) {
            return "reference";
        }

        // A list of plain values: a field of their kind holding several (`[]const []const u8`
        // is a list of text).
        if (is_list(Type)) {
            if (remote_fields.kind_of(std.meta.Elem(Type))) |kind| {
                return kind;
            }
        }

        // A list of groups: rows of a repeater.
        if (is_rows(Type) and is_group(std.meta.Elem(Type))) {
            return "repeater";
        }

        return remote_fields.kind_of(Type) orelse @compileError("record " ++ record_name ++
            ": field `" ++ name ++ "` is " ++ @typeName(Type) ++ "; give it a kind: " ++
            "`.fields = .{ ." ++ name ++ " = .{ .kind = \"...\" } }`");
    }
}

/// The places a `publr.Decimal` field keeps (a list of them too); null for any other.
fn places_of(comptime Type: type) ?u32 {
    comptime {
        const Value = if (is_list(Type)) std.meta.Elem(Type) else Type;

        std.debug.assert(@typeInfo(Value) != .optional);

        if (@typeInfo(Value) != .@"struct" or !@hasDecl(Value, "decimal_places")) {
            return null;
        }

        return Value.decimal_places;
    }
}

const is_reference = remote_fields.is_reference;
const is_list = remote_fields.is_list;

/// A list of plain structs: rows of a repeater (a list of references is not).
fn is_rows(comptime Type: type) bool {
    return is_list(Type) and @typeInfo(std.meta.Elem(Type)) == .@"struct" and
        !is_reference(std.meta.Elem(Type));
}

/// A plain struct that is not a value of its own (a reference, a moment, money's JSON map):
/// a group of fields.
fn is_group(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and !is_reference(Type) and Type != words.Time and
        !@hasDecl(Type, "jsonParse");
}

/// A field's default as the form starts it, written as text: `Placed`, `true`, `20`, `pl`;
/// empty for none, or a default no form field takes (a list, a struct).
fn default_of(
    comptime Field: type,
    comptime attrs: std.builtin.Type.Struct.FieldAttributes,
) []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Field) != .@"fn");

        const given = attrs.defaultValue(Field) orelse return "";
        const Value = @TypeOf(given);
        const value = if (@typeInfo(Value) == .optional) given orelse return "" else given;

        return switch (@typeInfo(@TypeOf(value))) {
            .bool => if (value) "true" else "false",
            .int, .comptime_int, .float, .comptime_float => std.fmt.comptimePrint("{d}", .{value}),
            .@"enum" => @tagName(value),
            .pointer => if (@TypeOf(value) == []const u8) value else "",
            else => "",
        };
    }
}

fn kind_needs_targets(comptime Type: type) bool {
    const Target = if (is_list(Type)) std.meta.Elem(Type) else Type;

    return is_reference(Target) and @hasDecl(Target, "handle");
}

fn target_of(comptime Type: type) []const u8 {
    return if (is_list(Type)) std.meta.Elem(Type).handle else Type.handle;
}

/// The part of a record's name after its plugin's: `entry` of `guestbook.entry`.
fn own_part(comptime name: []const u8) []const u8 {
    comptime {
        const dot = std.mem.indexOfScalar(u8, name, '.').?;

        std.debug.assert(dot + 1 < name.len);

        return name[dot + 1 ..];
    }
}

/// `.title_field` and `.indexed` name fields of the document: `.title_field = .name`,
/// `.indexed = &.{.page}`. A misspelt one fails the build.
fn check_named_fields(comptime Document: type, comptime options: anytype) void {
    comptime {
        const Options = @TypeOf(options);

        std.debug.assert(options.name.len > 0);

        const titled = @hasField(Options, "title_field");
        const title_named = !titled or @TypeOf(options.title_field) == @TypeOf(.enum_literal);

        if (!title_named) {
            @compileError("record " ++ options.name ++ ": `.title_field` names a field: " ++
                "`.title_field = .name`");
        }

        if (@hasField(Options, "title_field") and options.title_field != .none) {
            field_named(Document, options.name, @tagName(options.title_field));
        }

        if (@hasField(Options, "indexed")) {
            for (options.indexed) |field| {
                if (@TypeOf(field) != @TypeOf(.enum_literal)) {
                    @compileError("record " ++ options.name ++ ": `.indexed` names fields: " ++
                        "`.indexed = &.{.page}`");
                }

                field_named(Document, options.name, @tagName(field));
            }
        }
    }
}

/// Every key of `given.fields` names a field of `Owner`: a misspelt override fails the build
/// instead of being left unread.
pub fn overrides_named(
    comptime Owner: type,
    comptime record: []const u8,
    comptime given: anytype,
) void {
    comptime {
        std.debug.assert(record.len > 0);

        if (@hasField(@TypeOf(given), "fields")) {
            for (std.meta.fieldNames(@TypeOf(given.fields))) |name| {
                field_named(Owner, record, name);
            }
        }
    }
}

fn field_named(
    comptime Document: type,
    comptime record: []const u8,
    comptime name: []const u8,
) void {
    comptime {
        std.debug.assert(record.len > 0);

        if (!@hasField(Document, name)) {
            @compileError("record " ++ record ++ ": " ++ @typeName(Document) ++ " has no " ++
                "field `" ++ name ++ "`");
        }
    }
}

/// What lists show a record by: the field `.title_field` names, else its first text field; a
/// settings record has none, nor one whose `.title_field` is `.none`.
fn title_field_of(comptime Document: type, comptime options: anytype) []const u8 {
    comptime {
        const Options = @TypeOf(options);

        std.debug.assert(options.name.len > 0);

        if (@hasField(Options, "title_field")) {
            return if (options.title_field == .none) "" else @tagName(options.title_field);
        }

        if (@hasField(Options, "kind") and options.kind == .settings) {
            return "";
        }

        return title_of(Document);
    }
}

fn indexed_of(comptime options: anytype) []const []const u8 {
    comptime {
        std.debug.assert(options.name.len > 0);

        if (!@hasField(@TypeOf(options), "indexed")) {
            return &.{};
        }

        var names: []const []const u8 = &.{};

        for (options.indexed) |field| {
            names = names ++ [_][]const u8{@tagName(field)};
        }

        const done = names;

        return done;
    }
}

/// The first text field: what a record is listed by when the type names none.
fn title_of(comptime Document: type) []const u8 {
    comptime {
        for (std.meta.fieldNames(Document), std.meta.fieldTypes(Document)) |field_name, FieldType| {
            if (FieldType == []const u8) {
                return field_name;
            }
        }

        @compileError(@typeName(Document) ++ ": give the record a text field, or `.title_field`");
    }
}

/// A name as the admin shows it: a first line without its full stop.
pub fn label_of(comptime first: []const u8) []const u8 {
    std.debug.assert(first.len < 4096);

    return if (first.len > 0 and first[first.len - 1] == '.') first[0 .. first.len - 1] else first;
}

test "a list of structs is a repeater, its rows' fields declared alike; text defaults" {
    const Line = struct {
        title: []const u8,
        quantity: u32,
    };
    const Order = struct {
        fulfilment: []const u8 = "Placed",
        lines: []const Line = &.{},
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Order), "Order" },
        .{ @typeName(Order) ++ ".fulfilment", "Fulfilment" },
        .{ @typeName(Order) ++ ".lines", "Lines" },
        .{ @typeName(Line) ++ ".title", "Product" },
        .{ @typeName(Line) ++ ".quantity", "Quantity" },
    });
    const Orders = define(Order, .{
        .name = "shop.order",
        .fields = .{
            .lines = .{
                .fields = .{
                    .quantity = .{
                        .validation = .{
                            .required = false,
                        },
                    },
                },
            },
        },
    });
    const def = comptime content_type_of(Orders, Docs);
    const lines = def.fields[1];

    try std.testing.expectEqualStrings("Placed", def.fields[0].default);
    try std.testing.expect(!def.fields[0].validation.required);
    try std.testing.expectEqualStrings("repeater", lines.kind);
    try std.testing.expect(!lines.many);
    try std.testing.expectEqualStrings("Product", lines.fields[0].label);
    try std.testing.expectEqualStrings("integer", lines.fields[1].kind);
    try std.testing.expect(!lines.fields[1].validation.required);
}

test "a decimal keeps its places and a list of text is one field holding several" {
    const Weight = @import("decimal.zig").Decimal(3);
    const Line = struct {
        title: []const u8,
        weight: Weight,
        codes: []const []const u8 = &.{},
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Line), "Line" },
        .{ @typeName(Line) ++ ".title", "Title" },
        .{ @typeName(Line) ++ ".weight", "Weight" },
        .{ @typeName(Line) ++ ".codes", "Codes" },
    });
    const Lines = define(Line, .{
        .name = "shop.line",
    });
    const def = comptime content_type_of(Lines, Docs);

    try std.testing.expectEqualStrings("decimal", def.fields[1].kind);
    try std.testing.expectEqual(@as(?u32, 3), def.fields[1].options.number.decimals);
    try std.testing.expectEqualStrings("string", def.fields[2].kind);
    try std.testing.expect(def.fields[2].many);
}

test "a field says how it holds a dimension's values through its owner's field option" {
    const Product = struct {
        name: []const u8,
        sku: []const u8,
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Product), "Product" },
        .{ @typeName(Product) ++ ".name", "Name" },
        .{ @typeName(Product) ++ ".sku", "SKU" },
    });
    const Products = define(Product, .{
        .name = "shop.product",
        .fields = .{
            .name = .{
                .translatable = .required,
                .searchable = true,
            },
        },
    });
    const def = comptime content_type_of(Products, Docs);

    try std.testing.expectEqual(1, def.fields[0].wrapped.len);
    try std.testing.expectEqualStrings("translatable", def.fields[0].wrapped[0].option);
    try std.testing.expectEqualStrings("required", def.fields[0].wrapped[0].value);
    try std.testing.expect(def.fields[0].searchable);
    try std.testing.expectEqual(0, def.fields[1].wrapped.len);
}

test "a struct field is a group; yes/no, number and choice defaults reach the form" {
    const Size = struct {
        width: u32 = 0,
        height: u32 = 0,
    };
    const Mood = enum { calm, loud };
    const Item = struct {
        size: Size = .{},
        available: bool = true,
        days: u32 = 20,
        mood: Mood = .loud,
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Item), "Item" },
        .{ @typeName(Item) ++ ".size", "Size" },
        .{ @typeName(Item) ++ ".available", "Available" },
        .{ @typeName(Item) ++ ".days", "Days" },
        .{ @typeName(Item) ++ ".mood", "Mood" },
        .{ @typeName(Size) ++ ".width", "Width" },
        .{ @typeName(Size) ++ ".height", "Height" },
    });
    const Items = define(Item, .{
        .name = "shop.item",
        .title_field = .mood,
    });
    const def = comptime content_type_of(Items, Docs);

    try std.testing.expectEqualStrings("group", def.fields[0].kind);
    try std.testing.expectEqualStrings("Height", def.fields[0].fields[1].label);
    try std.testing.expectEqualStrings("true", def.fields[1].default);
    try std.testing.expectEqualStrings("20", def.fields[2].default);
    try std.testing.expectEqualStrings("loud", def.fields[3].default);
}

test "a content type and an internal record from their document structs" {
    const Entry = struct {
        name: []const u8,
        message: []const u8,
        visits: u32 = 0,
        seen_at: ?words.Time = null,
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Entry), "Guestbook entry\n\nWhat visitors leave." },
        .{ @typeName(Entry) ++ ".name", "Name\nWho signed" },
        .{ @typeName(Entry) ++ ".message", "Message" },
        .{ @typeName(Entry) ++ ".visits", "Visits" },
        .{ @typeName(Entry) ++ ".seen_at", "Seen" },
    });
    const Entries = define(Entry, .{
        .name = "guestbook.entry",
        .public = true,
        .fields = .{
            .message = .{
                .validation = .{
                    .max_len = 500,
                },
            },
        },
    });
    const def = comptime content_type_of(Entries, Docs);

    try std.testing.expectEqualStrings("guestbook.entry", def.handle);
    try std.testing.expectEqualStrings("Guestbook entry", def.name);
    try std.testing.expectEqualStrings("name", def.title_field);
    try std.testing.expectEqualStrings("string", def.fields[0].kind);
    try std.testing.expectEqualStrings("Who signed", def.fields[0].help);
    try std.testing.expect(def.fields[0].validation.required);
    try std.testing.expectEqual(500, def.fields[1].validation.max_len.?);
    try std.testing.expectEqualStrings("integer", def.fields[2].kind);
    try std.testing.expect(!def.fields[2].validation.required);
    try std.testing.expectEqualStrings("datetime", def.fields[3].kind);

    const Tally = define(Entry, .{
        .name = "guestbook.tally",
        .internal = true,
        .indexed = &.{.name},
    });
    const collection = comptime collection_of(Tally);

    try std.testing.expectEqualStrings("tally", collection.kind);
    try std.testing.expectEqualStrings("name", collection.indexed[0]);
    try std.testing.expect(collection.shared);
}

/// The statuses a record's `.status` brings beyond core's, labelled by the `///` on each
/// value of its enum.
pub fn statuses_of(comptime Definition: type, comptime Docs: type) []const status_module.Status {
    comptime {
        std.debug.assert(Definition.type_name.len > 0);

        const options = Definition.given;

        if (!@hasField(@TypeOf(options), "status")) {
            return &.{};
        }

        const Status = options.status.list;
        const live = record_flow.published_of(options);
        var list: []const status_module.Status = &.{};

        for (std.meta.fieldNames(Status)) |value| {
            if (plugin_define.listed_in(record_flow.core_status_ids, value)) {
                continue;
            }

            const label = plugin_define.first(Docs, @typeName(Status) ++ "." ++ value) orelse value;
            var shown = false;

            for (live) |published| {
                shown = shown or std.mem.eql(u8, @tagName(published), value);
            }

            list = list ++ [_]status_module.Status{.{
                .id = record_flow.status_id(options.name, value),
                .label = label_of(label),
                .live = shown,
                .alias = record_flow.alias_of(options, value),
            }};
        }

        const done = list;

        return done;
    }
}

/// The type's flow as its definition keeps it: its own statuses, every transition by name, and
/// its start.
pub fn flow_of(comptime Definition: type, comptime Docs: type) flow_model.Flow {
    comptime {
        std.debug.assert(Definition.type_name.len > 0);

        const options = Definition.given;

        if (!@hasField(@TypeOf(options), "status")) {
            return .{};
        }

        return .{
            .statuses = statuses_of(Definition, Docs),
            .transitions = record_flow.transitions_of(options),
            .start = record_flow.start_status(options),
        };
    }
}

/// The ids of the statuses a record's type uses: its list's.
pub fn status_ids_of(comptime Definition: type) []const []const u8 {
    comptime {
        std.debug.assert(Definition.type_name.len > 0);

        const options = Definition.given;

        if (!@hasField(@TypeOf(options), "status")) {
            return &.{};
        }

        var ids: []const []const u8 = &.{};

        for (std.meta.fieldNames(options.status.list)) |value| {
            ids = ids ++ [_][]const u8{record_flow.status_id(options.name, value)};
        }

        const done = ids;

        return done;
    }
}

test "a record's references to any record read back as an input's: type, value, missing" {
    const registry = @import("../../server/registry.zig");
    const fixture = @import("../../operations/record/fixture.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try fixture.post_type(&system);

    const live = try fixture.published(&system, "post", "{\"title\":\"Live\"}");
    const gone = try fixture.published(&system, "post", "{\"title\":\"Gone\"}");

    _ = try registry.SDK.dispatch(&system, record_operations.Transition, .{
        .id = gone.id,
        .transition = "trash",
    });
    system.parent = system.allocate_operation_id();

    var host: @import("../../sdk/plugin/context.zig").HostApi = .{
        .inner = &system,
    };
    const Line = struct {
        item: AnyRef,
        others: []const AnyRef,
    };
    var line = try std.json.parseFromSliceLeaky(Line, system.arena, try std.fmt.allocPrint(
        system.arena,
        "{{\"item\":\"{s}\",\"others\":[\"{s}\"]}}",
        .{ live.id, gone.id },
    ), .{});

    try AnyRef.read_all(host.ctx(), &line);
    try std.testing.expectEqualStrings("post", line.item.type);
    const read = try line.item.value.?.read(system.arena);

    try std.testing.expectEqualStrings("Live", read.get("title").?.text().?);
    try std.testing.expect(!line.item.missing);
    try std.testing.expect(line.others[0].missing);
    try std.testing.expect(line.others[0].value == null);
}
