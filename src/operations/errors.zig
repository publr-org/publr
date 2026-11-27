//! The error log: one entry per top-level call refused or failed, reads too, written after
//! its rollback (`operations/activity.zig` writes both logs). Read only: `errors.list`.

const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const activity = @import("activity.zig");
const public = @import("../publr/operations/errors.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const Item = public.Item;

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

        if (in.limit < 1 or in.limit > store.errors.list_max) {
            return ctx.refuse(&.{.{
                .field = "limit",
                .message = std.fmt.comptimePrint("A page is 1 to {d} entries.", .{
                    store.errors.list_max,
                }),
            }});
        }

        const rows = try store.errors.list(ctx.db, ctx.arena, .{
            .actor = in.actor,
            .operation = in.operation,
            .since = in.since,
            .until = in.until,
            .before = in.before,
        }, in.limit);
        const items = ctx.arena.alloc(Item, rows.len) catch return error.OutOfMemory;
        const logged = try activity.lines_of(ctx, .@"error", rows);

        for (rows, items) |row, *item| {
            item.* = .{
                .id = row.id,
                .at = row.at,
                .actor = row.actor,
                .app = row.app,
                .operation = row.operation,
                .input = try activity.input_of(ctx, row.input),
                .calls = try activity.names_of(ctx, row.calls),
                .@"error" = row.@"error",
                .message = row.message,
                .failed_in = row.failed_in,
                .lines = try activity.lines_for(ctx, logged, .@"error", row.id),
            };
        }

        return .{
            .entries = items,
        };
    }
};

pub const operations = [_]type{List};
