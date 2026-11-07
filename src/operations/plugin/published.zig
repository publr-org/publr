//! `plugin.interfaces`: each plugin's published interface on this site, the built-in ones
//! from their declarations, the installed ones from their manifests. What `plugin build`
//! builds a plugin against: each one a module under its name (`@import("payments")`).
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const state = @import("state.zig");
const published = @import("../../sdk/published.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Interfaces = struct {
    pub const name = "plugin.interfaces";
    pub const description = "List each plugin's published interface: its contracts and dimensions";
    pub const details =
        \\What other plugins build against without a plugin's code: the contracts it owns,
        \\each part's input and output as shape nodes, and its dimensions with the field
        \\option and read option each offers. The built-in ones first, then the installed ones
        \\by name; a plugin publishing nothing is left out. `plugin build` reads them to build
        \\a plugin naming them in `depends_on` or `compatible_with`.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        interfaces: []const published.Interface,
        /// Whether more follow past this page.
        more: bool = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .limit = "How many plugins to look at; 50 when omitted, up to 200",
        .offset = "How many plugins to pass over first: the built-in ones, then the installed",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .interfaces = &.{.{
            .plugin = "payments",
            .version = "1.0.0",
            .contracts = &.{.{
                .name = "payments.method",
                .parts = &.{.{
                    .name = "start",
                    .required = true,
                    .input = &.{.{
                        .parent = -1,
                        .kind = .object,
                    }},
                    .output = &.{.{
                        .parent = -1,
                        .kind = .object,
                    }},
                }},
            }},
        }},
    };

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
