//! A plugin's own log (`plugin.log`): the lines it logged with `ctx.log`, newest first, for
//! its Log tab. Read only; the lines are kept for good (`store/plugin_log.zig`).

const std = @import("std");
const public = @import("../../publr/operations/plugin/log.zig");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{Log};

pub const Line = public.Line;

pub const Log = struct {
    pub const shape = public.Log;
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

        if (in.limit < 1 or in.limit > store.plugin_log.list_max) {
            return ctx.refuse(&.{.{
                .field = "limit",
                .message = std.fmt.comptimePrint("A page is 1 to {d} lines.", .{
                    store.plugin_log.list_max,
                }),
            }});
        }

        if (in.name.len == 0) {
            return error.Invalid;
        }

        const rows = try store.plugin_log.of_plugin(
            ctx.db,
            ctx.arena,
            in.name,
            in.before,
            in.limit,
        );
        const lines = ctx.arena.alloc(Line, rows.len) catch return error.OutOfMemory;

        for (rows, lines) |row, *line| {
            line.* = .{
                .id = row.id,
                .at = row.at,
                .level = row.level,
                .line = row.line,
                .call = row.call,
            };
        }

        return .{
            .lines = lines,
        };
    }
};
