//! The variant a person reads and edits content in, in the admin (with the languages plugin:
//! the content language). Their own choice, apart from the language the admin speaks to
//! them; the main variant until they choose. The site's visitors choose on the site.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const variants = @import("../variants.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

const person_prefix = "content_variant:";

pub const Variant = struct {
    pub const name = "user.variant";
    pub const description = "The variant you read and edit content in, in the admin";
    pub const details =
        \\Any signed-in account, about itself: `chosen` is the code of its choice, empty for
        \\the main variant (also when the choice is no longer one of the site's), and
        \\`variants` the site's, the main one first; empty while no plugin declares variants.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct {};
    pub const Out = struct {
        chosen: []const u8,
        variants: []const variants.Variant,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .chosen = "pl",
        .variants = &.{.{
            .code = "en",
            .label = "English",
            .main = true,
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .chosen = "Your choice's code; empty for the main variant",
        .variants = "The site's variants: `code`, `label`, `address`, `main`",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const listed = try variants.listed(ctx);
        const user = ctx.caller.user_id() orelse return .{
            .chosen = "",
            .variants = listed,
        };
        const key = try key_of(ctx, user);
        const value = try store.settings.get(ctx.db, ctx.arena, key) orelse "";

        return .{
            .chosen = if (other_of(listed, value)) value else "",
            .variants = listed,
        };
    }
};

pub const SetVariant = struct {
    pub const name = "user.set_variant";
    pub const description = "Choose the variant you read and edit content in, in the admin";
    pub const details =
        \\Any signed-in account, for itself: a code `user variant` lists, or empty for the
        \\main variant. Lists, the editor and the visual editor open in it.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        variant: []const u8,
    };
    pub const Out = struct {
        variant: []const u8,
    };
    pub const example: In = .{
        .variant = "pl",
    };
    pub const example_out: Out = .{
        .variant = "pl",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .variant = "A variant's code (`pl`), or empty for the main one",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .variant = "Your choice now; empty for the main variant",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user = ctx.caller.user_id() orelse return error.Denied;
        const listed = try variants.listed(ctx);
        const kept = if (other_of(listed, in.variant)) in.variant else "";

        if (in.variant.len > 0 and kept.len == 0) {
            return error.Invalid;
        }

        try store.settings.set(ctx.db, try key_of(ctx, user), kept, ctx.now_ms);

        return .{
            .variant = kept,
        };
    }
};

fn key_of(ctx: *Ctx, user: []const u8) Error![]const u8 {
    std.debug.assert(user.len > 0);

    return std.mem.concat(ctx.arena, u8, &.{ person_prefix, user }) catch error.OutOfMemory;
}

/// Whether `code` is one of the site's variants other than the main one.
fn other_of(listed: []const variants.Variant, code: []const u8) bool {
    std.debug.assert(listed.len <= variants.variants_max);

    for (listed) |variant| {
        if (!variant.main and std.mem.eql(u8, variant.code, code)) {
            return true;
        }
    }

    return false;
}
