//! `apps edit`: a change to one part of a file, not the whole file written again. A small
//! change (a word in a heading, one rule in a stylesheet) is then a few words to send.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const apps = @import("../apps.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Edit = struct {
    pub const name = "apps.edit";
    pub const description = "Change one part of a file of the project's apps; `apps load` " ++
        "makes it live";
    pub const details =
        \\Administrators only. `old` must appear exactly once in the file (give enough of the
        \\text around it to make it so); it is replaced by `new`. Refused, changing nothing,
        \\when `old` is not there or is there more than once, and, like `apps write`, to a
        \\device that may save drafts only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        path: []const u8,
        old: []const u8,
        new: []const u8,
    };
    pub const Out = struct {
        path: []const u8,
        bytes: u64,
    };
    pub const example: In = .{
        .path = "www/content/index.publr",
        .old = "<h1>Hi</h1>",
        .new = "<h1>Hello</h1>",
    };
    pub const example_out: Out = .{
        .path = "www/content/index.publr",
        .bytes = 15,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .path = "`<app>/<path>`",
        .old = "The text to change, exactly as it is in the file, once",
        .new = "What it becomes; empty to remove it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .path = "The file",
        .bytes = "Its size now",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.old.len == 0) {
            return error.Invalid;
        }

        const read = try registry.SDK.dispatch(ctx, apps.Read, .{
            .path = in.path,
        });
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
