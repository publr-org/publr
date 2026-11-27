//! The error log: one entry per top-level call refused or failed, reads too, written after
//! its rollback (`operations/activity.zig` writes both logs). Read only: `errors.list`.
const operation = @import("../operation.zig");
const activity = @import("activity.zig");

pub const namespace: operation.Namespace = .{
    .name = "errors",
    .label = "Error log",
    .area = .system,
    .summary = "What was refused or failed: every such call, kept forever",
    .details =
    \\One entry per top-level call refused (denied, invalid input, a dependency) or
    \\failed, reads included: who, when, the operation, its input with secrets masked,
    \\the error, its message, the inner operation it came from, and what plugins logged
    \\in it. A call that answered but whose plugin logged an `.err` line is here too, as
    \\error `Logged`. Never changed or removed.
    ,
};

pub const Item = struct {
    id: i64,
    at: i64,
    actor: []const u8,
    app: []const u8,
    operation: []const u8,
    /// The call's input, its secrets masked; null when it had none.
    input: ?operation.Json,
    calls: []const []const u8,
    @"error": []const u8,
    message: []const u8,
    failed_in: []const u8,
    /// What plugins logged during the call, in order.
    lines: []const activity.Line = &.{},
};

pub const List = struct {
    pub const name = "errors.list";
    pub const description = "What was refused or failed, newest first";
    pub const details =
        \\Administrators only. Filters: who, the operation, a time range in milliseconds.
        \\Page back with `before`, the id of the oldest entry shown.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        actor: ?[]const u8 = null,
        operation: ?[]const u8 = null,
        since: ?i64 = null,
        until: ?i64 = null,
        before: ?i64 = null,
        limit: u32 = 50,
    };
    pub const Out = struct {
        entries: []const Item,
    };
    pub const example: In = .{
        .operation = "plugin.disable",
    };
    pub const example_out: Out = .{
        .entries = &.{.{
            .id = 7,
            .at = 1_790_000_000_000,
            .actor = "u_admin",
            .app = "",
            .operation = "plugin.disable",
            .input = .{
                .text = "{\"names\":[\"inventory\"]}",
            },
            .calls = &.{},
            .@"error" = "Failed",
            .message = "cart depends on inventory. To disable them together: " ++
                "publr plugin disable --names cart,inventory",
            .failed_in = "",
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .actor = "Who: a user id, `system`, `anonymous` or `plugin:<name>`",
        .operation = "One operation, `record.save`",
        .since = "From this time, milliseconds",
        .until = "Before this time, milliseconds",
        .before = "Only entries older than this id: the next page",
        .limit = "Page size",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .entries = "Newest first: id, time, who, operation, masked input, error, message",
    };
};
