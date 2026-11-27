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
const public = @import("../publr/operations/event.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const Field = public.Field;
pub const Described = public.Described;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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

const example_described = public.example_described;

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
