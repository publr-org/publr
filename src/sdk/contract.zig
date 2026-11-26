//! What core keeps of contracts and their providers (`publr/contract.zig` is how plugins
//! define and call them): a compiled plugin's providers checked against their contracts, the
//! contracts it owns as its published interface carries them, and the administrator's
//! choice of providers, in order.
const std = @import("std");
const wire_json = @import("plugin/wire_json.zig");
const plugin_define = @import("../publr/plugin/define.zig");
const guest = @import("plugin/guest.zig");
const sdk = @import("../sdk.zig");
const shapes = @import("../model/contract.zig");
const store = @import("../store.zig");
const public = @import("../publr/contract.zig");

pub const providers_max: u32 = 64;
pub const parts_max = registered_model.parts_max;
pub const name_len_max = public.name_len_max;
pub const Component = public.Component;
pub const define = public.define;
pub const PublishedPart = public.PublishedPart;
pub const is_contract = public.is_contract;
pub const providers = public.providers;
pub const Provider = public.Provider;
pub const Optional = public.Optional;

pub const Part = registered_model.Part;
pub const Registered = registered_model.Registered;

const registered_model = @import("../model/provider.zig");
const published_model = @import("../model/published.zig");

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
            pub const with: []const shapes.Node = data.with;
            pub const parts = data.parts;
            pub const install_part: []const u8 = for (data.parts) |part| {
                if (part.at_install) {
                    break part.name;
                }
            } else "";

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
                .with = Contract.with,
            }};
        }

        if (list.len > published_model.contracts_max) {
            @compileError("plugin " ++ plugin ++ ": `.contracts` lists at most 16");
        }

        const done = list;

        return done;
    }
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
                "`.{ .contract, .name, .label, .operations = .{ ... } }`");
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
        const panel: []const u8 = if (@hasField(Given, "panel"))
            panel_of(Plugin, label, given.panel)
        else
            "";

        if (Contract.component == .none and component.len > 0) {
            @compileError(label ++ ": the contract takes no `.component`");
        }

        if (Contract.component == .required and component.len == 0) {
            @compileError(label ++ ": the contract needs a `.component`");
        }

        return .{
            .contract = Contract.contract_name,
            .name = given.name,
            .label = if (@hasField(Given, "label")) given.label else "",
            .plugin = plugin,
            .parts = parts,
            .component = component,
            .panel = panel,
            .with = Contract.with,
            .at_install = Contract.install_part,
        };
    }
}

/// A provider's `.panel`: one of the plugin's own reads, taking `record` and `base` and
/// answering `html`, as any panel's.
fn panel_of(comptime Plugin: type, comptime label: []const u8, comptime Given: type) []const u8 {
    comptime {
        std.debug.assert(label.len > 0);

        const Operation = own_operation(Plugin, Given) orelse
            @compileError(label ++ ": `.panel` is one of the plugin's own `.operations`");
        const drawn = Operation.kind == .read and @hasField(Operation.In, "record") and
            @hasField(Operation.Out, "html");

        if (!drawn) {
            @compileError(label ++ ": `.panel` is a read taking `record` and `base`, " ++
                "answering `html`");
        }

        return Operation.name;
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

/// The provider takes what it uses of what the contract sends (each field it declares is one
/// the contract sends, of the same kind) and gives everything the contract reads.
fn fits(comptime label: []const u8, comptime part: PublishedPart, comptime Operation: type) void {
    comptime {
        @setEvalBranchQuota(200_000);

        const sent = part.input;
        const accepted = shapes.describe(Operation.In);
        const read = part.output;
        const given = shapes.describe(Operation.Out);

        if (shapes.check_provider_input(sent, accepted)) |problem| {
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

    return wire_json.parse(Choice, ctx.arena, text, .{}) catch .{};
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

pub fn in_list(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

pub const List = @import("../operations/provider.zig").List;
pub const Answers = @import("../operations/provider/answers.zig").Answers;

/// An app's plugins with the plugins providing the contracts they reach: a provider of a
/// contract a listed plugin owns (a payment method of `payments`) works in the app as its
/// owner does, without the app naming it, and so do the providers of the contracts that
/// provider owns in turn (the country plugin of `tax`, a provider of `orders`), at any depth.
pub fn with_providers(
    ctx: *const sdk.Ctx,
    plugins: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(plugins.len <= 1 << 10);
    std.debug.assert(ctx.now_ms >= 0);

    const registry = @import("../server/registry.zig");
    var list: std.ArrayList([]const u8) = .empty;

    try list.appendSlice(ctx.arena, plugins);

    // Each pass adds the providers of what the last one reached; a pass adding none ends it.
    var before: usize = 0;

    while (before != list.items.len) {
        before = list.items.len;

        for (registry.providers) |provider| {
            try add_provider(ctx.arena, &list, provider.contract, provider.plugin);
        }

        if (ctx.sandboxed_plugins) |sandboxed| {
            for (sandboxed.manifests()) |manifest| {
                for (manifest.providers) |provider| {
                    try add_provider(ctx.arena, &list, provider.contract, manifest.name);
                }
            }
        }
    }

    return list.items;
}

fn add_provider(
    arena: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    contract: []const u8,
    plugin: []const u8,
) error{OutOfMemory}!void {
    std.debug.assert(contract.len > 0);

    const dot = std.mem.indexOfScalar(u8, contract, '.') orelse return;

    if (plugin.len == 0 or !in_list(list.items, contract[0..dot]) or in_list(list.items, plugin)) {
        return;
    }

    try list.append(arena, plugin);
}
