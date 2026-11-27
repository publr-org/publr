//! The columns plugins add to People (`.register_columns` on `users`) or the media library
//! (`media`) that a person hides: their own choice, else the one administrators made for
//! everyone, else none hidden.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/user/columns.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Columns = struct {
    pub const shape = public.Columns;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const field_docs = shape.field_docs;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const user = ctx.caller.user_id() orelse return error.Denied;
        const key = std.mem.concat(ctx.arena, u8, &.{ key_of(in.list), ":", user }) catch {
            return error.OutOfMemory;
        };
        const saved = try store.settings.get(ctx.db, ctx.arena, key) orelse
            try store.settings.get(ctx.db, ctx.arena, key_of(in.list)) orelse "[]";
        const hidden = std.json.parseFromSliceLeaky([]const []const u8, ctx.arena, saved, .{}) catch
            &.{};

        return .{
            .hidden = hidden,
        };
    }
};

pub const SetColumns = struct {
    pub const shape = public.SetColumns;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user = ctx.caller.user_id() orelse return error.Denied;

        if (in.for_everyone and !ctx.caller.holds("admin")) {
            return error.Denied;
        }

        const all_columns = try registry.all_columns(ctx);

        for (in.hidden) |field| {
            if (!on_list(all_columns, @tagName(in.list), field)) {
                return error.Invalid;
            }
        }

        const key = if (in.for_everyone)
            key_of(in.list)
        else
            std.mem.concat(ctx.arena, u8, &.{ key_of(in.list), ":", user }) catch {
                return error.OutOfMemory;
            };
        const text = try sdk.stringify(ctx.arena, in.hidden);

        try store.settings.set(ctx.db, key, text, ctx.now_ms);

        return .{
            .hidden = in.hidden,
        };
    }
};

/// Whether a plugin adds a column to `list` on `field`.
fn on_list(all_columns: []const registry.Column, list: []const u8, field: []const u8) bool {
    std.debug.assert(field.len <= 1 << 16);

    for (all_columns) |column| {
        if (column.on(list) and std.mem.eql(u8, column.field, field)) {
            return true;
        }
    }

    return false;
}

const List = public.List;

/// The setting a list's choice is kept in.
fn key_of(list: List) []const u8 {
    std.debug.assert(std.enums.values(List).len == 2);

    return switch (list) {
        .users => "people_columns",
        .media => "media_columns",
    };
}
