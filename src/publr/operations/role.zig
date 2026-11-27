//! The roles, what each lets its accounts call, and changing them.
const operation = @import("../operation.zig");
const role = @import("../model/role.zig");
const event_define = @import("../plugin/hook_define.zig").event;

/// A role as the role operations answer it.
pub const Listed = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8 = "",
    /// `core`, the plugin that declared it first, or empty for one the site made.
    owner: []const u8 = "",
    grants: []const []const u8,
    /// What code declares for it, core and every plugin together; empty for the site's own.
    declared: []const []const u8 = &.{},
    /// How many accounts hold it.
    holders: u32 = 0,
    /// Its grants are not what code declares for it (`role reset` puts them back).
    changed: bool = false,
    /// `admin`: everything, never changed or removed.
    locked: bool = false,
};

pub const locked: operation.Failure = .{
    .name = "Locked",
    .status = 409,
    .message = "Administrator holds everything and never changes",
};

pub const only_role: operation.Failure = .{
    .name = "OnlyRole",
    .status = 409,
    .message = "It is some account's only role: give them another first",
};

const example_listed: Listed = .{
    .name = "editor",
    .label = "Editor",
    .description = "The content: records, terms and their history.",
    .owner = role.owner_core,
    .grants = &.{ "record.*", "!record.purge" },
    .declared = &.{ "record.*", "!record.purge" },
    .holders = 3,
};

pub const given_by_type: operation.Failure = .{
    .name = "GivenByType",
    .status = 409,
    .message = "A type of user gives this role: it cannot reach the admin",
};

pub const namespace: operation.Namespace = .{
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
    \\never changes. An account holds the roles it is given, none unless asked, and may
    \\call what any of them grants. Only an account that may call one of the admin's
    \\operations (anything outside `app.*`) gets into the admin. Administrators only.
    ,
};

pub const List = struct {
    pub const name = "role.list";
    pub const description = "List every role with its grants, who declared it and its holders";
    pub const details =
        \\Administrators only: what `user create --roles` and `user update --roles` accept,
        \\in the order the roles were made. Nothing is written.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        roles: []const Listed,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .roles = &.{example_listed},
    };
    pub const output_docs: operation.Docs(Out) = .{
        .roles = "name, label, description, owner, grants, declared, holders, changed, locked",
    };
};

pub const Get = struct {
    pub const name = "role.get";
    pub const description = "One role with its grants, who declared it and its holders";
    pub const details =
        \\Administrators only. Fails as not found for a name no role has.
    ;
    pub const kind: operation.Kind = .read;
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
        .role = example_listed,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The role's name",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .role = "As `role list` gives it",
    };
};

pub const Create = struct {
    pub const name = "role.create";
    pub const description = "Make a role of the site's own";
    pub const details =
        \\Administrators only. `copy` starts it with another role's grants, `grants` adds to
        \\them. Fails as invalid for a bad name, label or grant, when the name is taken, or
        \\when the project holds 64 roles already; as not found when `copy` names no role;
        \\as `GivenByType` when a type of user gives the name and the grants reach past
        \\what visitors call.
    ;
    pub const kind: operation.Kind = .write;
    pub const failures = [_]operation.Failure{given_by_type};
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
    pub const field_docs: operation.Docs(In) = .{
        .name = "[a-z][a-z0-9_]*, 1 to 32 characters",
        .label = "As the admin names it, 1 to 64 characters",
        .description = "One sentence, up to 200 characters",
        .grants = "Grants: `record.save`, `record.*`, `!record.purge`",
        .copy = "A role whose grants it starts with",
    };
    pub const output_docs: operation.Docs(Out) = Get.output_docs;
};

pub const Update = struct {
    pub const name = "role.update";
    pub const description = "Change a role's label, description and grants";
    pub const details =
        \\Administrators only. `grants` is the whole list, in place of the one it had. Fails
        \\as not found for a name no role has, as `Locked` for `admin`, as invalid for a
        \\bad label, description or grant, and as `GivenByType` when a type of user gives
        \\the role and the grants reach past what visitors call: staff and visitors are two
        \\ladders.
    ;
    pub const kind: operation.Kind = .write;
    pub const failures = [_]operation.Failure{ locked, given_by_type };
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
    pub const field_docs: operation.Docs(In) = .{
        .name = "The role's name",
        .label = "As the admin names it, 1 to 64 characters",
        .description = "One sentence, up to 200 characters",
        .grants = "Every grant it keeps",
    };
    pub const output_docs: operation.Docs(Out) = Get.output_docs;
};

pub const Reset = struct {
    pub const name = "role.reset";
    pub const description = "Put a role's grants back to what code declares for it";
    pub const details =
        \\Administrators only. Its grants become those core and every plugin declared for
        \\it; its label and description stay. Fails as not found for a name no role has, as
        \\`Locked` for `admin`, and as invalid for a role no code declares (the site's own).
    ;
    pub const kind: operation.Kind = .write;
    pub const failures = [_]operation.Failure{ locked, given_by_type };
    pub const In = Get.In;
    pub const Out = Get.Out;
    pub const example: In = Get.example;
    pub const example_out: Out = Get.example_out;
    pub const field_docs: operation.Docs(In) = Get.field_docs;
    pub const output_docs: operation.Docs(Out) = Get.output_docs;
};

pub const Remove = struct {
    pub const name = "role.remove";
    pub const description = "Remove a role and take it from its holders; it waits in the trash";
    pub const details =
        \\Administrators only. Its holders lose it; `trash restore --id` brings the role and
        \\its holders back. Code never makes it again. Fails as not found for a name no role
        \\has, as `Locked` for `admin`, and as `OnlyRole` while it is any account's only role.
    ;
    pub const kind: operation.Kind = .write;
    pub const failures = [_]operation.Failure{ locked, only_role };
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
    pub const field_docs: operation.Docs(In) = Get.field_docs;
    pub const output_docs: operation.Docs(Out) = .{
        .removed = "The role's name",
        .trash = "Its trash entry",
    };
};

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

/// A grant left a role a type of user gives: the plugin's update took the operation from
/// visitors, and a type's people never reach what staff call.
pub const GrantDropped = event_define(.{
    .name = "role.grant_dropped",
    .payload = struct {
        /// The role's name
        role: []const u8,
        /// The grant that went: the operation's name
        grant: []const u8,
    },
});
