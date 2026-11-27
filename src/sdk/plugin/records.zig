//! Core's reading of a plugin's `publr.record.define` types, in its own shapes: each content
//! type's declaration, each internal record's collection, and the `.register_fields` groups
//! (`publr/plugin/record_define.zig` is what a plugin writes).
const std = @import("std");
const content_type = @import("../../model/content_type.zig");
const field_model = @import("../../model/field.zig");
const internal_record = @import("../../model/internal_record.zig");
const conditions = @import("../../model/conditions.zig");
const record_define = @import("../../publr/plugin/record_define.zig");
const plugin_define = @import("../../publr/plugin/define.zig");
const record_flow = @import("../../publr/plugin/record_flow.zig");
const record_menu = @import("record_menu.zig");
const field_kind_define = @import("../../publr/plugin/field_kind_define.zig");
const remote_fields = @import("remote_fields.zig");
const field_defs = @import("records/fields.zig");
const listed = @import("records/listed.zig");

const Scope = record_define.Scope;
const label_of = record_define.label_of;
const overrides_named = record_define.overrides_named;
const field_branches_max = record_define.field_branches_max;
const own_plugin = field_defs.own_plugin;
const apply = field_defs.apply;
const kind_of = field_defs.kind_of;
const places_of = field_defs.places_of;
const is_rows = field_defs.is_rows;
const is_list = remote_fields.is_list;
const title_field_of = listed.title_field_of;
const indexed_of = listed.indexed_of;
const status_ids_of = listed.status_ids_of;
const flow_of = listed.flow_of;

pub const field_of = field_defs.field_of;
pub const statuses_of = listed.statuses_of;

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
                pub const own_kinds = field_kind_define.definitions_of(Plugin);
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
            .computed = @import("../../publr/plugin/record_computed.zig").names_of(Definition),
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
            const provider = @import("../../publr/provider_ref.zig").is_provider_ref(Inner);

            // Worked out by its plugin, never written by a caller: no rule to check.
            if (@import("../../publr/plugin/record_computed.zig").is_computed(Definition, name)) {
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
            if (field_model.hidden(def.visibility)) {
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

test {
    _ = @import("records/tests.zig");
}
