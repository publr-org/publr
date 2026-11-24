//! `<ProviderSlot contract="shipping.method" chosen={cart.shipping} … />`: the place a page or
//! component leaves for the chosen provider of a contract to draw its own `.component` (a
//! parcel locker map, a bank picker). Before the app compiles, each slot becomes one branch
//! per provider of the contract that brings a component, from a plugin the app reaches:
//! `{(chosen) === "inpost" ? (<…LockerMap … />) : null}`, its component imported as any
//! plugin's (`plugin:inpost/LockerMap`). Every other attribute is handed to the component as
//! it is written. A provider with no component, or none chosen, draws nothing.
//!
//! A contract's `.with` types what the slot hands over: every attribute is one of its fields,
//! each required one given, a quoted value only for a text field, or the app does not load.
//! A component reading a prop `.with` does not name (`props.town`) is not drawn, and the log
//! says why.
const std = @import("std");
const Registered = @import("../../model/provider.zig").Registered;
const registry = @import("../../server/registry.zig");
const sdk = @import("../../sdk.zig");
const Component = registry.PluginComponent;
const Interactive = sdk.sandboxed_plugins.Interactive;
const Reason = @import("../../lib/report.zig").Reason;

const tag_open = "<ProviderSlot";
pub const slots_max: u32 = 16;

pub const Error = error{ OutOfMemory, InvalidSlot, SlotMismatch };

/// What slots draw from: every provider, compiled in or installed, and every plugin's
/// components. Compiled in only by default: what the build's own check of its apps sees.
pub const Sources = struct {
    providers: []const Registered = registry.providers,
    components: []const Component = registry.plugin_components,
    /// Every plugin's interactive components, for the apps that reach it to place.
    interactive: []const Interactive = registry.plugin_interactive,
};

/// The compiled-in providers and components, with the installed plugins' when there are
/// any (a provider of a contract it does not fit as it is now left out, as it is off).
pub fn sources(
    arena: std.mem.Allocator,
    sandboxed: ?*const sdk.sandboxed_plugins.SandboxedPlugins,
) Error!Sources {
    std.debug.assert(registry.providers.len <= 64 * 64);

    const installed = sandboxed orelse return .{};
    var providers: std.ArrayList(Registered) = .empty;
    var components: std.ArrayList(Component) = .empty;
    var interactive: std.ArrayList(Interactive) = .empty;

    try providers.appendSlice(arena, registry.providers);
    try components.appendSlice(arena, registry.plugin_components);
    try interactive.appendSlice(arena, registry.plugin_interactive);

    for (installed.manifests()) |manifest| {
        for (manifest.providers) |provider| {
            if (!installed.remote_off(manifest.name, provider.contract)) {
                var owned = provider;

                owned.plugin = manifest.name;
                try providers.append(arena, owned);
            }
        }
    }

    try components.appendSlice(arena, installed.components());
    try interactive.appendSlice(arena, installed.interactive());

    return .{
        .providers = providers.items,
        .components = components.items,
        .interactive = interactive.items,
    };
}

/// `text` with every `<ProviderSlot … />` drawn as its providers' components; `text` itself
/// when it has none.
pub fn expand(
    arena: std.mem.Allocator,
    text: []const u8,
    providers: []const Registered,
    components: []const Component,
    plugins: ?[]const []const u8,
    reason: ?*Reason,
) Error![]const u8 {
    std.debug.assert(providers.len <= 64 * 64);

    if (std.mem.indexOf(u8, text, tag_open) == null) {
        return text;
    }

    var body: std.ArrayList(u8) = .empty;
    var imports: std.ArrayList(u8) = .empty;
    var rest = text;
    var count: u32 = 0;

    while (std.mem.indexOf(u8, rest, tag_open)) |at| {
        count += 1;

        if (count > slots_max) {
            return error.InvalidSlot;
        }

        const slot = try parse(arena, rest[at..]);

        try body.appendSlice(arena, rest[0..at]);
        try draw(arena, slot, .{
            .providers = providers,
            .components = components,
        }, plugins, count, &body, &imports, reason);
        rest = rest[at + slot.len ..];
    }

    try body.appendSlice(arena, rest);

    return with_imports(arena, body.items, imports.items);
}

const Slot = struct {
    /// The whole tag's length.
    len: u32,
    contract: []const u8,
    chosen: []const u8,
    /// Every other attribute, as written.
    others: []const u8,
};

/// One self-closing tag: `contract="…"` a literal, `chosen={…}` an expression.
fn parse(arena: std.mem.Allocator, text: []const u8) Error!Slot {
    std.debug.assert(std.mem.startsWith(u8, text, tag_open));

    var at: u32 = tag_open.len;
    var depth: u32 = 0;
    var quote: u8 = 0;

    while (at < text.len) : (at += 1) {
        const char = text[at];

        if (quote != 0) {
            if (char == quote) {
                quote = 0;
            }
        } else if (char == '"' or char == '\'' or char == '`') {
            quote = char;
        } else if (char == '{') {
            depth += 1;
        } else if (char == '}') {
            depth -|= 1;
        } else if (depth == 0 and char == '/' and at + 1 < text.len and text[at + 1] == '>') {
            break;
        }
    } else {
        return error.InvalidSlot;
    }

    const attributes = text[tag_open.len..at];
    const contract = literal_of(attributes, "contract=\"") orelse return error.InvalidSlot;
    const chosen = expression_of(attributes, "chosen={") orelse return error.InvalidSlot;

    return .{
        .len = at + 2,
        .contract = contract.value,
        .chosen = chosen.value,
        .others = try without(arena, attributes, contract.whole, chosen.whole),
    };
}

const Found = struct {
    value: []const u8,
    /// The attribute as written, name included.
    whole: []const u8,
};

fn literal_of(attributes: []const u8, opening: []const u8) ?Found {
    std.debug.assert(opening.len > 0);

    const start = std.mem.indexOf(u8, attributes, opening) orelse return null;
    const value_start = start + opening.len;
    const end = std.mem.indexOfScalarPos(u8, attributes, value_start, '"') orelse return null;

    return .{
        .value = attributes[value_start..end],
        .whole = attributes[start .. end + 1],
    };
}

fn expression_of(attributes: []const u8, opening: []const u8) ?Found {
    std.debug.assert(opening.len > 0);

    const start = std.mem.indexOf(u8, attributes, opening) orelse return null;
    const value_start = start + opening.len;
    var depth: u32 = 1;
    var at = value_start;

    while (at < attributes.len) : (at += 1) {
        if (attributes[at] == '{') {
            depth += 1;
        }

        if (attributes[at] == '}') {
            depth -= 1;

            if (depth == 0) {
                return .{
                    .value = attributes[value_start..at],
                    .whole = attributes[start .. at + 1],
                };
            }
        }
    }

    return null;
}

/// `attributes` with the two named ones taken out (each a slice of it).
fn without(
    arena: std.mem.Allocator,
    attributes: []const u8,
    first: []const u8,
    second: []const u8,
) Error![]const u8 {
    std.debug.assert(first.len > 0 and second.len > 0);

    var kept: [2048]u8 = undefined;
    var len: u32 = 0;
    var at: u32 = 0;

    while (at < attributes.len) {
        const here = attributes.ptr + at;

        if (here == first.ptr or here == second.ptr) {
            at += @intCast(if (here == first.ptr) first.len else second.len);
            continue;
        }

        if (len == kept.len) {
            return error.InvalidSlot;
        }

        kept[len] = attributes[at];
        len += 1;
        at += 1;
    }

    const copy = arena.dupe(u8, kept[0..len]) catch return error.OutOfMemory;

    return std.mem.trim(u8, copy, " \t\r\n");
}

fn draw(
    arena: std.mem.Allocator,
    slot: Slot,
    from: Sources,
    plugins: ?[]const []const u8,
    number: u32,
    body: *std.ArrayList(u8),
    imports: *std.ArrayList(u8),
    reason: ?*Reason,
) Error!void {
    std.debug.assert(slot.contract.len > 0);
    std.debug.assert(number > 0);

    for (from.providers, 0..) |provider, index| {
        const fits = std.mem.eql(u8, provider.contract, slot.contract) and
            provider.component.len > 0 and reaches(plugins, provider.plugin);
        const text = if (fits) component_text(from.components, provider) else null;

        if (text == null) {
            continue;
        }

        if (provider.with.len > 0) {
            try typed.check_slot(slot.contract, slot.others, provider.with, reason);

            if (typed.unknown_prop(text.?, provider.with)) |prop| {
                std.log.warn("{s}: {s}/{s} reads props.{s}, which {s}'s `.with` does not " ++
                    "name: not drawn", .{
                    slot.contract,
                    provider.plugin,
                    provider.component,
                    prop,
                    slot.contract,
                });
                continue;
            }
        }

        const local = try std.fmt.allocPrint(arena, "ProviderSlot{d}x{d}", .{ number, index });

        try imports.print(arena, "import {s} from \"plugin:{s}/{s}\";\n", .{
            local,
            provider.plugin,
            provider.component,
        });
        try body.print(arena, "{{({s}) === \"{s}\" ? (<{s} {s} />) : null}}", .{
            slot.chosen,
            provider.name,
            local,
            slot.others,
        });
    }
}

fn reaches(plugins: ?[]const []const u8, plugin: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    const reached = plugins orelse return true;

    for (reached) |one| {
        if (std.mem.eql(u8, one, plugin)) {
            return true;
        }
    }

    return false;
}

/// The provider's component's text, when its plugin brings it.
fn component_text(components: []const Component, provider: Registered) ?[]const u8 {
    std.debug.assert(provider.component.len > 0);

    for (components) |component| {
        const same = std.mem.eql(u8, component.plugin, provider.plugin) and
            std.mem.eql(u8, component.name, provider.component);

        if (same) {
            return component.text;
        }
    }

    return null;
}

const typed = @import("provider_slots/typed.zig");

/// The imports put at the head of the template's frontmatter, one made when it has none.
fn with_imports(arena: std.mem.Allocator, body: []const u8, imports: []const u8) Error![]const u8 {
    std.debug.assert(body.len > 0);

    if (imports.len == 0) {
        return body;
    }

    if (std.mem.startsWith(u8, body, "---\n")) {
        return std.mem.concat(arena, u8, &.{ "---\n", imports, body["---\n".len..] });
    }

    return std.mem.concat(arena, u8, &.{ "---\n", imports, "---\n", body });
}

test "a provider slot draws the chosen provider's component, and nothing for the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const providers = [_]Registered{ .{
        .contract = "shipping.method",
        .name = "lockers",
        .plugin = "lockers",
        .parts = &.{},
        .component = "LockerMap",
    }, .{
        .contract = "shipping.method",
        .name = "courier",
        .plugin = "courier",
        .parts = &.{},
    } };
    const components = [_]Component{.{
        .plugin = "lockers",
        .name = "LockerMap",
        .text = "<div />",
    }};
    const page = "---\nconst cart = {};\n---\n<main><ProviderSlot contract=\"shipping.method\" " ++
        "chosen={cart.shipping} city=\"Kraków\" /></main>";
    const drawn = try expand(arena, page, &providers, &components, null, null);

    try std.testing.expectEqualStrings("---\nimport ProviderSlot1x0 from " ++
        "\"plugin:lockers/LockerMap\";\nconst cart = {};\n---\n<main>{(cart.shipping) === " ++
        "\"lockers\" ? (<ProviderSlot1x0 city=\"Kraków\" />) : null}</main>", drawn);

    // An app that reaches no lockers plugin: the slot draws nothing.
    const none = try expand(arena, page, &providers, &components, &.{"courier"}, null);

    try std.testing.expect(std.mem.indexOf(u8, none, "ProviderSlot") == null);
    const plain = try expand(arena, "<p />", &providers, &.{}, null, null);

    try std.testing.expectEqualStrings("<p />", plain);
    try std.testing.expectError(
        error.InvalidSlot,
        expand(arena, "<ProviderSlot chosen={x} />", &providers, &components, null, null),
    );
}
