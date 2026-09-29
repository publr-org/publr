const std = @import("std");
const sdk = @import("../sdk.zig");
const plugin_context = @import("plugin/context.zig");
const plugin_types = @import("plugin/types.zig");
const status_module = @import("../model/status.zig");
const filter_module = @import("../model/filter.zig");
const content_type = @import("../model/content_type.zig");
const field = @import("../model/field.zig");
const kinds = @import("../model/kinds.zig");
const role = @import("../model/role.zig");
const provider = @import("provider.zig");
const runtime = @import("plugin/sandboxed.zig");

pub const PluginCtx = plugin_context.PluginCtx;
pub const types = plugin_types;
pub const ContentTypeDef = content_type.Def;
pub const DeclaredType = plugin_types.Declared;
pub const Role = role.Role;
pub const SignInProvider = provider.SignInProvider;
/// What a plugin declares to run in the sandbox: see `plugin/sandboxed.zig`.
pub const Permission = runtime.Permission;
pub const Limits = runtime.Limits;
pub const ContentAccess = runtime.ContentAccess;
pub const Entry = runtime.Entry;
pub const runtime_entries = runtime.runtime_entries;
pub const HookIn = runtime.HookIn;
pub const HookOut = runtime.HookOut;
pub const plugin_manifest = @import("plugin/manifest.zig");
pub const wire = @import("plugin/wire.zig");
pub const guest = @import("plugin/guest.zig");
pub const content_types_max: u32 = 64;

pub const name_len_max: u32 = 32;
pub const version_len_max: u32 = 32;
pub const summary_len_max: u32 = 200;
pub const plugins_max: u32 = 64;

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    native_only: bool = false,
};

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

            if (!manifest.native_only and !plugin_context.takes_plugin_ctx(Operation.run)) {
                @compileError("plugin " ++ manifest.name ++ ": " ++ Operation.name ++
                    " must take *PluginCtx (or set manifest.native_only)");
            }
        }

        for (middleware_of(Plugin)) |Middleware| {
            sdk.middleware.validate(Middleware);

            if (!manifest.native_only and !plugin_context.takes_plugin_ctx(Middleware.run)) {
                @compileError("plugin " ++ manifest.name ++ ": a hook must take *PluginCtx " ++
                    "(or set manifest.native_only)");
            }
        }

        if (@hasDecl(Plugin, "schema_sql") and Plugin.schema_sql.len == 0) {
            @compileError("plugin " ++ manifest.name ++ ": `schema_sql` is empty");
        }

        if (@hasDecl(Plugin, "schema_sql") and !manifest.native_only) {
            @compileError("plugin " ++ manifest.name ++ ": own tables need native_only");
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

        if (@hasDecl(Plugin, "bootstrap")) {
            const Bootstrap = @TypeOf(Plugin.bootstrap);
            const expected = fn (*sdk.Ctx) sdk.Error!void;

            if (Bootstrap != expected) {
                @compileError("plugin " ++ name ++ ": `bootstrap` is " ++
                    "`pub fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void`");
            }
        }

        if (@hasDecl(Plugin, "sign_in_provider")) {
            const declared: SignInProvider = Plugin.sign_in_provider;

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

        if (!@hasDecl(Plugin, "field_kinds")) {
            return &.{};
        }

        const list: []const kinds.Kind = &Plugin.field_kinds;
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

pub fn content_types_of(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "content_types")) {
            return &.{};
        }

        const list: []const ContentTypeDef = &Plugin.content_types;

        std.debug.assert(list.len <= content_types_max);

        return list;
    }
}

/// The custom field groups a plugin declares on users or media, each with its location
/// rules (`destination`); created or updated when the database opens, fields locked.
pub fn custom_fields_of(comptime Plugin: type) []const ContentTypeDef {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "custom_fields")) {
            return &.{};
        }

        const list: []const ContentTypeDef = &Plugin.custom_fields;

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

        if (!@hasDecl(Plugin, "operations")) {
            return &.{};
        }

        const list: []const type = &Plugin.operations;

        std.debug.assert(list.len <= sdk.operations_max);

        return list;
    }
}

pub fn namespaces_of(comptime Plugin: type) []const sdk.operation.Namespace {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "namespaces")) {
            return &.{};
        }

        const list: []const sdk.operation.Namespace = &Plugin.namespaces;

        std.debug.assert(list.len <= plugins_max);

        return list;
    }
}

/// The roles a plugin declares: a new name is a new role; the name of one there already
/// (`editor`) adds grants to it.
pub fn roles_of(comptime Plugin: type) []const Role {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "roles")) {
            return &.{};
        }

        const list: []const Role = &Plugin.roles;

        std.debug.assert(list.len <= role.roles_max);

        for (list) |declared| {
            if (!role.valid_name(declared.name)) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": role " ++ declared.name ++
                    ": a name is [a-z][a-z0-9_]*, 1 to 32 characters");
            }

            for (declared.grants) |grant| {
                if (!role.valid_grant(grant)) {
                    @compileError("plugin " ++ Plugin.manifest.name ++ ": role " ++
                        declared.name ++ ": grant `" ++ grant ++ "` is `*`, an operation, " ++
                        "or a namespace ending in `.*`");
                }
            }
        }

        return list;
    }
}

pub fn policies_of(comptime Plugin: type) []const sdk.Policy {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "policies")) {
            return &.{};
        }

        const list: []const sdk.Policy = &Plugin.policies;

        std.debug.assert(list.len <= sdk.authorize.policies_max);

        return list;
    }
}

pub fn middleware_of(comptime Plugin: type) []const type {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "middleware")) {
            return &.{};
        }

        const list: []const type = &Plugin.middleware;

        std.debug.assert(list.len <= sdk.middleware.middleware_max);

        return list;
    }
}

pub fn schema_of(comptime Plugin: type) ?[:0]const u8 {
    comptime {
        std.debug.assert(@hasDecl(Plugin, "manifest"));

        if (!@hasDecl(Plugin, "schema_sql")) {
            return null;
        }

        const sql: [:0]const u8 = Plugin.schema_sql;

        std.debug.assert(sql.len > 0);

        return sql;
    }
}

pub fn Merged(comptime plugins: anytype) type {
    comptime {
        @setEvalBranchQuota(100_000);

        var operations: []const type = &.{};
        var namespaces: []const sdk.operation.Namespace = &.{};
        var policies: []const sdk.Policy = &.{};
        var middleware: []const type = &.{};
        var schemas: []const [:0]const u8 = &.{};
        var statuses: []const status_module.Status = &.{};
        var transitions: []const status_module.Transition = &.{};
        var field_kinds: []const kinds.Kind = &.{};
        var content_types: []const DeclaredType = &.{};
        var custom_fields: []const DeclaredType = &.{};
        var filters: []const filter_module.Definition = &.{};
        var delivery_gates: []const sdk.delivery.Gate = &.{};
        var roles: []const Role = &.{};
        var sign_in_providers: []const SignInProvider = &.{};

        std.debug.assert(plugins.len <= plugins_max);

        for (plugins) |Plugin| {
            validate(Plugin);
            operations = operations ++ operations_of(Plugin);
            namespaces = namespaces ++ namespaces_of(Plugin);
            policies = policies ++ policies_of(Plugin);
            roles = roles ++ roles_of(Plugin);
            middleware = middleware ++ middleware_of(Plugin);
            field_kinds = field_kinds ++ field_kinds_of(Plugin);
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

            if (@hasDecl(Plugin, "statuses")) {
                statuses = statuses ++ @as([]const status_module.Status, &Plugin.statuses);
            }

            if (@hasDecl(Plugin, "filters")) {
                filters = filters ++ @as([]const filter_module.Definition, &Plugin.filters);
            }

            if (@hasDecl(Plugin, "delivery_gates")) {
                delivery_gates = delivery_gates ++
                    @as([]const sdk.delivery.Gate, &Plugin.delivery_gates);
            }

            if (@hasDecl(Plugin, "sign_in_provider")) {
                sign_in_providers = sign_in_providers ++
                    &[_]SignInProvider{Plugin.sign_in_provider};
            }

            if (@hasDecl(Plugin, "transitions")) {
                transitions = transitions ++ @as(
                    []const status_module.Transition,
                    &Plugin.transitions,
                );
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
            pub const merged_schemas = schemas;
            pub const merged_statuses = statuses;
            pub const merged_transitions = transitions;
            pub const merged_field_kinds = field_kinds;
            pub const merged_content_types = content_types;
            pub const merged_custom_fields = custom_fields;
            pub const merged_filters = filters;
            pub const merged_delivery_gates = delivery_gates;
            pub const merged_sign_in_providers = sign_in_providers;
            /// The core roles with every plugin's merged in.
            pub const merged_roles = role.merge(&role.core, roles);
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
            .fields = &.{.{ .name = "note", .label = "Note", .kind = "string", .required = true }},
        }};
        pub const permissions = [_]Permission{.{
            .key = "content.write",
            .reason = "Keeps every greeting as a record",
        }};
        pub const operations = [_]type{Greet};
        pub const middleware = [_]type{Counted};

        pub const Greet = struct {
            pub const name = "greeter.greet";
            pub const description = "Greet someone";
            pub const kind: sdk.operation.Kind = .write;
            pub const In = struct { who: []const u8, times: u32 = 1 };
            pub const Out = struct { text: []const u8 };
            pub const example: In = .{ .who = "world" };
            pub const example_out: Out = .{ .text = "hello, world" };
            pub const field_docs: sdk.operation.Docs(In) = .{ .who = "Whom to greet" };

            pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
                std.debug.assert(in.who.len > 0);
                std.debug.assert(ctx.now_ms() >= 0);

                const text = std.fmt.allocPrint(ctx.arena(), "hello, {s}", .{in.who}) catch {
                    return error.OutOfMemory;
                };

                return .{ .text = text };
            }
        };

        pub const Counted = struct {
            pub const stage: sdk.middleware.Stage = .after;
            pub const operation = "greeter.greet";
            pub const reason = "Says when someone was greeted";

            pub fn run(ctx: *PluginCtx, in: *Greet.In, out: *const Greet.Out) sdk.Error!void {
                std.debug.assert(out.text.len > 0);
                ctx.notice("greeter.greeted", in.who);
            }
        };
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
            .fields = &.{.{ .name = "note", .label = "Note", .kind = "string", .required = true }},
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
        pub const roles = [_]Role{
            .{ .name = "editor", .label = "Editor", .grants = &.{"hello.*"} },
            .{
                .name = "greeter",
                .label = "Greeter",
                .grants = &.{"hello.record"},
            },
        };

        pub const Record = struct {
            pub const name = "hello.record";
            pub const description = "Record a greeting";
            pub const kind: sdk.operation.Kind = .write;
            pub const In = struct { note: []const u8 };
            pub const Out = struct { rows: u32 };
            pub const example: In = .{ .note = "hi" };
            pub const example_out: Out = .{ .rows = 1 };

            pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
                std.debug.assert(in.note.len > 0);
                std.debug.assert(ctx.now_ms() >= 0);

                const record = @import("../operations/record.zig");
                const document = try std.json.Stringify.valueAlloc(
                    ctx.arena(),
                    .{ .note = in.note },
                    .{},
                );

                _ = try ctx.call(record.Create, .{ .type = "greeting", .document = document });

                const all = try ctx.call(record.List, .{ .type = "greeting", .limit = 200 });

                return .{ .rows = @intCast(all.records.len) };
            }
        };

        pub const Counted = struct {
            pub const stage: sdk.middleware.Stage = .after;
            pub const operation = "hello.record";

            pub fn run(ctx: *PluginCtx, in: *Record.In, out: *const Record.Out) sdk.Error!void {
                std.debug.assert(in.note.len > 0);
                std.debug.assert(out.rows > 0);
                ctx.notice("hello.recorded", in.note);
            }
        };

        fn no_shouting(_: *const sdk.Ctx, request: sdk.authorize.Request) sdk.Grant {
            std.debug.assert(request.operation_name.len > 0);
            std.debug.assert(request.resource.fields.len == 0);

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
        .roles = Bundle.merged_roles,
    });

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    try TestSDK.apply_schemas(&harness.fixture.connection);

    var system = harness.ctx(.system);
    try plugin_types.apply(&system, Bundle.merged_content_types);

    var ctx = harness.ctx(.{ .user = .{ .id = "u_1", .roles = &.{"editor"} } });
    const first = try TestSDK.dispatch(&ctx, testing.Hello.Record, .{ .note = "hi" });
    const second = try TestSDK.dispatch(&ctx, testing.Hello.Record, .{ .note = "again" });

    try std.testing.expectEqual(@as(u32, 1), first.rows);
    try std.testing.expectEqual(@as(u32, 2), second.rows);

    // A plugin's role reaches what it grants; an account holding no role, nothing.
    var greeter = harness.ctx(.{ .user = .{ .id = "u_2", .roles = &.{"greeter"} } });
    var nobody = harness.ctx(.{ .user = .{ .id = "u_3", .roles = &.{} } });
    try std.testing.expect(TestSDK.may(&greeter, testing.Hello.Record));
    try std.testing.expect(!TestSDK.may(&nobody, testing.Hello.Record));
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&nobody, testing.Hello.Record, .{
        .note = "no",
    }));
    try std.testing.expectEqual(@as(usize, 3), Bundle.merged_roles.len);
    try std.testing.expect(TestSDK.namespace_of("hello") != null);
    try std.testing.expectEqual(@as(usize, 1), Bundle.merged_policies.len);
    try std.testing.expectEqual(@as(usize, 1), Bundle.merged_field_kinds.len);
    try std.testing.expectEqualStrings("hello.mood", Bundle.merged_field_kinds[0].id);
}

test {
    _ = plugin_manifest;
    _ = wire;
    _ = runtime;
}
