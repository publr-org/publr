//! The columns plugins add to People (`.register_columns` on `users`) that a person hides:
//! their own choice, else the one administrators made for everyone, else none hidden.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

const everyone_key = "people_columns";
const person_prefix = "people_columns:";

pub const Columns = struct {
    pub const name = "user.columns";
    pub const description = "The plugins' columns on People you hide";
    pub const details =
        \\Any signed-in account, about itself: `hidden` names the columns plugins add to
        \\People that it does not show, by field (`loyalty.points`): its own choice, else
        \\the one administrators made for everyone.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {};
    pub const Out = struct {
        hidden: []const []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .hidden = &.{},
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .hidden = "The columns not shown, by field",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const user = ctx.caller.user_id() orelse return error.Denied;
        const key = std.mem.concat(ctx.arena, u8, &.{ person_prefix, user }) catch {
            return error.OutOfMemory;
        };
        const saved = try store.settings.get(ctx.db, ctx.arena, key) orelse
            try store.settings.get(ctx.db, ctx.arena, everyone_key) orelse "[]";
        const hidden = std.json.parseFromSliceLeaky([]const []const u8, ctx.arena, saved, .{}) catch
            &.{};

        return .{
            .hidden = hidden,
        };
    }
};

pub const SetColumns = struct {
    pub const name = "user.set_columns";
    pub const description = "Choose which plugins' columns on People you hide";
    pub const details =
        \\Any signed-in account, for itself: `hidden` names the columns plugins add to People
        \\that it does not show, by field. `for_everyone` (administrators only) makes the
        \\choice everyone starts at who made none.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    /// Open, but about the account asking: its example names one.
    pub const example_signed_in = true;
    pub const In = struct {
        hidden: []const []const u8 = &.{},
        for_everyone: bool = false,
    };
    pub const Out = struct {
        hidden: []const []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .hidden = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .hidden = "Columns plugins add to People, by field (`loyalty.points`)",
        .for_everyone = "Everyone's choice (administrators only)",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .hidden = "The columns not shown now",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user = ctx.caller.user_id() orelse return error.Denied;

        if (in.for_everyone and !ctx.caller.holds("admin")) {
            return error.Denied;
        }

        const all_columns = try registry.all_columns(ctx);

        for (in.hidden) |field| {
            if (!on_people(all_columns, field)) {
                return error.Invalid;
            }
        }

        const key = if (in.for_everyone)
            everyone_key
        else
            std.mem.concat(ctx.arena, u8, &.{ person_prefix, user }) catch {
                return error.OutOfMemory;
            };
        const text = try sdk.stringify(ctx.arena, in.hidden);

        try store.settings.set(ctx.db, key, text, ctx.now_ms);

        return .{
            .hidden = in.hidden,
        };
    }
};

/// Whether a plugin adds a column to People on `field`.
fn on_people(all_columns: []const registry.Column, field: []const u8) bool {
    std.debug.assert(field.len <= 1 << 16);

    for (all_columns) |column| {
        if (column.on("users") and std.mem.eql(u8, column.field, field)) {
            return true;
        }
    }

    return false;
}
