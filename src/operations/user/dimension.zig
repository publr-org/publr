//! What a person reads and edits content in, in the admin: one value per dimension of the
//! site's (with the languages plugin, the content language; with an A/B test, its
//! variation). Their own choice, apart from the language the admin speaks to them; each
//! dimension's main value until they choose. The site's visitors choose on the site.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const site_dimensions = @import("../dimensions.zig");
const model_dimension = @import("../../model/dimension.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

const person_prefix = "content_dimension:";

/// One dimension as the person sees it: what it is, its values, their choice.
pub const Chosen = struct {
    /// The dimension's name: `language`.
    dimension: []const u8,
    /// The admin's picker for it, top right; empty for none.
    picker: []const u8,
    /// The code chosen; empty for the main value.
    chosen: []const u8,
    values: []const site_dimensions.Value,
};

pub const Dimensions = struct {
    pub const name = "user.dimensions";
    pub const description = "What you read and edit content in, in the admin";
    pub const details =
        \\Any signed-in account, about itself: for each of the site's dimensions, highest
        \\priority first, its values (the main one first) and the code of its choice, empty
        \\for the main value (also when the choice is no longer one of the dimension's).
        \\Empty while no plugin declares a dimension.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct {};
    pub const Out = struct {
        dimensions: []const Chosen,
    };
    pub const example: In = .{};
    // As a site with no dimension answers: none to choose.
    pub const example_out: Out = .{
        .dimensions = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .dimensions = "Each dimension: `dimension`, `picker`, `chosen`, `values` (`code`, " ++
            "`label`, `address`, `main`)",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const every = site_dimensions.all(ctx);
        const out = ctx.arena.alloc(Chosen, every.len) catch return error.OutOfMemory;

        std.debug.assert(every.len <= model_dimension.dimensions_max);

        for (every, out) |dimension, *one| {
            const values = try site_dimensions.values_of(ctx, dimension);
            const value = if (ctx.caller.user_id()) |user|
                try store.settings.get(ctx.db, ctx.arena, try key_of(ctx, dimension.name, user))
            else
                null;

            one.* = .{
                .dimension = dimension.name,
                .picker = dimension.picker,
                .chosen = if (other_of(values, value orelse "")) value.? else "",
                .values = values,
            };
        }

        return .{
            .dimensions = out,
        };
    }
};

pub const SetDimension = struct {
    pub const name = "user.set_dimension";
    pub const description = "Choose what you read and edit content in, in the admin";
    pub const details =
        \\Any signed-in account, for itself: in `dimension` (empty: the one with pages of its
        \\own, else the highest priority one), a code `user dimensions` lists, or empty for
        \\the main value. Lists, the editor and the visual editor open in it.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {
        dimension: []const u8 = "",
        code: []const u8 = "",
    };
    pub const Out = struct {
        dimension: []const u8,
        code: []const u8,
    };
    // As a site with no dimension takes it: back to the main value.
    pub const example: In = .{};
    pub const example_out: Out = .{
        .dimension = "",
        .code = "",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .dimension = "The dimension (`language`); empty for the site's first",
        .code = "One of its codes (`pl`), or empty for its main value",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .dimension = "The dimension chosen in; empty on a site with none",
        .code = "Your choice now; empty for the main value",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user = ctx.caller.user_id() orelse return error.Denied;
        const found = if (in.dimension.len > 0)
            site_dimensions.find(ctx, in.dimension)
        else
            site_dimensions.setting(ctx);
        const dimension = found orelse {
            return if (in.dimension.len > 0 or in.code.len > 0) error.Invalid else .{
                .dimension = "",
                .code = "",
            };
        };
        const listed = try site_dimensions.values_of(ctx, dimension);
        const kept = if (other_of(listed, in.code)) in.code else "";

        if (in.code.len > 0 and kept.len == 0) {
            return error.Invalid;
        }

        try store.settings.set(ctx.db, try key_of(ctx, dimension.name, user), kept, ctx.now_ms);

        return .{
            .dimension = dimension.name,
            .code = kept,
        };
    }
};

/// What the person chose, as the combination a read asks for: each dimension at its choice,
/// the main values left out.
pub fn chosen_pairs(ctx: *Ctx) Error![]const model_dimension.Pair {
    std.debug.assert(ctx.now_ms >= 0);

    const read = try sdk_dispatch(ctx);
    var out: std.ArrayList(model_dimension.Pair) = .empty;

    // Only a dimension that moves the whole site (its values have addresses) is chosen for
    // the person; the others are chosen where content is edited.
    for (read.dimensions) |one| {
        const site_wide = for (one.values) |value| {
            if (value.address.len > 0) {
                break true;
            }
        } else false;

        if (one.chosen.len > 0 and site_wide) {
            out.append(ctx.arena, .{
                .dimension = one.dimension,
                .code = one.chosen,
            }) catch return error.OutOfMemory;
        }
    }

    return out.items;
}

fn sdk_dispatch(ctx: *Ctx) Error!Dimensions.Out {
    std.debug.assert(ctx.now_ms >= 0);

    return @import("../../server/registry.zig").SDK.dispatch(ctx, Dimensions, .{});
}

fn key_of(ctx: *Ctx, dimension: []const u8, user: []const u8) Error![]const u8 {
    std.debug.assert(user.len > 0);
    std.debug.assert(dimension.len > 0);

    return std.mem.concat(ctx.arena, u8, &.{ person_prefix, dimension, ":", user }) catch {
        return error.OutOfMemory;
    };
}

/// Whether `code` is one of the values other than the main one.
fn other_of(listed: []const site_dimensions.Value, code: []const u8) bool {
    std.debug.assert(listed.len <= site_dimensions.values_max);

    for (listed) |value| {
        if (!value.main and std.mem.eql(u8, value.code, code)) {
            return true;
        }
    }

    return false;
}
