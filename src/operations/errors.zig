//! The error log: one entry per top-level call refused or failed, reads too, written after
//! its rollback (`operations/activity.zig` writes both logs). Read only: `errors.list`.

const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const activity = @import("activity.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "errors",
    .summary = "What was refused or failed: every such call, kept forever",
    .details =
    \\One entry per top-level call refused (denied, invalid input, a dependency) or
    \\failed, reads included: who, when, the operation, its input with secrets masked,
    \\the error, its message, and the inner operation it came from. Never changed or
    \\removed.
    ,
};

pub const Item = struct {
    id: i64,
    at: i64,
    actor: []const u8,
    app: []const u8,
    operation: []const u8,
    input: []const u8,
    calls: []const []const u8,
    @"error": []const u8,
    message: []const u8,
    failed_in: []const u8,
};

pub const List = struct {
    pub const name = "errors.list";
    pub const description = "What was refused or failed, newest first";
    pub const details =
        \\Administrators only. Filters: who, the operation, a time range in milliseconds.
        \\Page back with `before`, the id of the oldest entry shown.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        actor: ?[]const u8 = null,
        operation: ?[]const u8 = null,
        since: ?i64 = null,
        until: ?i64 = null,
        before: ?i64 = null,
        limit: u32 = 50,
    };
    pub const Out = struct { entries: []const Item };
    pub const rules: sdk.operation.Rules(In) = .{
        .limit = .{ .min = 1, .max = store.errors.list_max },
    };
    pub const example: In = .{ .operation = "plugin.disable" };
    pub const example_out: Out = .{ .entries = &.{.{
        .id = 7,
        .at = 1_790_000_000_000,
        .actor = "u_admin",
        .app = "",
        .operation = "plugin.disable",
        .input = "{\"names\":[\"inventory\"]}",
        .calls = &.{},
        .@"error" = "Failed",
        .message = "cart depends on inventory. To disable them together: " ++
            "publr plugin disable --names cart,inventory",
        .failed_in = "",
    }} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .actor = "Who: a user id, `system`, `anonymous` or `plugin:<name>`",
        .operation = "One operation, `record.save`",
        .since = "From this time, milliseconds",
        .until = "Before this time, milliseconds",
        .before = "Only entries older than this id: the next page",
        .limit = "Page size",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .entries = "Newest first: id, time, who, operation, masked input, error, message",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.limit <= store.errors.list_max);

        const rows = try store.errors.list(ctx.db, ctx.arena, .{
            .actor = in.actor,
            .operation = in.operation,
            .since = in.since,
            .until = in.until,
            .before = in.before,
        }, in.limit);
        const items = ctx.arena.alloc(Item, rows.len) catch return error.OutOfMemory;

        for (rows, items) |row, *item| {
            item.* = .{
                .id = row.id,
                .at = row.at,
                .actor = row.actor,
                .app = row.app,
                .operation = row.operation,
                .input = row.input,
                .calls = try activity.names_of(ctx, row.calls),
                .@"error" = row.@"error",
                .message = row.message,
                .failed_in = row.failed_in,
            };
        }

        return .{ .entries = items };
    }
};

pub const operations = [_]type{List};
