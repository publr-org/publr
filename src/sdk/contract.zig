//! Contracts and their providers. A contract is a named set of operations providers
//! implement, owned by core or any plugin: `publr.contract.define(.{ .name, .operations,
//! .optional, .component })`, each part a struct with `In` and `Out`. A plugin registers a
//! provider with `.register_providers`, naming its own operations for the parts; the build
//! checks each against the part's shapes. The owner never names providers: it lists the
//! enabled ones, in the administrator's order, with `publr.providers(ctx, Contract, .{})`.
const std = @import("std");
const plugin_define = @import("plugin/define.zig");
const sdk = @import("../sdk.zig");
const shapes = @import("../model/contract.zig");
const store = @import("../store.zig");

pub const providers_max: u32 = 64;
pub const parts_max = registered_model.parts_max;
pub const name_len_max: u32 = 64;

/// Whether a contract's providers bring a UI of their own, drawn in a slot the owner leaves
/// for the chosen provider.
pub const Component = published_model.Component;

pub const Part = registered_model.Part;
pub const Registered = registered_model.Registered;

const registered_model = @import("../model/provider.zig");
const published_model = @import("../model/published.zig");

/// `publr.contract.define(.{ .name = "messaging", .operations = .{ .send = Send },
/// .optional = .{ .receipt = Receipt }, .component = .optional })`.
pub fn define(comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            const known = [_][]const u8{ "name", "operations", "optional", "component" };

            if (!in_list(&known, given)) {
                @compileError("contract: no option `." ++ given ++ "`");
            }
        }

        if (!@hasField(Options, "name") or !@hasField(Options, "operations")) {
            @compileError("a contract needs `.name` and `.operations`");
        }

        const name: []const u8 = options.name;

        if (name.len == 0 or name.len > name_len_max) {
            @compileError("contract `" ++ name ++ "`: `.name` is 1 to 64 characters");
        }

        const optional = if (@hasField(Options, "optional")) options.optional else .{};
        const required_parts = std.meta.fieldNames(@TypeOf(options.operations));

        if (required_parts.len == 0) {
            @compileError("contract " ++ name ++ ": `.operations` names at least one part");
        }

        for (required_parts ++ std.meta.fieldNames(@TypeOf(optional))) |part| {
            const Shape = part_type(options.operations, optional, part).?;

            if (!@hasDecl(Shape, "In") or !@hasDecl(Shape, "Out")) {
                @compileError("contract " ++ name ++ ": part `" ++ part ++ "` is a struct " ++
                    "with `In` and `Out`");
            }
        }

        return struct {
            pub const publr_contract_definition = true;
            pub const contract_name = name;
            /// Defined here, in Zig: its owner calls it with these types.
            pub const owner: []const u8 = "";
            pub const operations = options.operations;
            pub const optional_parts = optional;
            pub const component: Component = if (@hasField(Options, "component"))
                options.component
            else
                .none;
            /// Each part with its shapes as data, as a published interface carries them.
            pub const parts = parts_of(options.operations, optional);

            /// The part's `In` and `Out`, required or optional.
            pub fn Shape(comptime part: []const u8) type {
                return part_type(operations, optional_parts, part) orelse
                    @compileError("contract " ++ name ++ " has no part `" ++ part ++ "`");
            }

            pub fn required(comptime part: []const u8) bool {
                return @hasField(@TypeOf(operations), part);
            }
        };
    }
}

fn parts_of(comptime operations: anytype, comptime optional: anytype) []const PublishedPart {
    comptime {
        var list: []const PublishedPart = &.{};

        for (std.meta.fieldNames(@TypeOf(operations))) |part| {
            list = list ++ &[_]PublishedPart{part_of(@field(operations, part), part, true)};
        }

        for (std.meta.fieldNames(@TypeOf(optional))) |part| {
            list = list ++ &[_]PublishedPart{part_of(@field(optional, part), part, false)};
        }

        if (list.len > published_model.parts_max) {
            @compileError("a contract has at most 16 parts");
        }

        const done = list;

        return done;
    }
}

fn part_of(comptime Shape: type, comptime name: []const u8, comptime required: bool) PublishedPart {
    comptime {
        std.debug.assert(name.len > 0);

        return .{
            .name = name,
            .required = required,
            .input = shapes.describe(Shape.In),
            .output = shapes.describe(Shape.Out),
        };
    }
}

pub const PublishedPart = published_model.Part;

/// Another plugin's contract as its published interface describes it: `payments.method`,
/// owned by `payments`. Only provided, never called (its owner calls it): a provider's
/// operations are checked against its parts' shapes as they are checked against a defined
/// contract's types.
pub fn published(comptime owner_name: []const u8, comptime data: published_model.Contract) type {
    comptime {
        std.debug.assert(owner_name.len > 0);
        std.debug.assert(data.name.len > 0);

        return struct {
            pub const publr_contract_definition = true;
            pub const contract_name = data.name;
            pub const owner = owner_name;
            pub const component: Component = data.component;
            pub const parts = data.parts;

            pub fn Shape(comptime part: []const u8) type {
                @compileError("contract " ++ data.name ++ " is " ++ owner_name ++ "'s: its " ++
                    "providers answer `" ++ part ++ "`; only " ++ owner_name ++ " calls it");
            }

            pub fn required(comptime part: []const u8) bool {
                const found = comptime published_part(parts, part) orelse
                    @compileError("contract " ++ data.name ++ " has no part `" ++ part ++ "`");

                return found.required;
            }
        };
    }
}

fn published_part(comptime parts: []const PublishedPart, comptime name: []const u8) ?PublishedPart {
    comptime {
        std.debug.assert(name.len > 0);

        for (parts) |part| {
            if (std.mem.eql(u8, part.name, name)) {
                return part;
            }
        }

        return null;
    }
}

/// The contracts a plugin owns (`.contracts`), as its published interface carries them:
/// each defined with `publr.contract.define`, named under the plugin (`payments.method`).
pub fn owned_of(comptime Plugin: type) []const published_model.Contract {
    comptime {
        const plugin = Plugin.manifest.name;
        var list: []const published_model.Contract = &.{};

        std.debug.assert(plugin.len > 0);

        if (!@hasField(@TypeOf(Plugin.options), "contracts")) {
            return list;
        }

        for (Plugin.options.contracts) |Contract| {
            if (!is_contract(Contract) or Contract.owner.len > 0) {
                @compileError("plugin " ++ plugin ++ ": `.contracts` lists its own " ++
                    "`publr.contract.define`s");
            }

            if (!published_model.owned_by(Contract.contract_name, plugin)) {
                @compileError("plugin " ++ plugin ++ ": contract `" ++ Contract.contract_name ++
                    "` is named under the plugin: `" ++ plugin ++ ".<name>`");
            }

            for (list) |before| {
                if (std.mem.eql(u8, before.name, Contract.contract_name)) {
                    @compileError("plugin " ++ plugin ++ ": `.contracts` lists " ++
                        Contract.contract_name ++ " twice");
                }
            }

            list = list ++ &[_]published_model.Contract{.{
                .name = Contract.contract_name,
                .parts = Contract.parts,
                .component = Contract.component,
            }};
        }

        if (list.len > published_model.contracts_max) {
            @compileError("plugin " ++ plugin ++ ": `.contracts` lists at most 16");
        }

        const done = list;

        return done;
    }
}

fn part_type(
    comptime operations: anytype,
    comptime optional: anytype,
    comptime part: []const u8,
) ?type {
    comptime {
        std.debug.assert(part.len > 0);

        if (@hasField(@TypeOf(operations), part)) {
            return @field(operations, part);
        }

        if (@hasField(@TypeOf(optional), part)) {
            return @field(optional, part);
        }

        return null;
    }
}

pub fn is_contract(comptime Type: type) bool {
    comptime std.debug.assert(@sizeOf(Component) > 0);

    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_contract_definition");
}

/// A compiled plugin's providers, each checked against its contract: every required part
/// given, nothing that is no part, each operation the plugin's own and fitting the part's
/// `In` and `Out`. A mismatch fails the build.
pub fn registered_of(comptime Plugin: type) []const Registered {
    comptime {
        const plugin = Plugin.manifest.name;
        var list: []const Registered = &.{};

        std.debug.assert(plugin.len > 0);

        if (!@hasField(@TypeOf(Plugin.options), "register_providers")) {
            return list;
        }

        for (Plugin.options.register_providers) |given| {
            list = list ++ &[_]Registered{checked(Plugin, given)};
        }

        if (list.len > providers_max) {
            @compileError("plugin " ++ plugin ++ ": more than 64 providers");
        }

        return list;
    }
}

fn checked(comptime Plugin: type, comptime given: anytype) Registered {
    comptime {
        const Given = @TypeOf(given);
        const plugin = Plugin.manifest.name;
        const complete = @hasField(Given, "contract") and @hasField(Given, "name") and
            @hasField(Given, "operations");

        std.debug.assert(plugin.len > 0);

        if (!complete) {
            @compileError("plugin " ++ plugin ++ ": a provider is " ++
                "`.{ .contract, .name, .operations = .{ ... } }`");
        }

        const Contract = given.contract;

        if (!is_contract(Contract)) {
            @compileError("plugin " ++ plugin ++ ": `.contract` is a `publr.contract.define`");
        }

        const label = "plugin " ++ plugin ++ ": provider " ++ given.name ++ " of " ++
            Contract.contract_name;

        if (!@import("../model/identity.zig").valid_provider(given.name)) {
            @compileError(label ++ ": `.name` is [a-z][a-z0-9_]*, at most 32 characters");
        }

        const foreign = Contract.owner.len > 0 and !std.mem.eql(u8, Contract.owner, plugin);

        if (foreign and !listed_dependency(Plugin, Contract.owner)) {
            @compileError(label ++ ": " ++ Contract.owner ++ " owns the contract; name it in " ++
                "`depends_on` or `compatible_with`");
        }

        for (Contract.parts) |part| {
            if (part.required and !@hasField(@TypeOf(given.operations), part.name)) {
                @compileError(label ++ ": the part `" ++ part.name ++ "` is required");
            }
        }

        var parts: []const Part = &.{};

        for (std.meta.fieldNames(@TypeOf(given.operations))) |part| {
            const Shape = published_part(Contract.parts, part) orelse
                @compileError(label ++ ": the contract has no part `" ++ part ++ "`");
            const Operation = own_operation(Plugin, @field(given.operations, part)) orelse
                @compileError(label ++ ": `" ++ part ++ "` is one of the plugin's own " ++
                    "`.operations`");

            fits(label ++ ", part " ++ part, Shape, Operation);
            parts = parts ++ &[_]Part{.{
                .part = part,
                .operation = Operation.name,
            }};
        }

        const component: []const u8 = if (@hasField(Given, "component")) given.component else "";

        if (Contract.component == .none and component.len > 0) {
            @compileError(label ++ ": the contract takes no `.component`");
        }

        if (Contract.component == .required and component.len == 0) {
            @compileError(label ++ ": the contract needs a `.component`");
        }

        return .{
            .contract = Contract.contract_name,
            .name = given.name,
            .plugin = plugin,
            .parts = parts,
            .component = component,
        };
    }
}

fn own_operation(comptime Plugin: type, comptime Given: type) ?type {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        for (plugin_define.get(Plugin, "operations")) |Declared| {
            const defined = @hasDecl(Declared, "definition") and Declared.definition == Given;

            if (Declared == Given or defined) {
                return Declared;
            }
        }

        return null;
    }
}

/// Whether the plugin names `owner` in `depends_on` or `compatible_with`.
fn listed_dependency(comptime Plugin: type, comptime owner: []const u8) bool {
    comptime {
        const depends_on = @import("plugin/depends_on.zig");

        std.debug.assert(owner.len > 0);

        return depends_on.names(plugin_define.get(Plugin, "depends_on"), owner) or
            depends_on.names(plugin_define.get(Plugin, "compatible_with"), owner);
    }
}

/// The provider accepts everything the contract sends and gives everything it reads.
fn fits(comptime label: []const u8, comptime part: PublishedPart, comptime Operation: type) void {
    comptime {
        @setEvalBranchQuota(200_000);

        const sent = part.input;
        const accepted = shapes.describe(Operation.In);
        const read = part.output;
        const given = shapes.describe(Operation.Out);

        if (shapes.check_input(sent, accepted)) |problem| {
            @compileError(label ++ ": takes " ++ misfit(problem, sent, accepted));
        }

        if (shapes.check_output(read, given)) |problem| {
            @compileError(label ++ ": answers " ++ misfit(problem, read, given));
        }
    }
}

fn misfit(
    comptime problem: shapes.Problem,
    comptime contract: []const shapes.Node,
    comptime provider: []const shapes.Node,
) []const u8 {
    comptime {
        var buffer: [256]u8 = undefined;
        const nodes = if (problem.on_user_side) contract else provider;
        const path = shapes.path_of(nodes, problem.node, &buffer);
        const shown = if (path.len == 0) "its whole value" else path;

        return shown ++ " in a way that does not fit the contract: it " ++
            shapes.reason_text(problem.reason);
    }
}

/// What the administrator chose for a contract: the providers in order, and those off.
pub const Choice = struct {
    order: []const []const u8 = &.{},
    off: []const []const u8 = &.{},
};

pub fn setting_key(arena: std.mem.Allocator, contract: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(contract.len > 0);

    return std.fmt.allocPrint(arena, "providers.{s}", .{contract});
}

pub fn choice_of(ctx: *sdk.Ctx, contract: []const u8) sdk.Error!Choice {
    std.debug.assert(contract.len > 0);

    const key = try setting_key(ctx.arena, contract);
    const text = try store.settings.get(ctx.db, ctx.arena, key) orelse return .{};

    return std.json.parseFromSliceLeaky(Choice, ctx.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{};
}

/// Every provider of `contract`, compiled in or installed, in the administrator's order
/// (the rest after, as registered), each with whether it is on.
pub const Listed = struct {
    provider: Registered,
    on: bool,
};

pub fn listed(ctx: *sdk.Ctx, contract: []const u8) sdk.Error![]const Listed {
    std.debug.assert(contract.len > 0);

    const registry = @import("../server/registry.zig");
    const choice = try choice_of(ctx, contract);
    var all: std.ArrayList(Registered) = .empty;

    for (registry.providers) |provider| {
        if (std.mem.eql(u8, provider.contract, contract)) {
            try all.append(ctx.arena, provider);
        }
    }

    if (ctx.sandboxed_plugins) |sandboxed| {
        for (sandboxed.manifests()) |manifest| {
            for (manifest.providers) |provider| {
                // A provider of another plugin's contract that does not fit it as it is now
                // (or whose owner is not there) is off until it does.
                const off = sandboxed.remote_off(manifest.name, provider.contract);

                if (!off and std.mem.eql(u8, provider.contract, contract)) {
                    var owned = provider;

                    owned.plugin = manifest.name;
                    try all.append(ctx.arena, owned);
                }
            }
        }
    }

    var ordered: std.ArrayList(Listed) = .empty;

    for (choice.order) |name| {
        for (all.items) |provider| {
            if (std.mem.eql(u8, provider.name, name) and !already(ordered.items, name)) {
                try ordered.append(ctx.arena, .{
                    .provider = provider,
                    .on = !in_list(choice.off, name),
                });
            }
        }
    }

    for (all.items) |provider| {
        if (!already(ordered.items, provider.name)) {
            try ordered.append(ctx.arena, .{
                .provider = provider,
                .on = !in_list(choice.off, provider.name),
            });
        }
    }

    return ordered.items;
}

/// The providers of `contract` that are on and have every part in `can`, in order.
pub fn enabled(
    ctx: *sdk.Ctx,
    contract: []const u8,
    can: []const []const u8,
) sdk.Error![]const Registered {
    std.debug.assert(contract.len > 0);

    var found: std.ArrayList(Registered) = .empty;

    for (try listed(ctx, contract)) |one| {
        if (one.on and one.provider.has_all(can)) {
            try found.append(ctx.arena, one.provider);
        }
    }

    return found.items;
}

fn already(items: []const Listed, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (items) |item| {
        if (std.mem.eql(u8, item.provider.name, name)) {
            return true;
        }
    }

    return false;
}

fn in_list(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

/// What the parts a caller asks for (`.{ .can = &.{.refund} }`) say, as names.
fn can_names(comptime Contract: type, comptime options: anytype) []const []const u8 {
    comptime {
        std.debug.assert(is_contract(Contract));

        var names: []const []const u8 = &.{};

        if (@hasField(@TypeOf(options), "can")) {
            for (options.can) |part| {
                const name = @tagName(part);

                _ = Contract.Shape(name);
                names = names ++ &[_][]const u8{name};
            }
        }

        return names;
    }
}

/// `publr.providers(ctx, Contract, .{ .can = &.{.refund} })`: the enabled providers of the
/// contract with those optional parts, in the administrator's order.
pub fn providers(
    ctx: anytype,
    comptime Contract: type,
    comptime options: anytype,
) sdk.Error![]const Provider(Contract) {
    comptime std.debug.assert(is_contract(Contract));

    const can = comptime can_names(Contract, options);
    const found = if (@TypeOf(ctx) == *sdk.Ctx)
        try enabled(ctx, Contract.contract_name, can)
    else
        (try ctx.call(List, .{
            .contract = Contract.contract_name,
            .can = can,
            .on_only = true,
        })).providers;
    const memory = if (@TypeOf(ctx) == *sdk.Ctx) ctx.arena else ctx.arena();
    const handles = memory.alloc(Provider(Contract), found.len) catch return error.OutOfMemory;

    for (found, handles) |provider, *handle| {
        handle.* = .{
            .registered = provider,
        };
    }

    return handles;
}

/// One provider of `Contract`: `chosen.call(ctx, .send, in)` for a required part,
/// `chosen.optional(.receipt)` for an optional one, null when it lacks it.
pub fn Provider(comptime Contract: type) type {
    return struct {
        registered: Registered,

        const Self = @This();

        pub fn name(self: Self) []const u8 {
            std.debug.assert(self.registered.name.len > 0);

            return self.registered.name;
        }

        pub fn call(
            self: Self,
            ctx: anytype,
            comptime part: @TypeOf(.enum_literal),
            in: Contract.Shape(@tagName(part)).In,
        ) sdk.Error!Contract.Shape(@tagName(part)).Out {
            comptime {
                if (!Contract.required(@tagName(part))) {
                    @compileError("`" ++ @tagName(part) ++ "` is optional: call it through " ++
                        "`chosen.optional(." ++ @tagName(part) ++ ")`");
                }
            }

            const operation = self.registered.operation_of(@tagName(part)).?;

            return call_part(ctx, Contract.Shape(@tagName(part)), operation, in);
        }

        pub fn optional(
            self: Self,
            comptime part: @TypeOf(.enum_literal),
        ) ?Optional(Contract.Shape(@tagName(part))) {
            comptime std.debug.assert(!Contract.required(@tagName(part)));

            const operation = self.registered.operation_of(@tagName(part)) orelse return null;

            return .{
                .operation = operation,
            };
        }
    };
}

pub fn Optional(comptime Shape: type) type {
    return struct {
        operation: []const u8,

        pub fn call(self: @This(), ctx: anytype, in: Shape.In) sdk.Error!Shape.Out {
            std.debug.assert(self.operation.len > 0);

            return call_part(ctx, Shape, self.operation, in);
        }
    };
}

/// A part called through its provider's operation, by name, through the same checks as any
/// call: compiled in or installed alike.
fn call_part(
    ctx: anytype,
    comptime Shape: type,
    operation: []const u8,
    in: Shape.In,
) sdk.Error!Shape.Out {
    std.debug.assert(operation.len > 0);

    const core = @TypeOf(ctx) == *sdk.Ctx;
    const memory = if (core) ctx.arena else ctx.arena();
    const input = std.json.Stringify.valueAlloc(memory, in, .{}) catch return error.OutOfMemory;
    const output = if (core)
        try @import("../server/registry.zig").SDK.call_json(ctx, operation, input)
    else
        try ctx.call_json(operation, input);

    return std.json.parseFromSliceLeaky(Shape.Out, memory, output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.Invalid;
}

pub const List = @import("../operations/provider.zig").List;

test "a contract names its parts, required and optional" {
    const Send = struct {
        pub const In = struct {
            to: []const u8,
        };
        pub const Out = struct {
            id: []const u8,
        };
    };
    const Receipt = struct {
        pub const In = struct {
            id: []const u8,
        };
        pub const Out = struct {
            delivered: bool,
        };
    };
    const Test = define(.{
        .name = "test.mail",
        .operations = .{
            .send = Send,
        },
        .optional = .{
            .receipt = Receipt,
        },
    });

    try std.testing.expectEqualStrings("test.mail", Test.contract_name);
    try std.testing.expect(Test.required("send"));
    try std.testing.expect(!Test.required("receipt"));
    try std.testing.expect(Test.Shape("receipt") == Receipt);
    try std.testing.expectEqual(Component.none, Test.component);

    const provider: Registered = .{
        .contract = "test.mail",
        .name = "postbox",
        .parts = &.{.{
            .part = "send",
            .operation = "postbox.send",
        }},
    };

    try std.testing.expectEqualStrings("postbox.send", provider.operation_of("send").?);
    try std.testing.expect(provider.operation_of("receipt") == null);
    try std.testing.expect(provider.has_all(&.{"send"}));
    try std.testing.expect(!provider.has_all(&.{"receipt"}));
}
