const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const role = @import("../model/role.zig");
const trash = @import("trash.zig");
const rows = @import("role/rows.zig");

const event_define = @import("../sdk/plugin/hook_define.zig").event;

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Listed = rows.Listed;

pub const namespace: sdk.operation.Namespace = .{
    .name = "role",
    .label = "Roles",
    .area = .people,
    .summary = "The roles, what each lets its accounts call, and changing them",
    .details =
    \\A role is a row: a name, a label and grants. A grant names an operation
    \\(`record.save`), a namespace and everything under it (`record.*`,
    \\`app.newsletter.*`) or everything (`*`); a grant starting with `!` takes names
    \\back from the role. Code declares roles (core's `admin`, `editor` and
    \\`contributor`, each plugin's), made the first time it declares them; the site
    \\changes them, makes its own and removes them. A plugin's update adds only the
    \\grants new in it, so what the site changed stays. `admin` grants everything and
    \\never changes. An account holds one or more roles and may call what any of them
    \\grants. Only an account that may call one of the admin's operations (anything
    \\outside `app.*`) gets into the admin. Administrators only.
    ,
};

pub const List = struct {
    pub const name = "role.list";
    pub const description = "List every role with its grants, who declared it and its holders";
    pub const details =
        \\Administrators only: what `user create --roles` and `user update --roles` accept,
        \\in the order the roles were made. Nothing is written.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        roles: []const Listed,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .roles = &.{rows.example},
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .roles = "name, label, description, owner, grants, declared, holders, changed, locked",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const found = try store.roles.list(ctx.db, ctx.arena);
        const listed = ctx.arena.alloc(Listed, found.len) catch return error.OutOfMemory;

        for (found, listed) |row, *out| {
            out.* = try rows.listed(ctx, row);
        }

        return .{
            .roles = listed,
        };
    }
};

pub const Get = struct {
    pub const name = "role.get";
    pub const description = "One role with its grants, who declared it and its holders";
    pub const details =
        \\Administrators only. Fails as not found for a name no role has.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        role: Listed,
    };
    pub const example: In = .{
        .name = "editor",
    };
    pub const example_out: Out = .{
        .role = rows.example,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The role's name",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .role = "As `role list` gives it",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.name.len <= 4096);

        return .{
            .role = try rows.listed(ctx, try rows.find(ctx, in.name)),
        };
    }
};

pub const Create = struct {
    pub const name = "role.create";
    pub const description = "Make a role of the site's own";
    pub const details =
        \\Administrators only. `copy` starts it with another role's grants, `grants` adds to
        \\them. Fails as invalid for a bad name, label or grant, when the name is taken, or
        \\when the project holds 64 roles already; as not found when `copy` names no role.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        label: []const u8,
        description: []const u8 = "",
        grants: []const []const u8 = &.{},
        copy: []const u8 = "",
    };
    pub const Out = Get.Out;
    pub const example: In = .{
        .name = "reviewer",
        .label = "Reviewer",
        .copy = "contributor",
    };
    pub const example_out: Out = .{
        .role = .{
            .name = "reviewer",
            .label = "Reviewer",
            .owner = "",
            .grants = &.{ "record.*", "!record.publish", "!record.purge" },
            .holders = 0,
        },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "[a-z][a-z0-9_]*, 1 to 32 characters",
        .label = "As the admin names it, 1 to 64 characters",
        .description = "One sentence, up to 200 characters",
        .grants = "Grants: `record.save`, `record.*`, `!record.purge`",
        .copy = "A role whose grants it starts with",
    };
    pub const output_docs: sdk.operation.Docs(Out) = Get.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!role.valid_name(in.name) or try sdk.stored_roles.exists(ctx, in.name)) {
            return error.Invalid;
        }

        if (try store.roles.count(ctx.db) >= role.roles_max) {
            return error.Invalid;
        }

        const copied = if (in.copy.len > 0)
            try store.role_grants.of(ctx.db, ctx.arena, (try rows.find(ctx, in.copy)).name)
        else
            &.{};
        const both = [_][]const []const u8{ copied, in.grants };
        const grants = std.mem.concat(ctx.arena, []const u8, &both) catch {
            return error.OutOfMemory;
        };
        const row: store.roles.Row = .{
            .name = in.name,
            .label = in.label,
            .description = in.description,
        };

        try rows.check(row, grants);
        try store.roles.insert(ctx.db, row, ctx.now_ms);
        try store.role_grants.set(ctx.db, in.name, grants);
        ctx.emit(Created, .{
            .role = in.name,
        });

        return .{
            .role = try rows.listed(ctx, row),
        };
    }
};

pub const Update = struct {
    pub const name = "role.update";
    pub const description = "Change a role's label, description and grants";
    pub const details =
        \\Administrators only. `grants` is the whole list, in place of the one it had. Fails
        \\as not found for a name no role has, as `Locked` for `admin`, and as invalid for a
        \\bad label, description or grant.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const failures = [_]sdk.operation.Failure{rows.locked};
    pub const In = struct {
        name: []const u8,
        label: []const u8,
        description: []const u8 = "",
        grants: []const []const u8,
    };
    pub const Out = Get.Out;
    pub const example: In = .{
        .name = "editor",
        .label = "Editor",
        .grants = &.{ "record.*", "!record.purge", "media.*" },
    };
    pub const example_out: Out = .{
        .role = .{
            .name = "editor",
            .label = "Editor",
            .owner = role.owner_core,
            .grants = &.{ "record.*", "!record.purge", "media.*" },
            .declared = &.{ "record.*", "!record.purge" },
            .holders = 3,
            .changed = true,
        },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The role's name",
        .label = "As the admin names it, 1 to 64 characters",
        .description = "One sentence, up to 200 characters",
        .grants = "Every grant it keeps",
    };
    pub const output_docs: sdk.operation.Docs(Out) = Get.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const found = try rows.changeable(ctx, in.name);
        const row: store.roles.Row = .{
            .name = found.name,
            .label = in.label,
            .description = in.description,
            .owner = found.owner,
        };

        try rows.check(row, in.grants);
        try store.roles.update(ctx.db, row, ctx.now_ms);
        try store.role_grants.set(ctx.db, found.name, in.grants);
        ctx.emit(Updated, .{
            .role = found.name,
        });

        return .{
            .role = try rows.listed(ctx, row),
        };
    }
};

pub const Reset = struct {
    pub const name = "role.reset";
    pub const description = "Put a role's grants back to what code declares for it";
    pub const details =
        \\Administrators only. Its grants become those core and every plugin declared for
        \\it; its label and description stay. Fails as not found for a name no role has, as
        \\`Locked` for `admin`, and as invalid for a role no code declares (the site's own).
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const failures = [_]sdk.operation.Failure{rows.locked};
    pub const In = Get.In;
    pub const Out = Get.Out;
    pub const example: In = Get.example;
    pub const example_out: Out = Get.example_out;
    pub const field_docs: sdk.operation.Docs(In) = Get.field_docs;
    pub const output_docs: sdk.operation.Docs(Out) = Get.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const found = try rows.changeable(ctx, in.name);
        const declared = try store.role_declarations.patterns_for(ctx.db, ctx.arena, found.name);

        if (found.owner.len == 0 or declared.len > role.grants_max) {
            return error.Invalid;
        }

        try store.role_grants.set(ctx.db, found.name, declared);
        ctx.emit(Updated, .{
            .role = found.name,
        });

        return .{
            .role = try rows.listed(ctx, found),
        };
    }
};

pub const Remove = struct {
    pub const name = "role.remove";
    pub const description = "Remove a role and take it from its holders; it waits in the trash";
    pub const details =
        \\Administrators only. Its holders lose it; `trash restore --id` brings the role and
        \\its holders back. Code never makes it again. Fails as not found for a name no role
        \\has, as `Locked` for `admin`, and as `OnlyRole` while it is any account's only role.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const failures = [_]sdk.operation.Failure{ rows.locked, rows.only_role };
    pub const In = Get.In;
    pub const Out = struct {
        removed: []const u8,
        /// Its trash entry: `trash restore --id` brings it back.
        trash: []const u8,
    };
    pub const example: In = .{
        .name = "contributor",
    };
    pub const example_out: Out = .{
        .removed = "contributor",
        .trash = "0190a1b2c3d40001a1b2c3d4",
    };
    pub const field_docs: sdk.operation.Docs(In) = Get.field_docs;
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .removed = "The role's name",
        .trash = "Its trash entry",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const found = try rows.changeable(ctx, in.name);

        if (try store.user_roles.sole_holders(ctx.db, found.name) > 0) {
            return ctx.fail(rows.only_role);
        }

        const label = std.fmt.allocPrint(ctx.arena, "Role {s}", .{found.label}) catch {
            return error.OutOfMemory;
        };
        const trash_id = try trash.keep(ctx, .{
            .kind = "role",
            .key = found.name,
            .label = label,
            .roots = try rows.roots_of(ctx, found.name),
        });

        try rows.drop(ctx, found.name);
        ctx.emit(Removed, .{
            .role = found.name,
        });

        return .{
            .removed = found.name,
            .trash = trash_id,
        };
    }
};

pub const operations = [_]type{ List, Get, Create, Update, Reset, Remove };

test {
    _ = @import("role/tests.zig");
}

/// What a role's events carry.
pub const Changed = struct {
    /// The role's name
    role: []const u8,
};

/// A role was made.
pub const Created = event_define(.{
    .name = "role.created",
    .payload = Changed,
});
/// A role's label, description or grants changed, or went back to what was declared.
pub const Updated = event_define(.{
    .name = "role.updated",
    .payload = Changed,
});
/// A role was removed.
pub const Removed = event_define(.{
    .name = "role.removed",
    .payload = Changed,
});
