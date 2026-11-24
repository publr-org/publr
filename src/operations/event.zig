//! The events plugins declare (`publr.event.define`, listed in `.events`), compiled in and
//! installed, each with its payload's fields: what a plugin hooking one (`publr.on`,
//! `publr.after`, `publr.remote.event`) writes its own words against. `event.list`,
//! `event.get`. Every operation also emits an event under its own name carrying its answer;
//! `operation get` describes those.
const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const shapes = @import("../model/contract.zig");
const plugin_contracts = @import("../model/plugin_contracts.zig");
const operation_operations = @import("operation.zig");
const key_page = @import("../model/key_page.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "event",
    .label = "Events",
    .area = .system,
    .summary = "The events plugins declare, with their payloads",
    .details =
    \\What each plugin's events carry, compiled in and installed: the payload's fields, each
    \\with its kind, for a plugin hooking one to write its own words against. Every
    \\operation also emits an event under its own name, carrying its answer (`operation
    \\get`). Administrators only.
    ,
};

/// One field of a payload: its path (`lines[].sku`), its kind, whether it may be null or
/// left out, an enumeration's values.
pub const Field = struct {
    path: []const u8,
    kind: []const u8,
    optional: bool = false,
    required: bool = true,
    values: []const []const u8 = &.{},
};

pub const Described = struct {
    name: []const u8,
    /// The plugin that emits it.
    plugin: []const u8,
    installed: bool = false,
    payload: []const Field,
};

pub const List = struct {
    pub const name = "event.list";
    pub const description = "Every event plugins declare, with its payload";
    pub const details =
        \\Administrators only. Each event a plugin declares, compiled in and installed: its
        \\name (`orders.paid`), the plugin emitting it, and its payload's fields with their
        \\kinds. `plugin` keeps one plugin's. Operations' own events (one per operation,
        \\carrying its answer) are not listed: `operation get` describes them. A page at a
        \\time, in the order of their names: `next` continues it.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        plugin: []const u8 = "",
        after: []const u8 = "",
    };
    pub const Out = struct {
        events: []const Described,
        next: []const u8 = "",
    };
    pub const example: In = .{
        .plugin = "hello",
    };
    pub const example_out: Out = .{
        .events = &.{example_described},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .plugin = "Only this plugin's events; every plugin's when left out",
        .after = "The page after this name: the `next` the last page answered",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .events = "Each event: name, plugin, installed, payload (path, kind, optional, " ++
            "required, values)",
        .next = "The next page's `after`; empty after the last",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.plugin.len <= 4096);

        var listed: std.ArrayList(Described) = .empty;

        for (try declared(ctx)) |event| {
            const own = in.plugin.len == 0 or std.mem.eql(u8, event.plugin, in.plugin);

            if (own) {
                listed.append(ctx.arena, event) catch return error.OutOfMemory;
            }
        }

        std.mem.sort(Described, listed.items, {}, by_name);

        const names = ctx.arena.alloc([]const u8, listed.items.len) catch {
            return error.OutOfMemory;
        };

        for (listed.items, names) |event, *event_name| {
            event_name.* = event.name;
        }

        const page = key_page.window(names, in.after, sdk.operation.page_limit_max);

        return .{
            .events = listed.items[page.start..page.end],
            .next = page.next,
        };
    }

    fn by_name(_: void, left: Described, right: Described) bool {
        return key_page.before(left.name, right.name);
    }
};

pub const Get = struct {
    pub const name = "event.get";
    pub const description = "One event: its payload, and the hooks that hear it";
    pub const details =
        \\Administrators only. The event as `event list` describes it, and each hook on it
        \\(plugin, stage `after` or `on`, its reason, its last failed run). Fails as not
        \\found for a name no plugin declares.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        event: Described,
        hooks: []const operation_operations.Hook = &.{},
    };
    pub const example: In = .{
        .name = "hello.recorded",
    };
    pub const example_out: Out = .{
        .event = example_described,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The event's name, as `event list` gives it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .event = "As `event list` describes it",
        .hooks = "Each hook on it: plugin, stage, reason and last_failure",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.name.len <= 4096);

        for (try declared(ctx)) |event| {
            if (std.mem.eql(u8, event.name, in.name)) {
                return .{
                    .event = event,
                    .hooks = try operation_operations.hooks_on(ctx, in.name),
                };
            }
        }

        return error.NotFound;
    }
};

const example_described: Described = .{
    .name = "hello.recorded",
    .plugin = "hello",
    .payload = &.{.{
        .path = "note",
        .kind = "string",
    }},
};

/// Every declared event, compiled-in plugins' first, then installed ones'.
fn declared(ctx: *Ctx) Error![]const Described {
    std.debug.assert(ctx.now_ms >= 0);

    const natives = registry.native_providers(ctx.arena) catch return error.OutOfMemory;
    var listed: std.ArrayList(Described) = .empty;

    for (natives) |provider| {
        try add_all(ctx, &listed, provider.plugin, provider.events, false);
    }

    if (ctx.sandboxed_plugins) |sandboxed| {
        for (sandboxed.manifests()) |manifest| {
            try add_all(ctx, &listed, manifest.name, manifest.events, true);
        }
    }

    return listed.items;
}

fn add_all(
    ctx: *Ctx,
    listed: *std.ArrayList(Described),
    plugin: []const u8,
    events: []const plugin_contracts.ProvidedEvent,
    installed: bool,
) Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(events.len <= 1 << 12);

    for (events) |event| {
        listed.append(ctx.arena, .{
            .name = event.name,
            .plugin = plugin,
            .installed = installed,
            .payload = try fields_of(ctx.arena, event.payload),
        }) catch return error.OutOfMemory;
    }
}

/// A payload's shape as fields, each by its path from the payload's root.
pub fn fields_of(
    arena: std.mem.Allocator,
    nodes: []const shapes.Node,
) error{OutOfMemory}![]const Field {
    std.debug.assert(nodes.len <= shapes.nodes_max);

    if (nodes.len <= 1) {
        return &.{};
    }

    const fields = try arena.alloc(Field, nodes.len - 1);

    for (nodes[1..], fields, 1..) |node, *field, index| {
        var buffer: [256]u8 = undefined;
        const path = shapes.path_of(nodes, @intCast(index), &buffer);

        field.* = .{
            .path = try arena.dupe(u8, path),
            .kind = @tagName(node.kind),
            .optional = node.optional,
            .required = node.required,
            .values = node.values,
        };
    }

    std.debug.assert(fields.len == nodes.len - 1);

    return fields;
}

pub const operations = [_]type{ List, Get };

test "a payload's fields by path, kinds named" {
    const Payload = struct {
        order: []const u8,
        note: ?[]const u8 = null,
        lines: []const struct {
            sku: []const u8,
            size: enum { small, large },
        } = &.{},
    };
    const nodes = comptime shapes.describe(Payload);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const fields = try fields_of(arena_state.allocator(), nodes);

    try std.testing.expectEqual(@as(usize, 6), fields.len);
    try std.testing.expectEqualStrings("order", fields[0].path);
    try std.testing.expect(fields[1].optional);
    try std.testing.expectEqualStrings("lines[]", fields[3].path);
    try std.testing.expectEqualStrings("lines[].size", fields[5].path);
    try std.testing.expectEqual(@as(usize, 2), fields[5].values.len);
}
