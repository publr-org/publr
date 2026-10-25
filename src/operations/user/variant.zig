//! What a person reads and edits content in, in the admin: one value per dimension of the
//! site's (with the languages plugin, the content language; with an A/B test, its
//! variation). Their own choice, apart from the language the admin speaks to them; each
//! dimension's main value until they choose. The site's visitors choose on the site.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const variants = @import("../variants.zig");
const model_dimension = @import("../../model/dimension.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

const person_prefix = "content_variant:";

/// One dimension as the person sees it: what it is, its values, their choice.
pub const Chosen = struct {
    /// The dimension's name: `language`.
    dimension: []const u8,
    /// The admin's picker for it, top right; empty for none.
    picker: []const u8,
    /// The code chosen; empty for the main value.
    chosen: []const u8,
    values: []const variants.Variant,
};

pub const Variant = struct {
    pub const name = "user.variant";
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

        const every = variants.all(ctx);
        const out = ctx.arena.alloc(Chosen, every.len) catch return error.OutOfMemory;

        std.debug.assert(every.len <= model_dimension.dimensions_max);

        for (every, out) |dimension, *one| {
            const values = try variants.values_of(ctx, dimension);
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

pub const SetVariant = struct {
    pub const name = "user.set_variant";
    pub const description = "Choose what you read and edit content in, in the admin";
    pub const details =
        \\Any signed-in account, for itself: in `dimension` (empty: the one with pages of its
        \\own, else the highest priority one), a code `user variant` lists, or empty for the
        \\main value. Lists, the editor and the visual editor open in it.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {
        dimension: []const u8 = "",
        variant: []const u8 = "",
    };
    pub const Out = struct {
        dimension: []const u8,
        variant: []const u8,
    };
    // As a site with no dimension takes it: back to the main value.
    pub const example: In = .{};
    pub const example_out: Out = .{
        .dimension = "",
        .variant = "",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .dimension = "The dimension (`language`); empty for the site's first",
        .variant = "One of its codes (`pl`), or empty for its main value",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .dimension = "The dimension chosen in; empty on a site with none",
        .variant = "Your choice now; empty for the main value",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user = ctx.caller.user_id() orelse return error.Denied;
        const found = if (in.dimension.len > 0)
            variants.find(ctx, in.dimension)
        else
            variants.setting(ctx);
        const dimension = found orelse {
            return if (in.dimension.len > 0 or in.variant.len > 0) error.Invalid else .{
                .dimension = "",
                .variant = "",
            };
        };
        const listed = try variants.values_of(ctx, dimension);
        const kept = if (other_of(listed, in.variant)) in.variant else "";

        if (in.variant.len > 0 and kept.len == 0) {
            return error.Invalid;
        }

        try store.settings.set(ctx.db, try key_of(ctx, dimension.name, user), kept, ctx.now_ms);

        return .{
            .dimension = dimension.name,
            .variant = kept,
        };
    }
};

/// What the person chose, as the combination a read asks for: each dimension at its choice,
/// the main values left out.
pub fn chosen_pairs(ctx: *Ctx) Error![]const model_dimension.Pair {
    std.debug.assert(ctx.now_ms >= 0);

    const read = try sdk_dispatch(ctx);
    var out: std.ArrayList(model_dimension.Pair) = .empty;

    for (read.dimensions) |one| {
        if (one.chosen.len > 0) {
            out.append(ctx.arena, .{
                .dimension = one.dimension,
                .code = one.chosen,
            }) catch return error.OutOfMemory;
        }
    }

    return out.items;
}

fn sdk_dispatch(ctx: *Ctx) Error!Variant.Out {
    std.debug.assert(ctx.now_ms >= 0);

    return @import("../../server/registry.zig").SDK.dispatch(ctx, Variant, .{});
}

fn key_of(ctx: *Ctx, dimension: []const u8, user: []const u8) Error![]const u8 {
    std.debug.assert(user.len > 0);
    std.debug.assert(dimension.len > 0);

    return std.mem.concat(ctx.arena, u8, &.{ person_prefix, dimension, ":", user }) catch {
        return error.OutOfMemory;
    };
}

/// Whether `code` is one of the values other than the main one.
fn other_of(listed: []const variants.Variant, code: []const u8) bool {
    std.debug.assert(listed.len <= variants.variants_max);

    for (listed) |variant| {
        if (!variant.main and std.mem.eql(u8, variant.code, code)) {
            return true;
        }
    }

    return false;
}
