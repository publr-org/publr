//! One registration: `pub const plugin = publr.plugin.define(manifest, options)`. The words
//! come from the plugin's doc comments, which the build hands over beside it; `Bind` pairs
//! the two into the type every reader takes, and `has`/`get` read its options.
const std = @import("std");
const doc_reader = @import("doc_reader.zig");

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
};

/// The manifest every reader takes: the name and version, and the description from `//!`.
pub const Described = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
};

pub fn Definition(comptime Options: type) type {
    return struct {
        manifest: Manifest,
        options: Options,
    };
}

pub fn define(comptime manifest: Manifest, comptime options: anytype) Definition(@TypeOf(options)) {
    comptime {
        std.debug.assert(manifest.name.len > 0);
        std.debug.assert(manifest.version.len > 0);

        return .{
            .manifest = manifest,
            .options = options,
        };
    }
}

/// Whether `Module` registers through `define`.
pub fn defined(comptime Module: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Module) == .@"struct");

        if (!@hasDecl(Module, "plugin")) {
            return false;
        }

        const Value = @TypeOf(Module.plugin);

        return @typeInfo(Value) == .@"struct" and @hasField(Value, "manifest") and
            @hasField(Value, "options") and Value == Definition(@TypeOf(Module.plugin.options));
    }
}

/// The plugin as every reader takes it: its manifest with the description from `main.zig`'s
/// `//!`, its options, and its words.
pub fn Bind(comptime Module: type, comptime Docs: type) type {
    comptime {
        if (!defined(Module)) {
            @compileError(@typeName(Module) ++ ": a plugin registers with " ++
                "`pub const plugin = publr.plugin.define(manifest, options)`");
        }

        const plugin = Module.plugin;
        _ = words(Docs, "main") orelse @compileError("plugin " ++
            plugin.manifest.name ++ ": main.zig needs a `//!` comment: its first line is the " ++
            "plugin's description, the rest the text on its settings page");
        const summary = Docs.first("main").?;

        if (summary.len == 0 or summary.len > summary_len_max) {
            @compileError("plugin " ++ plugin.manifest.name ++ ": the first line of main.zig's " ++
                "`//!` is the description, 1 to 200 characters");
        }

        if (plugin.manifest.version.len > version_len_max) {
            @compileError("plugin " ++ plugin.manifest.name ++ ": `version` is 1 to 32 chars");
        }

        check_options(plugin.manifest.name, @TypeOf(plugin.options));

        const Bound = struct {
            pub const manifest: Described = .{
                .name = plugin.manifest.name,
                .version = plugin.manifest.version,
                .summary = summary,
            };
            pub const options = plugin.options;
            // Null without `.extend`, and in the sandbox, which has none of the host's seams:
            // its build names `extend` as left out.
            pub const host = if (@hasField(@TypeOf(plugin.options), "extend") and
                @import("guest.zig").mode == .native)
                host_define.extended(plugin.manifest.name, plugin.options.extend)
            else
                null;
            pub const docs = Docs;
            pub const source = Module;
            pub const settings_text = Docs.rest("main").?;
        };

        @import("secret_define.zig").check(Bound);

        return Bound;
    }
}

const summary_len_max: u32 = 200;
const version_len_max: u32 = 32;

/// What `define` takes.
const options_known = [_][]const u8{
    "records",                 "operations",
    "hooks",                   "events",
    "permissions",             "secrets",
    "depends_on",              "compatible_with",
    "remotes",                 "field_kinds",
    "register_fields",         "roles",
    "translations",            "limits",
    "pages",                   "panels",
    "jobs",                    "menu",
    "icons",                   "register_statuses",
    "extend",                  "webhooks",
    "register_location_rules", "register_providers",
    "register_columns",
};

/// What only a built-in plugin takes outside `.extend`, until each finds its place.
pub const options_built_in = [_][]const u8{
    "row_actions",
    "settings_pages",
};

fn check_options(comptime plugin: []const u8, comptime Options: type) void {
    comptime {
        std.debug.assert(plugin.len > 0);

        const fields = std.meta.fieldNames(Options).len;
        const listed = options_known.len + options_built_in.len;

        // Each option's name against every known one, a byte at a time.
        @setEvalBranchQuota(1000 + fields * listed * 64);

        for (std.meta.fieldNames(Options)) |name| {
            if (!listed_in(&options_known, name) and !listed_in(&options_built_in, name)) {
                @compileError("plugin " ++ plugin ++ ": `define` has no option `." ++ name ++ "`");
            }
        }
    }
}

pub fn listed_in(comptime names: []const []const u8, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        for (names) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                return true;
            }
        }

        return false;
    }
}

/// Whether the plugin has the option `name`: a field of `define`'s options, or what one of
/// them gives (`.records` content types, `.hooks` middleware, `.extend`'s seams).
pub fn has(comptime Plugin: type, comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    if (comptime host_define.seam(name)) {
        if (comptime !extends(Plugin)) {
            return false;
        }

        return comptime Plugin.host.has(name);
    }

    const Options = @TypeOf(Plugin.options);
    const listed_kind = std.mem.eql(u8, name, "content_types") or
        std.mem.eql(u8, name, "internal_records");
    const from_records = @hasField(Options, "records") and listed_kind;
    const hook_lists = @hasField(Options, "hooks") or @hasField(Options, "records") or
        comptime host_hooks(Plugin).len > 0;
    const from_hooks = hook_lists and std.mem.eql(u8, name, "middleware");
    const from_groups = @hasField(Options, "register_fields") and
        std.mem.eql(u8, name, "custom_fields");

    const from_words = std.mem.eql(u8, name, "namespaces");

    return @hasField(Options, name) or from_records or from_hooks or from_groups or
        from_words;
}

/// The option `name`; a list comes back as a slice either way, empty when the plugin has
/// none of it.
pub fn get(comptime Plugin: type, comptime name: []const u8) Got(Plugin, name) {
    if (comptime !has(Plugin, name)) {
        if (comptime !list_option(name)) {
            @compileError("plugin " ++ Plugin.manifest.name ++ " has no `" ++ name ++ "`");
        }

        return &.{};
    }

    if (comptime host_define.seam(name)) {
        return comptime Plugin.host.get(name);
    }

    inline for (resolvers) |entry| {
        if (comptime std.mem.eql(u8, entry[0], name)) {
            return comptime entry[2](Plugin);
        }
    }

    const value = @field(Plugin.options, name);

    return switch (@typeInfo(@TypeOf(value))) {
        .array => &value,
        .@"struct" => |shape| if (shape.is_tuple) &value else value,
        else => value,
    };
}

/// Whether `name` is a list read the same way whether or not a plugin gives it.
fn list_option(comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    inline for (resolvers) |entry| {
        if (comptime std.mem.eql(u8, entry[0], name)) {
            return true;
        }
    }

    return host_define.listed(name);
}

/// The options a bound plugin's readers take in their core shape, each `.{ name, Item, of }`:
/// operations and pages given their words, hooks with their records', and so on.
const resolvers = .{
    .{ "operations", type, described_operations },
    .{ "content_types", ContentTypeDef, declared_content_types },
    .{ "internal_records", Collection, declared_collections },
    .{ "middleware", type, declared_hooks },
    .{ "namespaces", Namespace, declared_namespaces },
    .{ "pages", Page, declared_pages },
    .{ "panels", Panel, described_panels },
    .{ "row_actions", RowAction, described_row_actions },
    .{ "settings_pages", SettingsPage, described_settings_pages },
    .{ "field_kinds", Kind, declared_kinds },
    .{ "custom_fields", ContentTypeDef, declared_field_groups },
    .{ "permissions", @import("../../model/sandboxed_plugin.zig").Ask, asks_of },
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

fn described_settings_pages(comptime Plugin: type) []const SettingsPage {
    std.debug.assert(Plugin.manifest.name.len > 0);

    const listed = as_slice(SettingsPage, Plugin.options.settings_pages);

    return admin_described.each(Plugin, SettingsPage, listed);
}

fn asks_of(comptime Plugin: type) []const @import("../../model/sandboxed_plugin.zig").Ask {
    std.debug.assert(Plugin.manifest.name.len > 0);

    return @import("permission_define.zig").asks_of(Plugin);
}

/// A bound plugin's operations: each `publr.operation.define` given its words and its
/// plugin's name; anything else as it is.
fn described_operations(comptime Plugin: type) []const type {
    comptime {
        const operation_define = @import("operation_define.zig");
        const listed = Plugin.options.operations;

        std.debug.assert(Plugin.manifest.name.len > 0);

        var described: [listed.len]type = undefined;

        for (listed, &described) |Listed, *slot| {
            slot.* = if (operation_define.is_definition(Listed))
                operation_define.Described(Listed, Plugin.manifest.name, Plugin.docs)
            else
                Listed;
        }

        const done = described;

        return &done;
    }
}

/// A bound plugin's content types: every `.records` entry that is not internal.
fn declared_content_types(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        const record_define = @import("record_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const ContentTypeDef = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "records")) {
            var fields: u32 = 0;

            for (Plugin.options.records) |Record| {
                fields += std.meta.fields(Record.Doc).len;
            }

            // Each record's fields read once, as `record.define` reads them.
            @setEvalBranchQuota(1000 + fields * record_define.field_branches_max);

            for (Plugin.options.records) |Record| {
                check_record_name(Plugin.manifest.name, Record.type_name);

                if (!Record.is_internal) {
                    const declared = record_define.Declared(Record, Plugin.docs).def;

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
        const record_define = @import("record_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const Collection = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "records")) {
            for (Plugin.options.records) |Record| {
                check_record_name(Plugin.manifest.name, Record.type_name);

                if (Record.is_internal) {
                    list = list ++ [_]Collection{record_define.collection_of(Record)};
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
        const hook_define = @import("hook_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const type = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        list = list ++ host_hooks(Plugin);

        if (@hasField(Options, "hooks")) {
            for (Plugin.options.hooks, 0..) |Hook, position| {
                if (!hook_define.is_hook(Hook)) {
                    list = list ++ [_]type{Hook};
                    continue;
                }

                const key = std.fmt.comptimePrint("hook:{d}", .{position});
                const reason = Plugin.docs.first(key);

                list = list ++ [_]type{hook_define.Described(Hook, Plugin.manifest.name, reason)};
            }
        }

        if (@hasField(Options, "records")) {
            const record_validate = @import("record_validate.zig");

            for (Plugin.options.records) |Record| {
                list = list ++ record_validate.hooks_of(Record);
            }
        }

        const done = list;

        return done;
    }
}

/// A bound plugin's field kinds: each `publr.field.kind` named under the plugin.
fn declared_kinds(comptime Plugin: type) []const Kind {
    comptime {
        const field_kind_define = @import("field_kind_define.zig");
        var list: []const Kind = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (Plugin.options.field_kinds) |Listed| {
            list = list ++ [_]Kind{
                field_kind_define.described(Listed, Plugin.manifest.name, Plugin.docs),
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

        return @import("record_define.zig").field_groups_of(Plugin);
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

const Namespace = @import("../operation.zig").Namespace;
const Page = @import("admin_slots.zig").Page;
const Panel = @import("admin_slots.zig").Panel;
const RowAction = @import("admin_slots.zig").RowAction;
const SettingsPage = @import("admin_slots.zig").SettingsPage;
const admin_described = @import("admin_described.zig");
const host_define = @import("host.zig");

/// Whether a bound plugin has `.extend`.
fn extends(comptime Plugin: type) bool {
    if (!@hasDecl(Plugin, "host")) {
        return false;
    }

    return @TypeOf(Plugin.host) != @TypeOf(null);
}

/// What `.extend` gave `host.middleware`.
fn host_hooks(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        if (!extends(Plugin)) {
            return &.{};
        }

        return Plugin.host.middlewares;
    }
}
const Kind = @import("../../model/kinds.zig").Kind;

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

const ContentTypeDef = @import("../../model/content_type.zig").Def;
const Collection = @import("../../model/internal_record.zig").Collection;

pub fn Got(comptime Plugin: type, comptime name: []const u8) type {
    if (host_define.listed(name)) {
        return @FieldType(host_define.Host, name);
    }

    if (host_define.seam(name)) {
        return host_define.Host.Got(Plugin.host, name);
    }

    inline for (resolvers) |entry| {
        if (std.mem.eql(u8, entry[0], name)) {
            return []const entry[1];
        }
    }

    const Value = @TypeOf(@field(Plugin.options, name));

    return switch (@typeInfo(Value)) {
        .array => |array| []const array.child,
        .@"struct" => |shape| if (shape.is_tuple) *const Value else Value,
        else => Value,
    };
}

/// The doc comment kept under `key` (`main`, `operations.answer.In.page`); null when there is
/// none.
pub fn words(comptime Docs: type, comptime key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    return Docs.get(key);
}

/// A doc comment's first line: a name, a label, a summary.
pub fn first(comptime Docs: type, comptime key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    return Docs.first(key);
}

/// What a doc comment says after its first line.
pub fn rest(comptime Docs: type, comptime key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    return Docs.rest(key);
}

/// Words written by hand, for a test: `Words(.{ .{ "main", "..." } })`. A plugin's come from
/// its source, found by name and split already (`doc_reader.generated`).
pub fn Words(comptime entries: anytype) type {
    return struct {
        pub fn get(comptime key: []const u8) ?[]const u8 {
            return part(key, .text);
        }

        pub fn first(comptime key: []const u8) ?[]const u8 {
            return part(key, .first);
        }

        pub fn rest(comptime key: []const u8) ?[]const u8 {
            return part(key, .rest);
        }

        fn part(comptime key: []const u8, comptime which: enum { text, first, rest }) ?[]const u8 {
            std.debug.assert(key.len > 0);

            inline for (entries) |entry| {
                if (comptime std.mem.eql(u8, entry[0], key)) {
                    const parts = comptime doc_reader.split(entry[1]);

                    return switch (which) {
                        .text => entry[1],
                        .first => parts.first,
                        .rest => parts.rest,
                    };
                }
            }

            return null;
        }
    };
}

test "a plugin written with define, bound to its words" {
    const Docs = Words(.{
        .{ "main", "Asks visitors whether a page helped.\n\nThe answers show here." },
    });
    const Module = struct {
        pub const plugin = define(.{
            .name = "helpful",
            .version = "0.1.0",
        }, .{
            .compatible_with = [_][]const u8{"blog"},
        });
    };
    const Plugin = Bind(Module, Docs);

    const summary = Plugin.manifest.summary;

    try std.testing.expectEqualStrings("Asks visitors whether a page helped.", summary);
    try std.testing.expectEqualStrings("The answers show here.", Plugin.settings_text);
    try std.testing.expect(has(Plugin, "compatible_with"));
    try std.testing.expect(!has(Plugin, "operations"));
    try std.testing.expectEqualStrings("blog", get(Plugin, "compatible_with")[0]);
}
