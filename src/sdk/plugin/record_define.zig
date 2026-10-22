//! `publr.record.define(Document, .{ .name, .internal, .fields, .title_field, .public, .url,
//! .indexed, .scope })`: a plugin's record type from its document struct. Content types and
//! internal records are one list (`.records`); the type says which it is. Its words are its
//! doc comments: the struct's `///` is the type's name and description, each field's its
//! label and help.
const queue = @import("queue.zig");
const std = @import("std");
const content_type = @import("../../model/content_type.zig");
const field_model = @import("../../model/field.zig");
const internal_record = @import("../../model/internal_record.zig");
const record_typed = @import("../../operations/record/typed.zig");
const internal_typed = @import("../../operations/internal/typed.zig");
const plugin_define = @import("define.zig");
const words = @import("words.zig");
const conditions = @import("../../model/conditions.zig");
const record_menu = @import("record_menu.zig");

pub const Scope = enum { project, app };

/// A reference to a record of any type: what it points at, and whether it is gone. A
/// field narrows the types with `.options = .{ .to = &.{"products.variant"} }`.
pub const AnyRef = struct {
    type: []const u8,
    id: []const u8,
    /// The record it pointed at is gone; the reference stays, marked so.
    missing: bool = false,

    pub const reference = true;
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
    app,
    kind,
    menu,
    data_view,
    append_only,
};

const record_flow = @import("record_flow.zig");
const flow_model = @import("../../model/flow.zig");
const status_module = @import("../../model/status.zig");
const record_operations = @import("../../operations/record.zig");
const PluginCtx = @import("context.zig").PluginCtx;
const sdk = @import("../../sdk.zig");

/// What one field's declaration may take to evaluate: its overrides, the parts of its options
/// and validation (each a few dozen, nested once), its kind's checks.
const field_branches_max: u32 = 600;

const FieldOption = enum {
    kind,
    validation,
    searchable,
    filterable,
    sortable,
    help,
    options,
    fields,
};

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
        const Typed = if (internal)
            internal_typed.of(Document, stored)
        else
            record_typed.of(Document, stored);

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
            pub const typed = Typed;
            /// The record's status as its code reads it: its list's, or `.other`.
            pub const Status = record_flow.Held(record_flow.List(options));
            /// One record as read: `{ id, version, status, changed, value }`.
            pub const Held = if (internal) Typed.Item else Content(Document, Status);
            pub const Ref = record_typed.Ref(Document, stored);
            /// Every transition on records of the type, as one hook point.
            pub const any_transition = record_flow.AnyTransition(options.name);
            /// Each transition's own hook point: `Posts.transitions.publish`.
            pub const transitions: record_flow.TransitionHooks(options) = .{};
            pub const get = if (internal) get_internal else get_content;
            pub const find_one = if (internal) Typed.find_one else find_content;

            /// Writes the fields `changes` names onto the record `held` read; the others keep
            /// what they hold. A conflict only when one of those fields changed since `held`
            /// was read; another field's change is kept. Never changes status.
            pub fn save(any_ctx: anytype, held: Held, changes: anytype) sdk.Error!void {
                const ctx = queue.base_of(any_ctx);

                comptime check_changes(Document, options.name, @TypeOf(changes));
                std.debug.assert(held.id.len > 0);

                const now = try Typed.get(ctx, held.id);

                inline for (comptime std.meta.fieldNames(@TypeOf(changes))) |field| {
                    const was = @field(held.value, field);
                    const is = @field(now.value, field);

                    if (!try same(ctx, was, is)) {
                        return error.Conflict;
                    }
                }

                if (comptime internal) {
                    _ = try Typed.save(ctx, held.id, changes, null);
                } else {
                    _ = try Typed.save(ctx, held.id, changes, .{});
                }
            }

            /// The record, its pending changes included; not found when it is another type's
            /// or in the trash, unless `.{ .trashed = true }`.
            fn get_content(
                any_ctx: anytype,
                id: []const u8,
                get_options: GetOptions,
            ) sdk.Error!Held {
                std.debug.assert(id.len > 0);

                const found = held_of(try Typed.get(any_ctx, id));
                const in_trash = std.mem.eql(u8, @tagName(found.status), "trashed");

                if (in_trash and !get_options.trashed) {
                    return error.NotFound;
                }

                return found;
            }

            /// An internal record by id; internal records have no trash.
            fn get_internal(
                any_ctx: anytype,
                id: []const u8,
                get_options: GetOptions,
            ) sdk.Error!Held {
                _ = get_options;

                std.debug.assert(id.len > 0);
                std.debug.assert(id.len <= 64 << 10);

                return Typed.get(any_ctx, id);
            }

            /// The one record whose unique `field` holds `value`, or null.
            fn find_content(
                any_ctx: anytype,
                comptime field: std.meta.FieldEnum(Document),
                value: anytype,
            ) sdk.Error!?Held {
                const found = try Typed.find_one(any_ctx, field, value) orelse return null;

                std.debug.assert(found.id.len > 0);

                return held_of(found);
            }

            fn held_of(item: Typed.Item) Held {
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
            pub fn create(any_ctx: anytype, value: Document) sdk.Error![]const u8 {
                const ctx = queue.base_of(any_ctx);

                std.debug.assert(options.name.len > 0);

                if (comptime internal) {
                    return Typed.create(ctx, value);
                }

                return Typed.create(ctx, value, .{
                    .status = comptime record_flow.start_status(options),
                });
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
            ) sdk.Error!Transitioned {
                const ctx = queue.base_of(any_ctx);

                comptime record_flow.check_named(options, @tagName(named));
                comptime std.debug.assert(!internal);
                std.debug.assert(held.id.len > 0);

                const moved = try ctx.call(record_operations.Transition, .{
                    .id = held.id,
                    .transition = @tagName(named),
                });

                return if (moved.pending) .pending else .done;
            }
        };
    }
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

/// Whether two values of a field are the same, as they are stored.
fn same(ctx: anytype, left: anytype, right: anytype) sdk.Error!bool {
    const arena = ctx.arena();
    const left_text = std.json.Stringify.valueAlloc(arena, left, .{}) catch {
        return error.OutOfMemory;
    };
    const right_text = std.json.Stringify.valueAlloc(arena, right, .{}) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(left_text.len > 0);

    return std.mem.eql(u8, left_text, right_text);
}

/// What `get` takes after the id: `.{}`, or `.{ .trashed = true }` to read a record in the
/// trash too.
pub const GetOptions = struct {
    trashed: bool = false,
};

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
        @setEvalBranchQuota(1000 + std.meta.fields(Document).len * field_branches_max);

        overrides_named(Document, name, options);

        for (std.meta.fields(Document)) |field| {
            fields = fields ++ [_]field_model.Def{field_of(Definition, Docs, field)};
        }

        return .{
            .handle = name,
            .name = label,
            .description = plugin_define.rest(Docs, @typeName(Document)).?,
            .public = @hasField(Options, "public") and options.public,
            .url = if (@hasField(Options, "url")) options.url else "",
            .editor = if (@hasField(Options, "editor")) options.editor else "form",
            .plural_name = if (@hasField(Options, "plural_name")) options.plural_name else "",
            .icon = record_menu.icon_of(Definition) orelse "",
            .app = if (@hasField(Options, "app")) options.app else "",
            .kind = if (@hasField(Options, "kind")) options.kind else .record,
            .system = true,
            .title_field = title_field_of(Document, options),
            .fields = fields,
            .statuses = status_ids_of(Definition),
            .flow = flow_of(Definition, Docs),
            .menu = record_menu.menu_of(Definition),
            .view = record_menu.view_of(Definition, record_flow.status_id, fields),
        };
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
                pub const given = .{
                    .name = handle,
                };
            };
            _ = plugin_define.words(Plugin.docs, @typeName(Fields)) orelse
                @compileError("plugin " ++ plugin ++ ": " ++ @typeName(Fields) ++ " needs a " ++
                    "`///` comment: the group's name in the admin");
            var fields: []const field_model.Def = &.{};

            for (std.meta.fields(Fields)) |field| {
                fields = fields ++ [_]field_model.Def{field_of(Pseudo, Plugin.docs, field)};
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
        if (@TypeOf(given) == conditions.Set) {
            return given;
        }

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

/// An internal record's collection.
pub fn collection_of(comptime Definition: type) internal_record.Collection {
    comptime {
        std.debug.assert(Definition.is_internal);

        const options = Definition.given;
        const Options = @TypeOf(options);
        const scope: Scope = if (@hasField(Options, "scope")) options.scope else .project;

        return .{
            .kind = Definition.stored_name,
            .indexed = indexed_of(options),
            .append_only = @hasField(Options, "append_only") and options.append_only,
            .shared = scope == .project,
            .fields = @import("remote_fields.zig").declared_of(
                Definition.type_name,
                Definition.Doc,
            ),
        };
    }
}

fn field_of(
    comptime Definition: type,
    comptime Docs: type,
    comptime field: std.builtin.Type.StructField,
) field_model.Def {
    return field_in(Definition, Definition.Doc, Definition.given, Docs, field);
}

/// A field of `Owner` (the document, or a repeater's row) with `given`'s overrides; a list of
/// structs is a repeater, its row's fields declared the same way.
fn field_in(
    comptime Definition: type,
    comptime Owner: type,
    comptime given: anytype,
    comptime Docs: type,
    comptime field: std.builtin.Type.StructField,
) field_model.Def {
    comptime {
        const key = @typeName(Owner) ++ "." ++ field.name;
        _ = plugin_define.words(Docs, key) orelse @compileError("record " ++
            Definition.type_name ++ ": field `" ++ field.name ++ "` needs a `///` comment");
        const optional = @typeInfo(field.type) == .optional;
        const Inner = if (optional) @typeInfo(field.type).optional.child else field.type;
        const overrides = if (@hasField(@TypeOf(given), "fields") and
            @hasField(@TypeOf(given.fields), field.name))
            @field(given.fields, field.name)
        else
            .{};
        const kind_given = @hasField(@TypeOf(overrides), "kind");
        const rows = is_rows(Inner);
        const group = !kind_given and is_group(Inner);
        var def: field_model.Def = .{
            .name = field.name,
            .label = label_of(plugin_define.first(Docs, key).?),
            .help = plugin_define.rest(Docs, key).?,
            .kind = if (kind_given)
                overrides.kind
            else if (rows)
                "repeater"
            else if (group)
                "group"
            else
                kind_of(Definition.type_name, field.name, Inner),
            .validation = .{
                .required = !optional and field.defaultValue() == null,
            },
            .locked = true,
            .many = is_list(Inner) and !rows,
            .default = default_of(field),
        };

        if (rows or group) {
            const Row = if (rows) std.meta.Elem(Inner) else Inner;
            var sub: []const field_model.Def = &.{};

            overrides_named(Row, Definition.type_name, overrides);

            for (std.meta.fields(Row)) |row_field| {
                const made = field_in(Definition, Row, overrides, Docs, row_field);

                sub = sub ++ [_]field_model.Def{made};
            }

            def.fields = sub;
        }

        if (kind_needs_targets(Inner)) {
            def.options.to = &.{target_of(Inner)};
        }

        if (@typeInfo(Inner) == .@"enum") {
            def.options.choices = std.meta.fieldNames(Inner);
        }

        if (std.meta.fieldNames(@TypeOf(overrides)).len > 0) {
            apply(Definition.type_name, &def, overrides);
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

        for (std.meta.fieldNames(@TypeOf(given))) |name| {
            if (!@hasField(FieldOption, name)) {
                @compileError("record " ++ record_name ++ ": field `" ++ def.name ++
                    "` has no option `" ++ name ++ "`");
            }
        }

        const Given = @TypeOf(given);

        for (std.meta.fieldNames(Given)) |name| {
            // A repeater's `fields` are its rows' overrides, taken where the rows are made.
            const grouped = std.mem.eql(u8, name, "options") or
                std.mem.eql(u8, name, "validation") or std.mem.eql(u8, name, "fields");

            if (!grouped) {
                @field(def, name) = @field(given, name);
            }
        }

        // A group sets what it names; the rest keeps what the struct field gave (a field
        // that may be left out stays not required unless `.validation` says otherwise).
        for ([_][]const u8{ "options", "validation" }) |group| {
            if (@hasField(@TypeOf(given), group)) {
                const values = @field(given, group);

                for (std.meta.fieldNames(@TypeOf(values))) |part| {
                    const Target = @TypeOf(@field(@field(def, group), part));

                    @field(@field(def, group), part) = coerced(Target, @field(values, part), 0);
                }
            }
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
/// a choice, a reference.
fn kind_of(
    comptime record_name: []const u8,
    comptime name: []const u8,
    comptime Type: type,
) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        const Target = if (is_list(Type)) std.meta.Elem(Type) else Type;
        const plain = [_]struct {
            type,
            []const u8,
        }{
            .{ []const u8, "string" },
            .{ bool, "boolean" },
            .{ words.Time, "datetime" },
        };

        for (plain) |pair| {
            if (Type == pair[0]) {
                return pair[1];
            }
        }

        if (is_reference(Target)) {
            return "reference";
        }

        return switch (@typeInfo(Type)) {
            .int => "integer",
            .float => "number",
            .@"enum" => "select",
            else => @compileError("record " ++ record_name ++ ": field `" ++ name ++ "` is " ++
                @typeName(Type) ++ "; give it a kind: `.fields = .{ ." ++ name ++
                " = .{ .kind = \"...\" } }`"),
        };
    }
}

fn is_reference(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "reference");
}

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
fn default_of(comptime field: std.builtin.Type.StructField) []const u8 {
    comptime {
        std.debug.assert(field.name.len > 0);

        const given = field.defaultValue() orelse return "";
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

fn is_list(comptime Type: type) bool {
    const info = @typeInfo(Type);

    return info == .pointer and info.pointer.size == .slice and info.pointer.child != u8;
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
fn overrides_named(
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
        for (std.meta.fields(Document)) |field| {
            if (field.type == []const u8) {
                return field.name;
            }
        }

        @compileError(@typeName(Document) ++ ": give the record a text field, or `.title_field`");
    }
}

/// A name as the admin shows it: a first line without its full stop.
fn label_of(comptime first: []const u8) []const u8 {
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
            if (record_flow.listed(&record_flow.core_status_ids, value)) {
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
