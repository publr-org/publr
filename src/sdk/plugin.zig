const std = @import("std");
const plugin_define = @import("plugin/define.zig");
const permission_model = @import("../model/permission.zig");
const job_define = @import("plugin/job_define.zig");
const webhook_define = @import("plugin/webhook_define.zig");
const hook_define = @import("plugin/hook_define.zig");
const remote_contract = @import("plugin/remote_contract.zig");
const sdk = @import("../sdk.zig");
const plugin_context = @import("plugin/context.zig");
const plugin_types = @import("plugin/types.zig");
const filter_module = @import("../model/filter.zig");
const content_type = @import("../model/content_type.zig");
const field = @import("../model/field.zig");
const kinds = @import("../model/kinds.zig");
const role = @import("../model/role.zig");
const provider = @import("provider.zig");
const runtime = @import("plugin/sandboxed.zig");
const db = @import("../lib/db.zig");

pub const PluginCtx = plugin_context.PluginCtx;
pub const types = plugin_types;
/// One registration: `pub const plugin = publr.plugin.define(manifest, options)`.
pub const define = plugin_define.define;
pub const Bind = plugin_define.Bind;
pub const ContentTypeDef = content_type.Def;
pub const DeclaredType = plugin_types.Declared;
pub const InternalCollection = @import("../model/internal_record.zig").Collection;
/// An internal record collection with the plugin that declared it.
pub const OwnedCollection = struct {
    owner: []const u8,
    collection: InternalCollection,
};
pub const Role = role.Declared;
pub const SignInProvider = provider.SignInProvider;
/// What a plugin declares to run in the sandbox: see `plugin/sandboxed.zig`.
pub const Limits = runtime.Limits;
pub const Entry = runtime.Entry;
pub const runtime_entries = runtime.runtime_entries;
pub const HookIn = runtime.HookIn;
pub const HookOut = runtime.HookOut;
pub const plugin_manifest = @import("plugin/manifest.zig");
pub const route = @import("plugin/route.zig");
pub const Route = route.Route;
pub const OperatorCommand = route.OperatorCommand;
pub const admin_slots = @import("plugin/admin_slots.zig");
pub const variants = @import("plugin/variants.zig");
/// A PO file a plugin brings: the admin's words in one language. A language pack is a
/// plugin of these alone; a plugin may bring its own words too.
pub const Translation = struct {
    /// `pl`, `pt-br`.
    locale: []const u8,
    /// The language in its own words: `Polski`.
    label: []const u8,
    /// The PO file, `@embedFile("i18n/pl.po")`.
    po: []const u8,
    /// Whose words it translates: `publr` for the core's, a plugin's name for that plugin's;
    /// empty for the declaring plugin's own. A plugin of translations alone may fill or fix
    /// any domain.
    domain: []const u8 = "",
    /// Publr's own translation of the core (`domain = "publr"`): it wins over any other.
    /// A plugin translating its own words wins for them without saying so.
    official: bool = false,
    /// What a language pack says of its grammar: the cases and genders a type's name is
    /// given in, for messages that decline it (`{type:accusative}`, `{type.gender, select,
    /// …}`). Empty for a language that does not decline nouns, or a plugin's own words.
    grammar: Grammar = .{},
};

/// A translation and the plugin that brings it.
pub const OwnedTranslation = struct {
    plugin: []const u8,
    translation: Translation,

    /// Whose words it translates, the declaring plugin's when it names none.
    pub fn domain(owned: OwnedTranslation) []const u8 {
        return if (owned.translation.domain.len > 0) owned.translation.domain else owned.plugin;
    }

    /// The words' owner's own translation: a plugin's of its own words, or Publr's official
    /// one of the core's. It wins over any other plugin's.
    pub fn first_party(owned: OwnedTranslation) bool {
        const own = std.mem.eql(u8, owned.domain(), owned.plugin);
        const core = std.mem.eql(u8, owned.domain(), "publr") and owned.translation.official;

        return own or core;
    }
};

pub const Grammar = struct {
    /// Each by key (`genitive`) and as people know it (`Dopełniacz (kogo? czego?)`); the
    /// first is the name itself.
    cases: []const Word = &.{},
    genders: []const Word = &.{},
};

pub const Word = struct {
    key: []const u8,
    label: []const u8,
};
pub const Variants = variants.Dimension;
pub const Variant = variants.Variant;
pub const SettingsPage = admin_slots.SettingsPage;
pub const SettingsTab = admin_slots.SettingsTab;
pub const SettingsTabPage = admin_slots.SettingsTabPage;
pub const RowAction = admin_slots.RowAction;
pub const Page = admin_slots.Page;
pub const Item = admin_slots.Item;
pub const Panel = admin_slots.Panel;

/// A panel and the plugin it is of.
pub const OwnedPanel = struct {
    plugin: []const u8,
    panel: Panel,
};

/// An entry and the plugin it is of.
/// A settings page and the plugin whose it is: pinned to the rail as that pair.
pub const OwnedSettingsPage = struct {
    plugin: []const u8,
    page: SettingsPage,
};

pub const OwnedSettingsTab = struct {
    plugin: []const u8,
    tab: SettingsTab,
};

/// What a plugin shows in place of the Overview's "Your agent" commands: its
/// `pub const agents_tab` HTML, which the admin sanitizes and draws in a box named after it.
pub const AgentsTab = struct {
    plugin: []const u8,
    html: []const u8,
};

pub const OwnedItem = struct {
    plugin: []const u8,
    item: Item,
};

/// A page and the plugin it is of.
pub const OwnedPage = struct {
    plugin: []const u8,
    page: Page,
};
pub const state = @import("plugin/state.zig");
pub const depends_on = @import("plugin/depends_on.zig");
pub const Process = state.Process;
pub const wire = @import("plugin/wire.zig");
pub const guest = @import("plugin/guest.zig");
pub const content_types_max: u32 = 64;

pub const name_len_max: u32 = 32;
pub const version_len_max: u32 = 32;
pub const summary_len_max: u32 = 200;
pub const plugins_max: u32 = 64;

/// Whose admin it is, as a plugin's `admin_brand(ctx)` says: its name in the window's title
/// and its mark in the rail. Empty is Publr's.
pub const AdminBrand = struct {
    name: []const u8 = "",
    /// The mark's address, an image any page may load.
    mark: []const u8 = "",
};

pub const Manifest = plugin_define.Described;

pub fn validate(comptime Plugin: type) void {
    comptime {
        const label = @typeName(Plugin);

        if (!@hasDecl(Plugin, "manifest")) {
            @compileError("plugin " ++ label ++ ": missing `pub const manifest: Manifest`");
        }

        const manifest: Manifest = Plugin.manifest;
        assert_name(manifest.name, label);

        if (manifest.version.len == 0 or manifest.version.len > version_len_max) {
            @compileError("plugin " ++ manifest.name ++ ": `manifest.version` is 1 to 32 chars");
        }

        if (manifest.summary.len == 0 or manifest.summary.len > summary_len_max) {
            @compileError("plugin " ++ manifest.name ++ ": `manifest.summary` is 1 to 200 chars");
        }

        for (operations_of(Plugin)) |Operation| {
            sdk.operation.validate(Operation);

            if (!@import("plugin_access.zig").own(manifest.name, Operation.name)) {
                @compileError("plugin " ++ manifest.name ++ ": operation " ++ Operation.name ++
                    " is outside its namespaces, `" ++ manifest.name ++ ".<verb>` and `app." ++
                    manifest.name ++ ".<verb>`");
            }
        }

        for (middleware_of(Plugin)) |Middleware| {
            sdk.middleware.validate(Middleware);
        }

        const internal_record = @import("../model/internal_record.zig");

        if (internal_record.problem(internal_records_of(Plugin))) |message| {
            @compileError("plugin " ++ manifest.name ++ ": " ++ message);
        }

        validate_entries(Plugin, manifest.name);

        const known: []const kinds.Kind = &kinds.core ++ field_kinds_of(Plugin);

        for (content_types_of(Plugin)) |def| {
            var problems: field.Problems = .{};
            content_type.validate_def(known, def, &problems);

            if (!problems.is_empty()) {
                @compileError("plugin " ++ manifest.name ++ ": content type " ++ def.handle ++
                    ": " ++ problems.items[0].message);
            }
        }
    }
}

/// The optional single declarations: `bootstrap` and `sign_in_provider`.
fn validate_entries(comptime Plugin: type, comptime name: []const u8) void {
    comptime {
        std.debug.assert(name.len > 0);
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (plugin_define.has(Plugin, "bootstrap")) {
            const Bootstrap = @TypeOf(plugin_define.get(Plugin, "bootstrap"));
            const expected = fn (*sdk.Ctx) sdk.Error!void;

            if (Bootstrap != expected) {
                @compileError("plugin " ++ name ++ ": `bootstrap` is " ++
                    "`pub fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void`");
            }
        }

        if (plugin_define.has(Plugin, "sign_in_provider")) {
            const declared: SignInProvider = plugin_define.get(Plugin, "sign_in_provider");

            if (provider.problem(declared)) |message| {
                @compileError("plugin " ++ name ++ ": sign_in_provider: " ++ message);
            }
        }
    }
}

/// The content types a plugin declares; created or updated when the database opens.
/// The field kinds a plugin brings, each named under the plugin (`geo.point`).
pub fn field_kinds_of(comptime Plugin: type) []const kinds.Kind {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "field_kinds")) {
            return &.{};
        }

        const list: []const kinds.Kind = plugin_define.get(Plugin, "field_kinds");
        const prefix = Plugin.manifest.name ++ ".";

        std.debug.assert(list.len <= kinds.kinds_max);

        for (list) |kind| {
            if (!std.mem.startsWith(u8, kind.id, prefix)) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": field kind " ++ kind.id ++
                    " must be named " ++ prefix ++ "<name>");
            }
        }

        return list;
    }
}

/// What a compiled-in plugin holds: everything its `.permissions` ask for, as asked, and
/// its own content types.
pub fn grants_of(comptime Plugin: type) sdk.PluginGrants {
    comptime {
        const Ask = @import("../model/sandboxed_plugin.zig").Ask;
        const declared = plugin_define.has(Plugin, "permissions");
        const asks: []const Ask = if (declared) plugin_define.get(Plugin, "permissions") else &.{};
        var held: []const permission_model.Held = &.{};
        var own: []const []const u8 = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (asks) |ask| {
            held = held ++ &[_]permission_model.Held{ask.held()};
        }

        for (content_types_of(Plugin)) |def| {
            own = own ++ &[_][]const u8{def.handle};
        }

        const done_held = held;
        const done_own = own;

        return .{
            .name = Plugin.manifest.name,
            .access = .{
                .held = done_held,
                .own_types = done_own,
                .depends_on = depends_on.of(Plugin),
                .compatible_with = compatible_with_of(Plugin),
                .secrets = @import("plugin/secret_define.zig").declared_of(Plugin),
                .remotes = @import("plugin/remote_contract.zig").uses_of(Plugin),
            },
        };
    }
}

pub fn content_types_of(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "content_types")) {
            return &.{};
        }

        const list: []const ContentTypeDef = plugin_define.get(Plugin, "content_types");

        std.debug.assert(list.len <= content_types_max);

        return list;
    }
}

/// What a plugin uses of other plugins, `.remotes = &.{ Reserve, Variant, OutOfStock }`:
/// `publr.remote.operation`, `publr.remote.record` and `publr.remote.event`.
pub fn remotes_of(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "remotes")) {
            return &.{};
        }

        const list: []const type = plugin_define.get(Plugin, "remotes");

        for (list) |Used| {
            const known = @hasDecl(Used, "remote") or @hasDecl(Used, "remote_record") or
                @hasDecl(Used, "remote_event");

            if (!known) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": `remotes` lists only " ++
                    "`publr.remote.operation`, `publr.remote.record` and `publr.remote.event`");
            }
        }

        return list;
    }
}

/// A remote's name: the operation's, the record type's or the event's.
pub fn remote_name(comptime Used: type) []const u8 {
    comptime {
        std.debug.assert(@typeInfo(Used) == .@"struct");

        if (@hasDecl(Used, "remote_record")) {
            return Used.remote_record;
        }

        if (@hasDecl(Used, "remote_event")) {
            return Used.remote_event;
        }

        return Used.name;
    }
}

/// The plugins it works with when present, without needing them: `name` or `name@range`.
pub fn compatible_with_of(comptime Plugin: type) []const []const u8 {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "compatible_with")) {
            return &.{};
        }

        return plugin_define.get(Plugin, "compatible_with");
    }
}

pub fn internal_records_of(comptime Plugin: type) []const InternalCollection {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "internal_records")) {
            return &.{};
        }

        return plugin_define.get(Plugin, "internal_records");
    }
}

pub fn custom_fields_of(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "custom_fields")) {
            return &.{};
        }

        const list: []const ContentTypeDef = plugin_define.get(Plugin, "custom_fields");

        std.debug.assert(list.len <= content_types_max);

        for (list) |def| {
            if (def.group.location.len == 0) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": custom field group " ++
                    def.handle ++ " needs its location (destination user or media)");
            }
        }

        return list;
    }
}

pub fn assert_name(comptime name: []const u8, comptime label: []const u8) void {
    comptime {
        if (name.len == 0 or name.len > name_len_max) {
            @compileError("plugin " ++ label ++ ": `manifest.name` must be 1 to 32 characters");
        }

        for (name, 0..) |char, index| {
            const lower = char >= 'a' and char <= 'z';
            const digit = char >= '0' and char <= '9';
            const ok = lower or char == '_' or (digit and index > 0);

            if (!ok) {
                const rule = ": `manifest.name` is [a-z][a-z0-9_]*: ";
                @compileError("plugin " ++ label ++ rule ++ name);
            }
        }
    }
}

pub fn operations_of(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "operations")) {
            return &.{};
        }

        const list: []const type = plugin_define.get(Plugin, "operations");

        std.debug.assert(list.len <= sdk.operations_max);

        return list;
    }
}

pub fn namespaces_of(comptime Plugin: type) []const sdk.operation.Namespace {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "namespaces")) {
            return &.{};
        }

        const list: []const sdk.operation.Namespace = plugin_define.get(Plugin, "namespaces");

        std.debug.assert(list.len <= plugins_max);

        return list;
    }
}

/// The roles a plugin declares: a new name is a new role, granting nothing until its
/// operations or an administrator say; the name of one there already changes nothing.
pub fn roles_of(comptime Plugin: type) []const Role {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "roles")) {
            return &.{};
        }

        const list: []const Role = plugin_define.get(Plugin, "roles");

        std.debug.assert(list.len <= role.roles_max);

        for (list) |declared| {
            if (!role.valid_name(declared.name)) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": role " ++ declared.name ++
                    ": a name is [a-z][a-z0-9_]*, 1 to 32 characters");
            }
        }

        return list;
    }
}

pub fn policies_of(comptime Plugin: type) []const sdk.Policy {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "policies")) {
            return &.{};
        }

        const list: []const sdk.Policy = plugin_define.get(Plugin, "policies");

        std.debug.assert(list.len <= sdk.authorize.policies_max);

        return list;
    }
}

/// Every remote a plugin declares names a plugin it depends on or works with. When that
/// plugin is compiled in too: one it needs must fit, or the build fails; one it only works
/// with that does not fit (or is outside the range) is off, and why.
fn check_remotes(comptime plugins: anytype) []const remote_contract.Off {
    comptime {
        var off: []const remote_contract.Off = &.{};

        for (plugins) |Plugin| {
            for (remotes_of(Plugin)) |Used| {
                const name = remote_name(Used);
                const target = sdk.plugin_of(name);
                const label = "plugin " ++ Plugin.manifest.name ++ ": " ++ name ++ " ";

                const required = declared_in(depends_on.of(Plugin), target);
                const optional = declared_in(compatible_with_of(Plugin), target);
                const named = if (required != null) required else optional;
                const declared = named orelse @compileError(label ++ "belongs to " ++ target ++
                    ", named in neither `depends_on` nor `compatible_with`");

                for (plugins) |Provider| {
                    if (!std.mem.eql(u8, Provider.manifest.name, target)) {
                        continue;
                    }

                    const why = remote_contract.misfit_compiled(Used, Provider, declared) orelse
                        continue;

                    if (required != null) {
                        @compileError(label ++ "does not fit: " ++ why);
                    }

                    off = off ++ &[_]remote_contract.Off{.{
                        .plugin = Plugin.manifest.name,
                        .name = name,
                        .why = why,
                    }};
                }
            }
        }

        return off;
    }
}

/// The text in `list` that names `name` (`shelf`, `shelf@^0.1`), or null.
fn declared_in(comptime list: []const []const u8, comptime name: []const u8) ?[]const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        for (list) |text| {
            if (std.mem.eql(u8, depends_on.parse(text).name, name)) {
                return text;
            }
        }

        return null;
    }
}

/// A plugin's entries in `list`, each checked to name its own operations.
fn owned_items(comptime Plugin: type, comptime list: []const u8) []const OwnedItem {
    comptime {
        var owned: []const OwnedItem = &.{};

        for (admin_slots.items_of(Plugin, list)) |item| {
            const counted = if (item.count) |Count| owns_operation(Plugin, Count) else true;

            if (!owns_operation(Plugin, item.operation) or !counted) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": entry " ++ item.label ++
                    " names an operation not its own");
            }

            owned = owned ++ &[_]OwnedItem{.{
                .plugin = Plugin.manifest.name,
                .item = item,
            }};
        }

        return owned;
    }
}

/// Whether `Operation` is one the plugin declares.
pub fn owns_operation(comptime Plugin: type, comptime Operation: type) bool {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        for (operations_of(Plugin)) |Declared| {
            if (Declared == Operation) {
                return true;
            }
        }

        return false;
    }
}

/// The plugin's name `count` times: the owner of each of its operations or middlewares.
fn owners(comptime Plugin: type, comptime count: u32) []const []const u8 {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        var names: []const []const u8 = &.{};

        for (0..count) |_| {
            names = names ++ &[_][]const u8{Plugin.manifest.name};
        }

        return names;
    }
}

pub fn middleware_of(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "middleware")) {
            return &.{};
        }

        const list: []const type = plugin_define.get(Plugin, "middleware");

        std.debug.assert(list.len <= sdk.middleware.middleware_max);

        return list;
    }
}

pub fn jobs_of(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "jobs")) {
            return &.{};
        }

        const list: []const type = plugin_define.get(Plugin, "jobs");

        for (list) |Job| {
            if (!job_define.is_job(Job)) {
                @compileError(Plugin.manifest.name ++ ": `.jobs` lists what `publr.job.define` " ++
                    "makes, not " ++ @typeName(Job));
            }
        }

        return list;
    }
}

/// The webhooks a plugin lists in `.webhooks`, each checked against its declared secrets.
pub fn webhooks_of(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "webhooks")) {
            return &.{};
        }

        const list: []const type = plugin_define.get(Plugin, "webhooks");
        const declared = @import("plugin/secret_define.zig").declared_of(Plugin);

        for (list) |Webhook| {
            if (!webhook_define.is_webhook(Webhook)) {
                @compileError(Plugin.manifest.name ++ ": `.webhooks` lists what " ++
                    "`publr.webhook.define` makes, not " ++ @typeName(Webhook));
            }

            for (declared) |secret| {
                if (std.mem.eql(u8, secret.name, Webhook.secret)) {
                    break;
                }
            } else @compileError(Plugin.manifest.name ++ ": webhook " ++ Webhook.name ++
                " is signed with " ++ Webhook.secret ++ ", not a secret in `.secrets`");
        }

        return list;
    }
}

pub fn schema_of(comptime Plugin: type) ?[:0]const u8 {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "schema_sql")) {
            return null;
        }

        const sql: [:0]const u8 = plugin_define.get(Plugin, "schema_sql");

        std.debug.assert(sql.len > 0);

        return sql;
    }
}

/// A plugin's migrations, each its own: a plugin migrates only its own tables.
pub fn migrations_of(comptime Plugin: type) []const db.migration.Migration {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!plugin_define.has(Plugin, "migrations")) {
            return &.{};
        }

        const list: []const db.migration.Migration = plugin_define.get(Plugin, "migrations");

        for (list) |migration| {
            if (!std.mem.eql(u8, migration.source, Plugin.manifest.name)) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": migration " ++
                    migration.name ++ " names `" ++ migration.source ++ "` as its source");
            }
        }

        std.debug.assert(list.len <= db.migration.migrations_max);

        return list;
    }
}

/// What a plugin's routes may live under: its name and its namespaces.
fn owned_of(comptime Plugin: type) []const []const u8 {
    comptime {
        var owned: []const []const u8 = &.{Plugin.manifest.name};

        for (namespaces_of(Plugin)) |namespace| {
            owned = owned ++ &[_][]const u8{namespace.name};
        }

        std.debug.assert(owned.len > 0);

        return owned;
    }
}

pub fn Merged(comptime plugins: anytype) type {
    comptime {
        @setEvalBranchQuota(100_000);

        var operations: []const type = &.{};
        var namespaces: []const sdk.operation.Namespace = &.{};
        var policies: []const sdk.Policy = &.{};
        var middleware: []const type = &.{};
        var operation_owners: []const []const u8 = &.{};
        var middleware_owners: []const []const u8 = &.{};
        var jobs: []const type = &.{};
        var job_owners: []const []const u8 = &.{};
        var webhooks: []const type = &.{};
        var webhook_owners: []const []const u8 = &.{};
        var plugin_grants: []const sdk.PluginGrants = &.{};
        var internal_collections: []const OwnedCollection = &.{};
        var schemas: []const [:0]const u8 = &.{};
        var migrations: []const db.migration.Migration = &.{};
        var field_kinds: []const kinds.Kind = &.{};
        var content_types: []const DeclaredType = &.{};
        var custom_fields: []const DeclaredType = &.{};
        var filters: []const filter_module.Definition = &.{};
        var delivery_gates: []const sdk.delivery.Gate = &.{};
        var sign_in_providers: []const SignInProvider = &.{};
        var routes: []const route.Declared = &.{};
        var settings_pages: []const OwnedSettingsPage = &.{};
        var row_actions: []const RowAction = &.{};
        var pages: []const OwnedPage = &.{};
        var top_bar: []const OwnedItem = &.{};
        var menu: []const @import("../model/sandboxed_plugin.zig").MenuEntry = &.{};
        var icons: []const @import("../model/sandboxed_plugin.zig").PluginIcon = &.{};
        var panels: []const OwnedPanel = &.{};
        var registered_statuses: []const @import("../model/flow.zig").Added = &.{};
        var sign_in_at: []const type = &.{};
        var admin_brand: []const type = &.{};
        var app_picker_segment: []const type = &.{};
        var dimension: ?variants.Dimension = null;
        var agents_tab: ?AgentsTab = null;
        var work_start: ?[]const u8 = null;
        var hosted = false;
        var settings_tabs: []const OwnedSettingsTab = &.{};
        var translations: []const OwnedTranslation = &.{};
        var operator_commands: []const route.DeclaredCommand = &.{};
        var before_command: []const type = &.{};
        var serving: []const type = &.{};

        std.debug.assert(plugins.len <= plugins_max);

        depends_on.check(plugins);

        const remotes_off = check_remotes(plugins);

        for (plugins) |Plugin| {
            validate(Plugin);
            operations = operations ++ operations_of(Plugin);
            operation_owners = operation_owners ++ owners(Plugin, operations_of(Plugin).len);
            namespaces = namespaces ++ namespaces_of(Plugin);
            policies = policies ++ policies_of(Plugin);
            const hooks = remote_contract.kept_hooks(Plugin, middleware_of(Plugin), remotes_off);

            middleware = middleware ++ hooks;
            middleware_owners = middleware_owners ++ owners(Plugin, hooks.len);
            // A webhook's delivery runs as one of its plugin's jobs.
            jobs = jobs ++ jobs_of(Plugin) ++ webhooks_of(Plugin);
            job_owners = job_owners ++ owners(Plugin, jobs_of(Plugin).len) ++
                owners(Plugin, webhooks_of(Plugin).len);
            webhooks = webhooks ++ webhooks_of(Plugin);
            webhook_owners = webhook_owners ++ owners(Plugin, webhooks_of(Plugin).len);
            plugin_grants = plugin_grants ++ &[_]sdk.PluginGrants{grants_of(Plugin)};

            for (internal_records_of(Plugin)) |collection| {
                internal_collections = internal_collections ++ &[_]OwnedCollection{.{
                    .owner = Plugin.manifest.name,
                    .collection = collection,
                }};
            }

            field_kinds = field_kinds ++ field_kinds_of(Plugin);
            const own_routes = route.routes_of(Plugin, owned_of(Plugin));

            routes = routes ++ own_routes;
            for (admin_slots.settings_pages_of(Plugin, own_routes)) |page| {
                const owned: OwnedSettingsPage = .{
                    .plugin = Plugin.manifest.name,
                    .page = page,
                };

                settings_pages = settings_pages ++ &[_]OwnedSettingsPage{owned};
            }
            row_actions = row_actions ++ admin_slots.row_actions_of(Plugin);

            // A tab may be gated by core's operations too, as a settings page may: a tab
            // over core's data (Users › Roles) is shown to whoever may read that data.
            for (admin_slots.settings_tabs_of(Plugin)) |tab| {
                settings_tabs = settings_tabs ++ &[_]OwnedSettingsTab{.{
                    .plugin = Plugin.manifest.name,
                    .tab = tab,
                }};
            }

            for (admin_slots.pages_of(Plugin)) |page| {
                const used = if (page.form) |form| [_]type{ form.read, form.save } else [_]type{
                    page.operation.?,
                    page.operation.?,
                };

                for (used) |Operation| {
                    if (!owns_operation(Plugin, Operation)) {
                        @compileError("plugin " ++ Plugin.manifest.name ++ ": page " ++
                            page.path ++ " uses " ++ Operation.name ++ ", not one of its own");
                    }
                }

                pages = pages ++ &[_]OwnedPage{.{
                    .plugin = Plugin.manifest.name,
                    .page = page,
                }};
            }

            top_bar = top_bar ++ owned_items(Plugin, "top_bar");

            for (admin_slots.panels_of(Plugin)) |panel| {
                if (!owns_operation(Plugin, panel.operation)) {
                    @compileError("plugin " ++ Plugin.manifest.name ++ ": panel " ++
                        panel.label ++ " is drawn by an operation not its own");
                }

                panels = panels ++ &[_]OwnedPanel{.{
                    .plugin = Plugin.manifest.name,
                    .panel = panel,
                }};
            }

            menu = menu ++ @import("plugin/menu_define.zig").entries_of(Plugin);

            if (plugin_define.bound(Plugin)) {
                const record_flow = @import("plugin/record_flow.zig");

                registered_statuses = registered_statuses ++ record_flow.registered_of(Plugin);
            }
            icons = icons ++ @import("plugin/menu_define.zig").icons_of(Plugin);

            if (plugin_define.has(Plugin, "sign_in_at")) {
                sign_in_at = sign_in_at ++ &[_]type{Plugin};
            }

            if (plugin_define.has(Plugin, "admin_brand")) {
                admin_brand = admin_brand ++ &[_]type{Plugin};
            }

            if (plugin_define.has(Plugin, "app_picker_segment")) {
                app_picker_segment = app_picker_segment ++ &[_]type{Plugin};
            }

            if (plugin_define.has(Plugin, "translations")) {
                for (plugin_define.get(Plugin, "translations")) |translation| {
                    translations = translations ++ &[_]OwnedTranslation{.{
                        .plugin = Plugin.manifest.name,
                        .translation = translation,
                    }};
                }
            }

            if (variants.of(Plugin)) |declared| {
                if (dimension != null) {
                    @compileError("two plugins declare `variants`; one dimension at a time");
                }

                if (!owns_operation(Plugin, declared.list)) {
                    @compileError("plugin " ++ Plugin.manifest.name ++
                        ": `variants.list` is one of its own operations");
                }

                dimension = declared;
            }

            if (plugin_define.has(Plugin, "agents_tab")) {
                if (agents_tab != null) {
                    @compileError("two plugins declare `agents_tab`; one at a time");
                }

                agents_tab = .{
                    .plugin = Plugin.manifest.name,
                    .html = plugin_define.get(Plugin, "agents_tab"),
                };
            }

            if (plugin_define.has(Plugin, "hosted")) {
                hosted = hosted or plugin_define.get(Plugin, "hosted");
            }

            if (plugin_define.has(Plugin, "work_start")) {
                if (work_start != null) {
                    @compileError("two plugins declare `work_start`; one at a time");
                }

                work_start = plugin_define.get(Plugin, "work_start").name;
            }

            operator_commands = operator_commands ++ route.operator_commands_of(Plugin);

            if (plugin_define.has(Plugin, "before_command")) {
                before_command = before_command ++ &[_]type{Plugin};
            }

            if (plugin_define.has(Plugin, "serving")) {
                serving = serving ++ &[_]type{Plugin};
            }
            for (content_types_of(Plugin)) |def| {
                content_types = content_types ++ &[_]DeclaredType{.{
                    .owner = Plugin.manifest.name,
                    .def = def,
                }};
            }

            for (custom_fields_of(Plugin)) |def| {
                custom_fields = custom_fields ++ &[_]DeclaredType{.{
                    .owner = Plugin.manifest.name,
                    .def = def,
                }};
            }

            if (schema_of(Plugin)) |sql| {
                schemas = schemas ++ &[_][:0]const u8{sql};
            }

            migrations = migrations ++ migrations_of(Plugin);

            if (plugin_define.has(Plugin, "filters")) {
                const declared: []const filter_module.Definition =
                    plugin_define.get(Plugin, "filters");

                filters = filters ++ declared;
            }

            if (plugin_define.has(Plugin, "delivery_gates")) {
                delivery_gates = delivery_gates ++
                    @as([]const sdk.delivery.Gate, plugin_define.get(Plugin, "delivery_gates"));
            }

            if (plugin_define.has(Plugin, "sign_in_provider")) {
                var declared: SignInProvider = plugin_define.get(Plugin, "sign_in_provider");

                declared.plugin = Plugin.manifest.name;
                sign_in_providers = sign_in_providers ++ &[_]SignInProvider{declared};
            }
        }

        if (delivery_gates.len > sdk.delivery.gates_max) {
            @compileError("more delivery gates than a site asks: " ++
                std.fmt.comptimePrint("{d}", .{sdk.delivery.gates_max}));
        }

        if (sign_in_providers.len > provider.providers_max) {
            @compileError("more sign-in providers than the login page holds: " ++
                std.fmt.comptimePrint("{d}", .{provider.providers_max}));
        }

        for (sign_in_providers, 0..) |declared, index| {
            for (sign_in_providers[index + 1 ..]) |other| {
                if (std.mem.eql(u8, declared.name, other.name)) {
                    @compileError("two plugins declare the sign-in provider " ++ declared.name);
                }
            }
        }

        for (plugins, 0..) |Plugin, index| {
            for (plugins, 0..) |Other, other_index| {
                const same_name = std.mem.eql(u8, Plugin.manifest.name, Other.manifest.name);

                if (other_index > index and same_name) {
                    @compileError("two plugins named " ++ Plugin.manifest.name);
                }
            }
        }

        route.assert_distinct(routes);

        for (content_types, 0..) |declared, index| {
            for (content_types[index + 1 ..]) |other| {
                if (std.mem.eql(u8, declared.def.handle, other.def.handle)) {
                    @compileError("two plugins declare the content type " ++ declared.def.handle);
                }
            }
        }

        for (custom_fields, 0..) |declared, index| {
            for (custom_fields[index + 1 ..]) |other| {
                if (std.mem.eql(u8, declared.def.handle, other.def.handle)) {
                    @compileError("two plugins declare the custom field group " ++
                        declared.def.handle);
                }
            }
        }

        return struct {
            pub const all = plugins;
            pub const merged_operations = operations;
            pub const merged_namespaces = namespaces;
            pub const merged_policies = policies;
            pub const merged_middleware = middleware;
            pub const merged_operation_owners = operation_owners;
            pub const merged_middleware_owners = middleware_owners;
            /// The remotes another compiled-in plugin switches off, and why.
            pub const merged_remotes_off = remotes_off;
            pub const merged_jobs = jobs;
            pub const merged_job_owners = job_owners;
            /// The webhooks compiled-in plugins declare, and the plugin of each.
            pub const merged_webhooks = webhooks;
            pub const merged_webhook_owners = webhook_owners;
            pub const merged_plugin_grants = plugin_grants;
            pub const merged_internal_collections = internal_collections;
            pub const merged_schemas = schemas;
            pub const merged_migrations = migrations;
            pub const merged_field_kinds = field_kinds;
            pub const merged_content_types = content_types;
            pub const merged_custom_fields = custom_fields;
            pub const merged_filters = filters;
            pub const merged_delivery_gates = delivery_gates;
            pub const merged_sign_in_providers = sign_in_providers;
            pub const merged_routes = routes;
            pub const merged_settings_pages = settings_pages;
            /// Every plugin's sections of System settings tabs, in name order.
            pub const merged_settings_tabs = settings_tabs;
            /// Every plugin's actions on other pages' rows, in name order.
            pub const merged_row_actions = row_actions;
            /// Every plugin's own pages, in name order.
            pub const merged_pages = pages;
            /// Every plugin's top bar entries, in name order.
            pub const merged_top_bar = top_bar;
            /// Every plugin's menu items, in name order.
            pub const merged_menu = menu;
            /// Every plugin's own icons, in name order.
            pub const merged_icons = icons;
            /// Every plugin's edit-form panels, in name order.
            pub const merged_panels = panels;
            /// Statuses plugins add to other plugins' flows, in name order.
            pub const merged_registered_statuses = registered_statuses;
            /// The plugins that may send someone who must sign in elsewhere, in name order.
            pub const merged_sign_in_at = sign_in_at;
            /// The plugins that say whose admin it is, in name order; the first that names
            /// one wins.
            pub const merged_admin_brand = admin_brand;
            /// The plugins that join a segment to the app picker, in name order.
            pub const merged_app_picker_segment = app_picker_segment;
            /// Every PO file the plugins bring, in plugin order.
            pub const merged_translations = translations;
            /// The variant dimension a plugin declares, if one does.
            pub const merged_variants = dimension;
            /// What a plugin shows in the Overview's "Your agent" tab, if one does.
            pub const merged_agents_tab = agents_tab;
            /// The operation `publr work start` runs, where a hosting service's plugin
            /// sends a device's work to a copy of the project (`pub const work_start`).
            pub const merged_work_start = work_start;
            /// A plugin says the project runs on a host (`pub const hosted = true`): its
            /// folder and binary are never on the machine of the person in its admin.
            pub const merged_hosted = hosted;
            /// The plugins that keep a `State`, in name order.
            pub const merged_stateful = state.stateful(plugins);
            pub const merged_operator_commands = operator_commands;
            /// The plugins with a CLI pre-command hook, in name order.
            pub const merged_before_command = before_command;
            /// The plugins with a hook for when `serve` listens, in name order.
            pub const merged_serving = serving;
        };
    }
}

pub const testing = struct {
    /// A plugin that can run in the sandbox: an operation, a hook asked for with a reason,
    /// and the permission it needs.
    pub const Greeter = struct {
        pub const manifest: Manifest = .{
            .name = "greeter",
            .version = "0.1.0",
            .summary = "Test plugin: greets, and counts the greetings as records",
        };
        pub const namespaces = [_]sdk.operation.Namespace{.{
            .name = "greeter",
            .summary = "Greetings",
            .details = "A test namespace for the sandbox.",
        }};
        pub const content_types = [_]ContentTypeDef{.{
            .handle = "greeting",
            .name = "Greeting",
            .title_field = "note",
            .fields = &.{.{
                .validation = .{
                    .required = true,
                },
                .name = "note",
                .label = "Note",
                .kind = "string",
            }},
        }};
        pub const permissions = [_]@import("../model/sandboxed_plugin.zig").Ask{.{
            .key = "records.write",
            .records = &.{"greeting"},
            .reason = "Keeps every greeting as a record",
        }};
        pub const operations = [_]type{Greet};
        pub const middleware = [_]type{Counted};

        pub const Greet = struct {
            pub const name = "greeter.greet";
            pub const description = "Greet someone";
            pub const kind: sdk.operation.Kind = .write;
            pub const In = struct {
                who: []const u8,
                times: u32 = 1,
            };
            pub const Out = struct {
                text: []const u8,
            };
            pub const example: In = .{
                .who = "world",
            };
            pub const example_out: Out = .{
                .text = "hello, world",
            };
            pub const field_docs: sdk.operation.Docs(In) = .{
                .who = "Whom to greet",
            };
            pub const deprecated: sdk.operation.Deprecated = .{
                .since = "0.1.0",
            };

            pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
                std.debug.assert(in.who.len > 0);
                std.debug.assert(ctx.now().ms >= 0);

                const text = std.fmt.allocPrint(ctx.arena(), "hello, {s}", .{in.who}) catch {
                    return error.OutOfMemory;
                };

                return .{
                    .text = text,
                };
            }
        };

        pub const Counted = struct {
            pub const stage: sdk.middleware.Stage = .after;
            pub const operation = "greeter.greet";
            pub const reason = "Says when someone was greeted";

            pub fn run(ctx: *PluginCtx, in: *Greet.In, out: *const Greet.Out) sdk.Error!void {
                std.debug.assert(out.text.len > 0);
                ctx.emit(Greeted, .{
                    .who = in.who,
                });
            }
        };

        pub const Greeted = hook_define.event(.{
            .name = "greeted",
            .payload = struct {
                who: []const u8,
            },
        });
    };

    pub const Hello = struct {
        pub const manifest: Manifest = .{
            .name = "hello",
            .version = "0.1.0",
            .summary = "Test plugin: records greetings as records of its own type",
        };
        pub const content_types = [_]ContentTypeDef{.{
            .handle = "greeting",
            .name = "Greeting",
            .title_field = "note",
            .fields = &.{.{
                .validation = .{
                    .required = true,
                },
                .name = "note",
                .label = "Note",
                .kind = "string",
            }},
        }};
        pub const field_kinds = [_]kinds.Kind{.{
            .id = "hello.mood",
            .label = "Mood",
            .description = "How the greeter felt",
            .icon = "user",
            .storage = .text,
            .convert_from = &.{"string"},
        }};
        pub const namespaces = [_]sdk.operation.Namespace{.{
            .name = "hello",
            .summary = "Greetings",
            .details = "A test namespace with one operation.",
        }};
        pub const operations = [_]type{Record};
        pub const middleware = [_]type{Counted};
        pub const policies = [_]sdk.Policy{&no_shouting};
        pub const routes = [_]Route{
            .{
                .path = "/api/hello/greeting",
                .handler = &greeting,
            },
            .{
                .method = .post,
                .path = "/api/hello/greeting",
                .handler = &greeting,
            },
            .{
                .method = .post,
                .path = "/api/hello/upload",
                .stream = &counted_upload,
            },
        };

        /// An upload taken a piece at a time, answered with how many bytes came.
        const counted_upload: route.Stream = .{
            .bytes_max = 1 << 20,
            .open = &upload_open,
            .write = &upload_write,
            .finish = &upload_finish,
            .abort = &upload_abort,
        };

        fn upload_open(
            request: *route.http.Request,
            _: *route.http.Response,
            _: *route.http.Context,
        ) anyerror!?*anyopaque {
            std.debug.assert(request.method() == .post);

            const received = try std.heap.page_allocator.create(u64);

            received.* = 0;

            return received;
        }

        fn upload_write(upload: *anyopaque, bytes: []const u8) anyerror!void {
            const received: *u64 = @ptrCast(@alignCast(upload));

            std.debug.assert(bytes.len > 0);

            received.* += bytes.len;
        }

        fn upload_finish(
            upload: *anyopaque,
            response: *route.http.Response,
            _: *route.http.Context,
        ) anyerror!void {
            const received: *u64 = @ptrCast(@alignCast(upload));
            defer std.heap.page_allocator.destroy(received);

            std.debug.assert(received.* <= counted_upload.bytes_max);

            try response.json(.created, .{
                .bytes = received.*,
            });
        }

        fn upload_abort(upload: *anyopaque) void {
            const received: *u64 = @ptrCast(@alignCast(upload));

            std.debug.assert(received.* <= counted_upload.bytes_max);
            std.heap.page_allocator.destroy(received);
        }

        /// Who is asking, as the route sees them.
        fn greeting(
            request: *route.http.Request,
            response: *route.http.Response,
            ctx: *route.http.Context,
        ) route.http.Error!void {
            const plugin_routes = @import("../server/plugin_routes.zig");
            const found = try plugin_routes.caller_context(request, response, ctx) orelse return;

            std.debug.assert(request.path().len > 0);

            try response.json(.ok, .{
                .caller = @tagName(found.caller),
            });
        }
        pub const roles = [_]Role{
            .{
                .name = "editor",
                .label = "Editor",
            },
            .{
                .name = "greeter",
                .label = "Greeter",
            },
        };

        pub const Record = struct {
            pub const name = "hello.record";
            pub const description = "Record a greeting";
            pub const kind: sdk.operation.Kind = .write;
            pub const In = struct {
                note: []const u8,
            };
            pub const Out = struct {
                rows: u32,
            };
            pub const example: In = .{
                .note = "hi",
            };
            pub const example_out: Out = .{
                .rows = 1,
            };

            pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
                std.debug.assert(in.note.len > 0);
                std.debug.assert(ctx.now().ms >= 0);

                const record = @import("../operations/record.zig");
                const document = try std.json.Stringify.valueAlloc(
                    ctx.arena(),
                    .{
                        .note = in.note,
                    },
                    .{},
                );

                _ = try ctx.call(record.Create, .{
                    .type = "greeting",
                    .document = document,
                });

                const all = try ctx.call(record.List, .{
                    .type = "greeting",
                    .limit = 200,
                });

                return .{
                    .rows = @intCast(all.records.len),
                };
            }
        };

        pub const Counted = struct {
            pub const stage: sdk.middleware.Stage = .after;
            pub const operation = "hello.record";

            pub fn run(ctx: *PluginCtx, in: *Record.In, out: *const Record.Out) sdk.Error!void {
                std.debug.assert(in.note.len > 0);
                std.debug.assert(out.rows > 0);
                ctx.emit(Recorded, .{
                    .note = in.note,
                });
            }
        };

        pub const Recorded = hook_define.event(.{
            .name = "recorded",
            .payload = struct {
                note: []const u8,
            },
        });

        fn no_shouting(_: *const sdk.Ctx, request: sdk.authorize.Request) sdk.Grant {
            std.debug.assert(request.operation_name.len > 0);

            return .{};
        }
    };
};

test "the test plugin passes the contract and merges into a registry" {
    const Bundle = Merged(.{testing.Hello});
    const TestSDK = sdk.SDK(.{
        .operations = Bundle.merged_operations,
        .namespaces = Bundle.merged_namespaces,
        .policies = Bundle.merged_policies,
        .middleware = Bundle.merged_middleware,
        .schemas = Bundle.merged_schemas,
    });

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try TestSDK.apply_schemas(&harness.fixture.connection);

    var system = harness.ctx(.system);
    try plugin_types.apply(&system, Bundle.merged_content_types);
    try sdk.stored_roles.declare(&system, "hello", comptime roles_of(testing.Hello));
    // What each role may call, granted as an administrator would.
    try @import("../store.zig").role_grants.add(system.db, "editor", &.{"hello.*"});
    try @import("../store.zig").role_grants.add(system.db, "greeter", &.{"hello.record"});

    var ctx = harness.ctx(.{
        .user = .{
            .id = "u_1",
            .roles = &.{"editor"},
        },
    });
    const first = try TestSDK.dispatch(&ctx, testing.Hello.Record, .{
        .note = "hi",
    });
    const second = try TestSDK.dispatch(&ctx, testing.Hello.Record, .{
        .note = "again",
    });

    try std.testing.expectEqual(@as(u32, 1), first.rows);
    try std.testing.expectEqual(@as(u32, 2), second.rows);

    // A plugin's role reaches what it was granted; an account holding no role, nothing.
    var greeter = harness.ctx(.{
        .user = .{
            .id = "u_2",
            .roles = &.{"greeter"},
        },
    });
    var nobody = harness.ctx(.{
        .user = .{
            .id = "u_3",
            .roles = &.{},
        },
    });
    try std.testing.expect(TestSDK.may(&greeter, testing.Hello.Record));
    try std.testing.expect(!TestSDK.may(&nobody, testing.Hello.Record));
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&nobody, testing.Hello.Record, .{
        .note = "no",
    }));
    try std.testing.expect(TestSDK.namespace_of("hello") != null);
    try std.testing.expectEqual(@as(usize, 1), Bundle.merged_policies.len);
    try std.testing.expectEqual(@as(usize, 1), Bundle.merged_field_kinds.len);
    try std.testing.expectEqualStrings("hello.mood", Bundle.merged_field_kinds[0].id);
}

test {
    _ = job_define;
    _ = plugin_manifest;
    _ = wire;
    _ = runtime;
    _ = @import("plugin/remote_fields.zig");
    _ = @import("plugin/remote_contract.zig");
    _ = @import("plugin/admin_described.zig");
    _ = @import("plugin/doc_imports.zig");
    _ = @import("plugin/view_wire.zig");
    _ = @import("plugin/host.zig");
}

/// A plugin that emits its own event: an `after` hook keeps it inside the write and refuses
/// "nobody"; an `on` hook hears it from the queue.
const Teller = struct {
    pub const manifest: Manifest = .{
        .name = "teller",
        .version = "0.1.0",
        .summary = "Test plugin: tells and hears",
    };
    pub const operations = [_]type{Tell};
    pub const middleware = [_]type{
        hook_define.Described(hook_define.after(Told, kept), "teller", null),
        hook_define.Described(hook_define.on(Told, heard), "teller", null),
        hook_define.Described(hook_define.on(Tell, answered), "teller", null),
    };

    pub const Told = hook_define.event(.{
        .name = "told",
        .payload = struct {
            who: []const u8,
        },
    });

    pub const Tell = struct {
        pub const name = "teller.tell";
        pub const description = "Tell someone";
        pub const kind: sdk.operation.Kind = .write;
        pub const In = struct {
            who: []const u8,
        };
        pub const Out = struct {
            told: []const u8,
        };
        pub const example: In = .{
            .who = "ada",
        };
        pub const example_out: Out = .{
            .told = "ada",
        };

        pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
            std.debug.assert(in.who.len > 0);

            ctx.emit(Told, .{
                .who = in.who,
            });

            return .{
                .told = in.who,
            };
        }
    };

    fn kept(ctx: *PluginCtx, told: Told.Payload) sdk.Error!void {
        std.debug.assert(ctx.inner.db.transaction_depth >= 1);

        if (std.mem.eql(u8, told.who, "nobody")) {
            return error.Conflict;
        }

        try line(ctx, "kept", told.who);
    }

    fn heard(ctx: *QueueCtx, told: Told.Payload) sdk.Error!void {
        std.debug.assert(ctx.base.inner.db.transaction_depth == 0);

        try line(ctx.base, "heard", told.who);
    }

    fn answered(ctx: *QueueCtx, out: Tell.Out) sdk.Error!void {
        std.debug.assert(ctx.base.inner.db.transaction_depth == 0);

        try line(ctx.base, "answered", out.told);
    }

    const QueueCtx = @import("plugin/queue.zig").Queue(PluginCtx);

    fn line(ctx: *PluginCtx, comptime what: []const u8, who: []const u8) sdk.Error!void {
        std.debug.assert(who.len > 0);

        var insert = try ctx.inner.db.prepare("INSERT INTO told (what, who) VALUES (?1, ?2)");
        defer insert.finalize();

        try insert.bind_text(1, what);
        try insert.bind_text(2, who);
        try insert.exec();
    }
};

test "a plugin's event: after hooks in the write, on hooks from the queue, a refusal rolls back" {
    const Bundle = Merged(.{Teller});
    const TestSDK = sdk.SDK(.{
        .operations = Bundle.merged_operations,
        .middleware = Bundle.merged_middleware,
        .operation_owners = Bundle.merged_operation_owners,
        .middleware_owners = Bundle.merged_middleware_owners,
    });

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    try ctx.db.exec("CREATE TABLE told (what TEXT NOT NULL, who TEXT NOT NULL)");

    _ = try TestSDK.dispatch(&ctx, Teller.Tell, .{
        .who = "ada",
    });

    // The `after` hook ran in the write; nothing heard from the queue yet.
    try std.testing.expectEqual(@as(u32, 1), try sdk.testing.count(&ctx, "told"));
    try std.testing.expectEqual(@as(u32, 2), try sdk.testing.count(&ctx, "job_queue"));

    // Refused by the `after` hook: the write and its events are gone.
    try std.testing.expectError(error.Conflict, TestSDK.dispatch(&ctx, Teller.Tell, .{
        .who = "nobody",
    }));
    try std.testing.expectEqual(@as(u32, 1), try sdk.testing.count(&ctx, "told"));
    try std.testing.expectEqual(@as(u32, 2), try sdk.testing.count(&ctx, "job_queue"));

    var worker = harness.ctx(.system);
    try std.testing.expectEqual(@as(u32, 2), try TestSDK.jobs.drain(&worker, 8));

    var select = try ctx.db.prepare("SELECT what, who FROM told ORDER BY rowid");
    defer select.finalize();

    const Row = struct {
        what: []const u8,
        who: []const u8,
    };
    const expected = [_][2][]const u8{
        .{ "kept", "ada" },
        .{ "heard", "ada" },
        .{ "answered", "ada" },
    };

    for (expected) |pair| {
        try std.testing.expect(try select.step());

        const row = try select.read(Row, harness.fixed.allocator());

        try std.testing.expectEqualStrings(pair[0], row.what);
        try std.testing.expectEqualStrings(pair[1], row.who);
    }

    try std.testing.expect(!try select.step());
}

test "a remote operation that fits the compiled-in one it names; the manifest carries both" {
    const Provider = struct {
        pub const manifest: Manifest = .{
            .name = "provider",
            .version = "1.2.0",
            .summary = "Provides an operation",
        };
        pub const namespaces = [_]sdk.operation.Namespace{.{
            .name = "provider",
            .summary = "Its operations",
            .details = "One operation.",
        }};
        pub const operations = [_]type{Adjust};
        pub const Adjust = struct {
            pub const name = "provider.adjust";
            pub const description = "Adjust a count";
            pub const kind: sdk.operation.Kind = .write;
            pub const In = struct {
                sku: []const u8,
                delta: i64,
                note: ?[]const u8 = null,
            };
            pub const Out = struct {
                total: i64,
                sku: []const u8,
            };
            pub const example: In = .{
                .sku = "a",
                .delta = 1,
            };
            pub const example_out: Out = .{
                .total = 1,
                .sku = "a",
            };

            pub fn run(_: *sdk.Ctx, in: In, _: *const sdk.Grant) sdk.Error!Out {
                return .{
                    .total = in.delta,
                    .sku = in.sku,
                };
            }
        };
    };
    const User = struct {
        pub const manifest: Manifest = .{
            .name = "user_side",
            .version = "0.1.0",
            .summary = "Uses the provider",
        };
        pub const compatible_with = .{"provider@^1.0"};
        pub const remotes = [_]type{Adjust};
        pub const Adjust = @import("plugin/hook_define.zig").remote.operation(
            "provider.adjust",
            struct {
                sku: []const u8,
                delta: i64,
            },
            struct {
                total: i64,
            },
        );
    };
    const Bundle = Merged(.{ Provider, User });

    try std.testing.expectEqual(@as(usize, 1), Bundle.merged_operations.len);
    try std.testing.expectEqual(@as(usize, 1), comptime remotes_of(User).len);

    const written = comptime @import("plugin/manifest.zig").of(User);

    try std.testing.expectEqualStrings("provider.adjust", written.remotes[0].name);
    try std.testing.expectEqualStrings("provider@^1.0", written.compatible_with[0]);
    try std.testing.expectEqual(@as(usize, 3), written.remotes[0].input.len);
}
