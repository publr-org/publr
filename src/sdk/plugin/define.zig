//! One registration: `pub const plugin = publr.plugin.define(manifest, options)`. The words
//! come from the plugin's doc comments, which the build hands over beside it; `Bind` pairs
//! the two into the type every reader takes, and `has`/`get` read an option whether the
//! plugin is written this way or still declares its parts one by one.
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

/// The plugin as every reader takes it. A plugin still declaring its parts one by one passes
/// through as it is; one using `define` gets its manifest with the description from `main.zig`'s
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

        check_options(plugin.manifest.name, @TypeOf(plugin.options));
        check_middleware(plugin.manifest.name, @TypeOf(plugin.options), plugin.options);

        const Bound = struct {
            pub const manifest: Described = .{
                .name = plugin.manifest.name,
                .version = plugin.manifest.version,
                .summary = summary,
            };
            pub const options = plugin.options;
            pub const docs = Docs;
            pub const source = Module;
            pub const settings_text = Docs.rest("main").?;
        };

        @import("secret_define.zig").check(Bound);

        return Bound;
    }
}

const summary_len_max: u32 = 200;

/// What `define` takes.
const options_known = [_][]const u8{
    "records",
    "operations",
    "hooks",
    "events",
    "permissions",
    "secrets",
    "depends_on",
    "compatible_with",
    "remotes",
    "field_kinds",
    "register_fields",
    "roles",
    "translations",
    "limits",
    "pages",
    "panels",
    "jobs",
    "menu",
    "icons",
    "register_statuses",
    "register_location_rules",
    "register_columns",
};

/// What only a built-in plugin takes, until `.extend` holds them: the server's own seams.
/// `middleware` takes only the two no hook says: every operation before it runs (`.pre`) and
/// every event inside the write (`.on` without an `event`).
const options_built_in = [_][]const u8{
    "middleware",
    "policies",
    "variants",
    "row_actions",
    "settings_pages",
    "settings_tabs",
    "routes",
    "operator_commands",
    "migrations",
    "schema_sql",
    "bootstrap",
    "sign_in_provider",
    "sign_in_at",
    "State",
    "serving",
    "before_command",
    "admin_brand",
    "agents_tab",
    "app_picker_segment",
    "work_start",
    "hosted",
    "delivery_gates",
    "filters",
};

/// Options decided for gates still to come: a plugin using one is told which, never ignored.
const options_later = [_][2][]const u8{
    .{ "register_taxonomies", "taxonomies on other plugins' types" },
    .{ "register_components", "slots on the site" },
    .{ "register_providers", "contracts and providers" },
    .{ "taxonomies", "taxonomies declared by plugins" },
    .{ "webhooks", "incoming webhooks" },
};

fn check_options(comptime plugin: []const u8, comptime Options: type) void {
    comptime {
        std.debug.assert(plugin.len > 0);

        const fields = std.meta.fieldNames(Options).len;
        const listed = options_known.len + options_built_in.len + options_later.len;

        // Each option's name against every known one, a byte at a time.
        @setEvalBranchQuota(1000 + fields * listed * 64);

        for (std.meta.fieldNames(Options)) |name| {
            for (options_later) |later| {
                if (std.mem.eql(u8, later[0], name)) {
                    @compileError("plugin " ++ plugin ++ ": `." ++ name ++ "` is decided but " ++
                        "not built yet: " ++ later[1] ++ " come with a later gate");
                }
            }

            if (!listed_in(&options_known, name) and !listed_in(&options_built_in, name)) {
                @compileError("plugin " ++ plugin ++ ": `define` has no option `." ++ name ++ "`");
            }
        }
    }
}

fn listed_in(comptime names: []const []const u8, comptime name: []const u8) bool {
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

/// `.middleware` holds only the server's two seams no hook says: a hook on every operation
/// before it runs, or on every event inside the write.
fn check_middleware(
    comptime plugin: []const u8,
    comptime Options: type,
    comptime given: anytype,
) void {
    comptime {
        std.debug.assert(plugin.len > 0);

        if (!@hasField(Options, "middleware")) {
            return;
        }

        for (given.middleware) |Middleware| {
            const every_operation = Middleware.stage == .pre;
            const every_event = Middleware.stage == .on and !@hasDecl(Middleware, "event");

            if (!every_operation and !every_event) {
                @compileError("plugin " ++ plugin ++ ": `" ++ @typeName(Middleware) ++ "` " ++
                    "belongs in `.hooks`: `publr.before`, `publr.after`, `publr.on` or " ++
                    "`publr.modify`");
            }
        }
    }
}

/// Whether the plugin has the option `name`: a field of `define`'s options, or a declaration of
/// a plugin still written part by part.
pub fn has(comptime Plugin: type, comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    if (comptime bound(Plugin)) {
        const Options = @TypeOf(Plugin.options);
        const listed_kind = std.mem.eql(u8, name, "content_types") or
            std.mem.eql(u8, name, "internal_records");
        const from_records = @hasField(Options, "records") and listed_kind;
        const hook_lists = @hasField(Options, "hooks") or @hasField(Options, "records");
        const from_hooks = hook_lists and std.mem.eql(u8, name, "middleware");
        const from_groups = @hasField(Options, "register_fields") and
            std.mem.eql(u8, name, "custom_fields");

        const from_words = std.mem.eql(u8, name, "namespaces");

        return @hasField(Options, name) or from_records or from_hooks or from_groups or
            from_words;
    }

    return @hasDecl(Plugin, name);
}

/// The option `name`; a list comes back as a slice either way.
pub fn get(comptime Plugin: type, comptime name: []const u8) Got(Plugin, name) {
    std.debug.assert(comptime has(Plugin, name));

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "operations")) {
        return comptime described_operations(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "content_types")) {
        return comptime declared_content_types(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "internal_records")) {
        return comptime declared_collections(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "middleware")) {
        return comptime declared_hooks(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "namespaces")) {
        return comptime declared_namespaces(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "pages")) {
        return comptime declared_pages(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "panels")) {
        const listed = as_slice(Panel, Plugin.options.panels);

        return comptime admin_described.each(Plugin, Panel, listed);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "row_actions")) {
        const listed = as_slice(RowAction, Plugin.options.row_actions);

        return comptime admin_described.each(Plugin, RowAction, listed);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "settings_pages")) {
        const listed = as_slice(SettingsPage, Plugin.options.settings_pages);

        return comptime admin_described.each(Plugin, SettingsPage, listed);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "field_kinds")) {
        return comptime declared_kinds(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "custom_fields")) {
        return comptime declared_field_groups(Plugin);
    }

    if (comptime bound(Plugin) and std.mem.eql(u8, name, "permissions")) {
        return comptime @import("permission_define.zig").asks_of(Plugin);
    }

    const value = if (comptime bound(Plugin))
        @field(Plugin.options, name)
    else
        @field(Plugin, name);

    return switch (@typeInfo(@TypeOf(value))) {
        .array => &value,
        .@"struct" => |shape| if (shape.is_tuple) &value else value,
        else => value,
    };
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

/// A bound plugin's content types: those it lists the old way, then every `.records`
/// entry that is not internal.
fn declared_content_types(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        const record_define = @import("record_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const ContentTypeDef = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "content_types")) {
            list = list ++ as_slice(ContentTypeDef, Plugin.options.content_types);
        }

        if (@hasField(Options, "records")) {
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

        if (@hasField(Options, "internal_records")) {
            list = list ++ as_slice(Collection, Plugin.options.internal_records);
        }

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

/// A bound plugin's hooks: `.middleware` listed the old way, then `.hooks`, each
/// `publr.before`, `publr.after`, `publr.on` and `publr.modify` given its plugin's name.
fn declared_hooks(comptime Plugin: type) []const type {
    comptime {
        const hook_define = @import("hook_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const type = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "middleware")) {
            list = list ++ as_slice(type, Plugin.options.middleware);
        }

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
            const made = @TypeOf(Listed) == type and field_kind_define.is_definition(Listed);
            const declared = if (made)
                field_kind_define.described(Listed, Plugin.manifest.name, Plugin.docs)
            else
                Listed;

            list = list ++ [_]Kind{declared};
        }

        const done = list;

        return done;
    }
}

/// A bound plugin's field groups: `custom_fields` the old way, then `.register_fields`.
fn declared_field_groups(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        const record_define = @import("record_define.zig");
        const Options = @TypeOf(Plugin.options);
        var list: []const ContentTypeDef = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "custom_fields")) {
            list = list ++ as_slice(ContentTypeDef, Plugin.options.custom_fields);
        }

        if (@hasField(Options, "register_fields")) {
            list = list ++ record_define.field_groups_of(Plugin);
        }

        const done = list;

        return done;
    }
}

/// A bound plugin's pages, each operation they name given its words and its plugin's name.
fn declared_pages(comptime Plugin: type) []const Page {
    comptime {
        const operation_define = @import("operation_define.zig");
        const plugin = Plugin.manifest.name;
        var list: []const Page = &.{};

        std.debug.assert(plugin.len > 0);

        for (as_slice(Page, Plugin.options.pages)) |page| {
            var made = page;

            if (page.operation) |Operation| {
                if (operation_define.is_definition(Operation)) {
                    made.operation = operation_define.Described(Operation, plugin, Plugin.docs);
                }
            }

            if (page.form) |form| {
                var described_form = form;

                const Docs = Plugin.docs;

                if (operation_define.is_definition(form.read)) {
                    described_form.read = operation_define.Described(form.read, plugin, Docs);
                }

                if (operation_define.is_definition(form.save)) {
                    described_form.save = operation_define.Described(form.save, plugin, Docs);
                }

                made.form = described_form;
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

/// A bound plugin's namespace: its own words, the description and the settings text,
/// unless it still lists namespaces itself.
fn declared_namespaces(comptime Plugin: type) []const Namespace {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(@TypeOf(Plugin.options), "namespaces")) {
            return as_slice(Namespace, Plugin.options.namespaces);
        }

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
const Kind = @import("../../model/kinds.zig").Kind;

fn as_slice(comptime Item: type, comptime value: anytype) []const Item {
    comptime {
        std.debug.assert(value.len <= 4096);

        if (@typeInfo(@TypeOf(value)) == .array) {
            return &value;
        }

        return value;
    }
}

const ContentTypeDef = @import("../../model/content_type.zig").Def;
const Collection = @import("../../model/internal_record.zig").Collection;

pub fn Got(comptime Plugin: type, comptime name: []const u8) type {
    if (bound(Plugin) and std.mem.eql(u8, name, "operations")) {
        return []const type;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "content_types")) {
        return []const ContentTypeDef;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "internal_records")) {
        return []const Collection;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "middleware")) {
        return []const type;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "permissions")) {
        return []const @import("../../model/sandboxed_plugin.zig").Ask;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "field_kinds")) {
        return []const Kind;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "pages")) {
        return []const Page;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "panels")) {
        return []const Panel;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "row_actions")) {
        return []const RowAction;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "settings_pages")) {
        return []const SettingsPage;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "namespaces")) {
        return []const Namespace;
    }

    if (bound(Plugin) and std.mem.eql(u8, name, "custom_fields")) {
        return []const ContentTypeDef;
    }

    const Value = if (bound(Plugin))
        @TypeOf(@field(Plugin.options, name))
    else
        @TypeOf(@field(Plugin, name));

    return switch (@typeInfo(Value)) {
        .array => |array| []const array.child,
        .@"struct" => |shape| if (shape.is_tuple) *const Value else Value,
        else => Value,
    };
}

pub fn bound(comptime Plugin: type) bool {
    return @hasDecl(Plugin, "options") and @hasDecl(Plugin, "source");
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
