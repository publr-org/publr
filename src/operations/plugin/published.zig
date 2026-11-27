//! `plugin.interfaces`: each plugin's published interface on this site, the built-in ones
//! from their declarations, the installed ones from their manifests. What `plugin build`
//! builds a plugin against: each one a module under its name (`@import("payments")`).
const std = @import("std");
const public = @import("../../publr/operations/plugin/published.zig");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const state = @import("state.zig");
const published = @import("../../sdk/published.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Interfaces = struct {
    pub const shape = public.Interfaces;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const field_docs = shape.field_docs;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const built_in = registry.published_interfaces;
        var out: std.ArrayList(published.Interface) = .empty;
        var looked: u32 = 0;

        for (built_in, 0..) |interface, index| {
            if (index >= in.offset and looked < in.limit) {
                looked += 1;

                if (publishes(interface)) {
                    try out.append(ctx.arena, interface);
                }
            }
        }

        const room = in.limit - looked;
        const total = @as(u32, built_in.len) + try store.sandboxed_plugins.count(ctx.db);

        if (room > 0) {
            const from = in.offset -| @as(u32, built_in.len);
            const rows = try store.sandboxed_plugins.page(ctx.db, ctx.arena, from, room);

            for (rows) |row| {
                const manifest = (try state.decode(ctx.arena, row)).manifest;
                const interface: published.Interface = .{
                    .plugin = manifest.name,
                    .version = manifest.version,
                    .contracts = manifest.contracts,
                    .dimensions = manifest.dimensions,
                };

                looked += 1;

                if (publishes(interface)) {
                    try out.append(ctx.arena, interface);
                }
            }
        }

        return .{
            .interfaces = out.items,
            .more = in.offset + looked < total,
        };
    }
};

fn publishes(interface: published.Interface) bool {
    std.debug.assert(interface.plugin.len > 0);

    return interface.contracts.len > 0 or interface.dimensions.len > 0;
}
