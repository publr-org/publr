const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/apps/edit.zig");
const registry = @import("../../server/registry.zig");
const apps = @import("../apps.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Edit = struct {
    pub const shape = public.Edit;
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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.old.len == 0) {
            return error.Invalid;
        }

        const read = try registry.SDK.dispatch(ctx, apps.Read, .{
            .path = in.path,
        });

        // A file that is not text is replaced whole with `apps write`, never edited.
        if (read.encoding != .text) {
            return error.Invalid;
        }

        const found = std.mem.count(u8, read.content, in.old);

        if (found == 0) {
            return ctx.fail(not_there);
        }

        if (found > 1) {
            return ctx.fail(not_once);
        }

        const at = std.mem.indexOf(u8, read.content, in.old).?;
        const changed = std.mem.concat(ctx.arena, u8, &.{
            read.content[0..at],
            in.new,
            read.content[at + in.old.len ..],
        }) catch return error.OutOfMemory;

        std.debug.assert(changed.len + in.old.len == read.content.len + in.new.len);

        const written = try registry.SDK.dispatch(ctx, apps.Write, .{
            .path = in.path,
            .content = changed,
        });

        return .{
            .path = written.path,
            .bytes = written.bytes,
        };
    }
};

const not_there: sdk.operation.Failure = .{
    .name = "NotThere",
    .status = 409,
    .message = "`old` is not in the file: read it (`apps read`) and give its text exactly",
};

const not_once: sdk.operation.Failure = .{
    .name = "NotOnce",
    .status = 409,
    .message = "`old` is in the file more than once: give more of the text around it",
};
