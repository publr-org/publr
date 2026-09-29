const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const role = @import("../model/role.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "role",
    .summary = "What each role lets its accounts call",
    .details =
    \\A role is data: a name, a label and grants. A grant names an operation
    \\(`record.save`), a namespace and everything under it (`record.*`,
    \\`app.newsletter.*`) or everything (`*`); a grant starting with `!` takes names
    \\back from the role. Core declares `admin` and `editor`; each built-in plugin
    \\declares its own, or adds grants to one that exists. An account holds one or more
    \\roles and may call what any of them grants. Only an account that may call one of
    \\the admin's operations (anything outside `app.*`) gets into the admin.
    ,
};

pub const List = struct {
    pub const name = "role.list";
    pub const description = "List every role, core and plugins together, with its grants";
    pub const details =
        \\Administrators only: what `user create --roles` and `user update --roles`
        \\accept. Nothing is written.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { roles: []const role.Role };
    pub const example: In = .{};
    pub const example_out: Out = .{ .roles = &role.core };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .roles = "name, label, description and grants, in the order declared",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        return .{ .roles = registry.Roles.all };
    }
};

pub const operations = [_]type{List};
