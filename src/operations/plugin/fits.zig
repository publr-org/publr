//! Whether each installed plugin fits this Publr, as an update asks it of the release it
//! would move to: run by that release on a copy of the site (`publr upgrade --check`), or by
//! the site's own Publr to see what is on its way out.
const std = @import("std");
const public = @import("../../publr/operations/plugin/fits.zig");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const fit = @import("fit.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const State = public.State;
pub const Used = public.Used;
pub const Plugin = public.Plugin;

pub const Fits = struct {
    pub const shape = public.Fits;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const sdk.Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const rows = try store.sandboxed_plugins.page(ctx.db, ctx.arena, in.offset, in.limit);
        const total = try store.sandboxed_plugins.count(ctx.db);
        const plugins = try ctx.arena.alloc(Plugin, rows.len);

        for (rows, plugins) |row, *plugin| {
            plugin.* = try fit_of(ctx, row.manifest);
        }

        return .{
            .publr = @import("../../publr.zig").version,
            .plugins = plugins,
            .more = in.offset + @as(u32, @intCast(rows.len)) < total,
        };
    }
};

/// What a plugin's manifest says of how it fits.
fn fit_of(ctx: *Ctx, manifest: []const u8) Error!Plugin {
    std.debug.assert(manifest.len > 0);

    const needs = std.json.parseFromSliceLeaky(fit.Needs, ctx.arena, manifest, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Invalid,
    };

    std.debug.assert(needs.name.len > 0);

    var found: Plugin = .{
        .name = needs.name,
        .version = needs.version,
        .state = .fits,
    };

    if (try fit.refusal(ctx.arena, needs)) |refused| {
        found.state = .blocked;
        found.reason = refused.message;
        return found;
    }

    if (needs.minimum_publr.len == 0) {
        found.state = .unchecked;
        return found;
    }

    var used: std.ArrayList(Used) = .empty;

    for (needs.uses) |item| {
        const deprecation = fit.deprecation_of_use(item) orelse continue;

        try used.append(ctx.arena, .{
            .item = item,
            .removed_on = deprecation.removed_on,
            .instead = deprecation.instead,
            .migration = deprecation.migration,
        });
    }

    if (used.items.len > 0) {
        found.state = .deprecations;
        found.deprecated = used.items;
    }

    return found;
}
