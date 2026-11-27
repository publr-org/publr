//! The statuses a record can be in and the moves between them: `status.list`.
const operation = @import("../operation.zig");
const status = @import("../model/status.zig");

pub const namespace: operation.Namespace = .{
    .name = "status",
    .label = "Statuses",
    .area = .background,
    .summary = "The lifecycle states a record can be in",
    .details =
    \\Publr ships `draft`, `published` and `archived`; plugins add more (a review
    \\workflow, scheduling). A status says whether a record is live (delivered and
    \\referenceable), whether it is listed by default, and which one new records
    \\start in. Transitions are the named moves between them, shown as buttons. A type
    \\with a flow of its own keeps its statuses and moves in its definition.
    ,
};

pub const List = struct {
    pub const name = "status.list";
    pub const description = "List every status and transition, core and plugins together";
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        statuses: []const status.Status,
        transitions: []const status.Transition,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .statuses = &status.core_statuses,
        .transitions = &status.core_transitions,
    };
    pub const output_docs: operation.Docs(Out) = .{
        .statuses = "id, label, color, and the live/listed/initial flags",
        .transitions = "from (`*` = any), to, and the button label",
    };
};
