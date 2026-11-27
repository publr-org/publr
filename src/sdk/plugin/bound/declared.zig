//! What core reads of a bound plugin's options in its own shapes: the content types its
//! records make, its hooks with their records', its pages and kinds given their words.
const std = @import("std");
const Namespace = @import("../../../publr/operation.zig").Namespace;
const Page = @import("../../../publr/plugin/admin_slots.zig").Page;
const Panel = @import("../../../publr/plugin/admin_slots.zig").Panel;
const RowAction = @import("../../../publr/plugin/admin_slots.zig").RowAction;
const admin_described = @import("../admin_described.zig");
const host_define = @import("../../../publr/extend/host.zig");
const ContentTypeDef = @import("../../../model/content_type.zig").Def;
const Collection = @import("../../../model/internal_record.zig").Collection;

/// The options a bound plugin's readers take in their core shape, each `.{ name, Item, of }`:
/// operations and pages given their words, hooks with their records', and so on.
pub const resolvers = .{
    .{ "operations", type, described_operations },
    .{ "content_types", ContentTypeDef, declared_content_types },
    .{ "taxonomies", ContentTypeDef, declared_taxonomies },
    .{ "register_taxonomies", TaxonomyRegistration, declared_registrations },
    .{ "internal_records", Collection, declared_collections },
    .{ "middleware", type, declared_hooks },
    .{ "namespaces", Namespace, declared_namespaces },
    .{ "pages", Page, declared_pages },
    .{ "panels", Panel, described_panels },
    .{ "row_actions", RowAction, described_row_actions },
    .{ "field_kinds", Kind, declared_kinds },
    .{ "custom_fields", ContentTypeDef, declared_field_groups },
    .{ "permissions", @import("../../../publr/model/sandboxed_plugin.zig").Ask, asks_of },
    .{ "compatible_with", []const u8, compatible_with_of },
    .{ "depends_on", []const u8, depends_on_of },
};

fn compatible_with_of(comptime Plugin: type) []const []const u8 {
    std.debug.assert(Plugin.manifest.name.len > 0);

    return as_slice([]const u8, Plugin.options.compatible_with);
}

fn depends_on_of(comptime Plugin: type) []const []const u8 {
    std.debug.assert(Plugin.manifest.name.len > 0);

    return as_slice([]const u8, Plugin.options.depends_on);
}

fn described_panels(comptime Plugin: type) []const Panel {
    std.debug.assert(Plugin.manifest.name.len > 0);

    return admin_described.each(Plugin, Panel, as_slice(Panel, Plugin.options.panels));
}

fn described_row_actions(comptime Plugin: type) []const RowAction {
    std.debug.assert(Plugin.manifest.name.len > 0);

    const listed = as_slice(RowAction, Plugin.options.row_actions);

    return admin_described.each(Plugin, RowAction, listed);
}

fn asks_of(comptime Plugin: type) []const @import("../../../publr/model/sandboxed_plugin.zig").Ask {
    std.debug.assert(Plugin.manifest.name.len > 0);

    return @import("../permission_define.zig").asks_of(Plugin);
}

/// A bound plugin's operations: each `publr.operation.define` given its words and its
/// plugin's name.
fn described_operations(comptime Plugin: type) []const type {
    comptime {
        const operation_define = @import("../../../publr/plugin/operation_define.zig");
        const listed = Plugin.options.operations;

        std.debug.assert(Plugin.manifest.name.len > 0);

        var described: [listed.len]type = undefined;

        for (listed, &described) |Listed, *slot| {
            if (!operation_define.is_definition(Listed)) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": `.operations` lists " ++
                    @typeName(Listed) ++ "; make it with `publr.operation.define`");
            }

            slot.* = operation_define.Described(Listed, Plugin.manifest.name, Plugin.docs);
        }

        const done = described;

        return &done;
    }
}

const TaxonomyRegistration = @import("../../../publr/model/taxonomy.zig").Registration;

/// A bound plugin's taxonomies, each `publr.taxonomy.define` stored under the plugin's name.
fn declared_taxonomies(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        const taxonomies = @import("../taxonomies.zig");
        var list: []const ContentTypeDef = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (Plugin.options.taxonomies) |Taxonomy| {
            if (!taxonomies.is_taxonomy(Taxonomy)) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": `.taxonomies` lists " ++
                    @typeName(Taxonomy) ++ "; make it with `publr.taxonomy.define`");
            }

            const def = taxonomies.def_of(Taxonomy, Plugin.manifest.name, Plugin.docs);

            for (list) |earlier| {
                if (std.mem.eql(u8, earlier.handle, def.handle)) {
                    @compileError("plugin " ++ Plugin.manifest.name ++ ": two taxonomies " ++
                        "are named " ++ def.handle);
                }
            }

            list = list ++ [_]ContentTypeDef{def};
        }

        const done = list;

        return done;
    }
}

/// A bound plugin's taxonomies on other plugins' types, checked.
fn declared_registrations(comptime Plugin: type) []const TaxonomyRegistration {
    comptime {
        var list: []const TaxonomyRegistration = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (Plugin.options.register_taxonomies) |entry| {
            list = list ++ [_]TaxonomyRegistration{.{
                .taxonomy = entry.taxonomy,
                .to = entry.to,
            }};
        }

        const done = list;

        @import("../taxonomies.zig").check(Plugin.manifest.name, done);

        return done;
    }
}

/// A bound plugin's content types: every `.records` entry that is not internal.
fn declared_content_types(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        const record_define = @import("../../../publr/plugin/record_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const ContentTypeDef = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "records")) {
            var fields: u32 = 0;

            for (Plugin.options.records) |Record| {
                fields += std.meta.fieldNames(Record.Doc).len;
            }

            // Each record's fields read once, as `record.define` reads them.
            @setEvalBranchQuota(1000 + fields * record_define.field_branches_max);

            for (Plugin.options.records) |Record| {
                check_record_name(Plugin.manifest.name, Record.type_name);

                if (!Record.is_internal) {
                    const declared = @import("../records.zig").Declared(Record, Plugin.docs).def;

                    list = list ++ [_]ContentTypeDef{declared};
                }
            }
        }

        const done = list;

        return done;
    }
}

fn declared_collections(comptime Plugin: type) []const Collection {
    comptime {
        const Options = @TypeOf(Plugin.options);
        var list: []const Collection = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "records")) {
            for (Plugin.options.records) |Record| {
                check_record_name(Plugin.manifest.name, Record.type_name);

                if (Record.is_internal) {
                    list = list ++ [_]Collection{@import("../records.zig").collection_of(Record)};
                }
            }
        }

        const done = list;

        return done;
    }
}

/// A record's name starts with its plugin's: `guestbook.entry` in guestbook.
fn check_record_name(comptime plugin: []const u8, comptime name: []const u8) void {
    comptime {
        std.debug.assert(plugin.len > 0);

        const prefix = plugin ++ ".";

        if (!std.mem.startsWith(u8, name, prefix)) {
            @compileError("plugin " ++ plugin ++ ": record `" ++ name ++ "` is named under " ++
                "its plugin: `" ++ prefix ++ "...`");
        }
    }
}

/// A bound plugin's hooks: what `.extend` gave `host.middleware`, then `.hooks`, each
/// `publr.before`, `publr.after`, `publr.on` and `publr.modify` given its plugin's name.
fn declared_hooks(comptime Plugin: type) []const type {
    comptime {
        const hook_define = @import("../../../publr/plugin/hook_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const type = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        list = list ++ host_hooks(Plugin);

        if (@hasField(Options, "hooks")) {
            for (Plugin.options.hooks, 0..) |Hook, position| {
                // A request hook runs before a page, not around an operation.
                if (hook_define.is_request_hook(Hook)) {
                    continue;
                }

                if (!hook_define.is_hook(Hook)) {
                    @compileError("plugin " ++ Plugin.manifest.name ++ ": `.hooks` takes " ++
                        "`publr.before`, `publr.after`, `publr.on` and `publr.modify`: " ++
                        @typeName(Hook));
                }

                const key = std.fmt.comptimePrint("hook:{d}", .{position});
                const reason = Plugin.docs.first(key);

                list = list ++ [_]type{hook_define.Described(Hook, Plugin.manifest.name, reason)};
            }
        }

        if (@hasField(Options, "records")) {
            const record_validate = @import("../record_validate.zig");
            const record_computed = @import("../../../publr/plugin/record_computed.zig");

            for (Plugin.options.records) |Record| {
                list = list ++ record_validate.hooks_of(Record);
                list = list ++ record_computed.hooks_of(Record, Plugin.manifest.name);
            }
        }

        const done = list;

        return done;
    }
}

/// A bound plugin's field kinds: each `publr.field.kind` named under the plugin.
fn declared_kinds(comptime Plugin: type) []const Kind {
    comptime {
        const field_kinds = @import("../field_kinds.zig");
        var list: []const Kind = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (Plugin.options.field_kinds) |Listed| {
            list = list ++ [_]Kind{
                field_kinds.described(Listed, Plugin.manifest.name, Plugin.docs),
            };
        }

        const done = list;

        return done;
    }
}

/// A bound plugin's field groups: its `.register_fields`.
fn declared_field_groups(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        return @import("../records.zig").field_groups_of(Plugin);
    }
}

/// A bound plugin's pages, each operation they name given its words and its plugin's name.
fn declared_pages(comptime Plugin: type) []const Page {
    comptime {
        var list: []const Page = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (as_slice(Page, Plugin.options.pages)) |page| {
            var made = page;

            if (page.operation) |Operation| {
                made.operation = admin_described.described(Plugin, Operation);
            }

            if (page.form) |form| {
                made.form.?.read = admin_described.described(Plugin, form.read);
                made.form.?.save = admin_described.described(Plugin, form.save);

                if (form.suggest) |Suggest| {
                    made.form.?.suggest = admin_described.described(Plugin, Suggest);
                }

                if (form.preview) |Preview| {
                    made.form.?.preview = admin_described.described(Plugin, Preview);
                }
            }

            if (page.top_bar) |shown| {
                if (shown.count) |Count| {
                    made.top_bar = .{
                        .count = admin_described.described(Plugin, Count),
                    };
                }
            }

            list = list ++ [_]Page{made};
        }

        const done = list;

        return done;
    }
}

/// A bound plugin's namespace: its own words, the description and the settings text.
fn declared_namespaces(comptime Plugin: type) []const Namespace {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        const own = [_]Namespace{.{
            .name = Plugin.manifest.name,
            .summary = Plugin.manifest.summary,
            .details = if (Plugin.settings_text.len > 0)
                Plugin.settings_text
            else
                Plugin.manifest.summary,
        }};

        return &own;
    }
}

/// Whether a bound plugin has `.extend`.
pub fn extends(comptime Plugin: type) bool {
    if (!@hasDecl(Plugin, "host")) {
        return false;
    }

    return @TypeOf(Plugin.host) != @TypeOf(null);
}

/// What `.extend` gave `host.middleware`.
pub fn host_hooks(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        if (!extends(Plugin)) {
            return &.{};
        }

        return Plugin.host.middlewares;
    }
}
const Kind = @import("../../../model/kinds.zig").Kind;

fn as_slice(comptime Item: type, comptime value: anytype) []const Item {
    comptime {
        std.debug.assert(value.len <= 4096);

        return switch (@typeInfo(@TypeOf(value))) {
            .array => &value,
            .@"struct" => &value,
            else => value,
        };
    }
}
