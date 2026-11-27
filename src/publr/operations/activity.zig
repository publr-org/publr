//! The activity log: one entry per top-level write that completed, written in its
//! transaction from the call's trail (`sdk/trail.zig`), its secrets masked
//! (`model/secret.zig`), what it changed named as units. Read only: `activity.list`.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "activity",
    .label = "Activity log",
    .area = .system,
    .summary = "What was done: every completed write, kept forever",
    .details =
    \\One entry per top-level write: who, when, through which app, the operation, its
    \\input with secrets masked, the operations it set off inside and what it changed
    \\(`record:<id>`, `plugin:<name>`). Entries are never changed or removed. Refused and
    \\failed calls are in `errors`.
    ,
};

pub const Line = struct {
    plugin: []const u8,
    /// `info`, `warn` or `err`.
    level: []const u8,
    line: []const u8,
};

pub const Item = struct {
    id: i64,
    at: i64,
    actor: []const u8,
    app: []const u8,
    operation: []const u8,
    /// The call's input, its secrets masked; null when it had none.
    input: ?operation.Json,
    units: []const []const u8,
    calls: []const []const u8,
    /// What plugins logged during the call, in order.
    lines: []const Line = &.{},
};

pub const List = struct {
    pub const name = "activity.list";
    pub const description = "What was done, newest first";
    pub const details =
        \\Administrators only. Filters: who (a user id, `system`, `anonymous`, or
        \\`plugin:<name>`), the operation, a unit it changed, a time range in milliseconds.
        \\Page back with `before`, the id of the oldest entry shown.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        actor: ?[]const u8 = null,
        operation: ?[]const u8 = null,
        unit: ?[]const u8 = null,
        since: ?i64 = null,
        until: ?i64 = null,
        before: ?i64 = null,
        limit: u32 = 50,
    };
    pub const Out = struct {
        entries: []const Item,
    };
    pub const example: In = .{
        .operation = "plugin.enable",
    };
    pub const example_out: Out = .{
        .entries = &.{.{
            .id = 42,
            .at = 1_790_000_000_000,
            .actor = "u_admin",
            .app = "",
            .operation = "plugin.enable",
            .input = .{
                .text = "{\"names\":[\"greeter\"]}",
            },
            .units = &.{"plugin:greeter"},
            .calls = &.{},
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .actor = "Who: a user id, `system`, `anonymous`, `plugin:<name>` or " ++
            "`job:<plugin>.<name>`",
        .operation = "One operation, `plugin.disable`",
        .unit = "A unit the entry changed, `record:<id>` or `plugin:<name>`",
        .since = "From this time, milliseconds",
        .until = "Before this time, milliseconds",
        .before = "Only entries older than this id: the next page",
        .limit = "Page size",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .entries = "Newest first: id, time, who, app, operation, masked input, units, calls",
    };
};
