const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const status = @import("../model/status.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "status",
    .summary = "The lifecycle states a record can be in",
    .details =
    \\Publr ships `draft`, `published` and `archived`; plugins add more (a review
    \\workflow, scheduling). A status says whether a record is live (delivered and
    \\referenceable), whether it is listed by default, and which one new records
    \\start in. Transitions are the named moves between them, shown as buttons.
    ,
};

pub const List = struct {
    pub const name = "status.list";
    pub const description = "List every status and transition, core and plugins together";
    pub const kind: sdk.operation.Kind = .read;
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
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .statuses = "id, label, color, and the live/listed/initial flags",
        .transitions = "from (`*` = any), to, and the button label",
    };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(registry.Statuses.all.len > 0);

        return .{
            .statuses = registry.Statuses.all,
            .transitions = registry.Statuses.all_transitions,
        };
    }
};

pub const operations = [_]type{List};
