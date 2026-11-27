//! Changing and removing accounts; the rules that keep one admin around.
const operation = @import("../../operation.zig");

const example_id = "9b1e7c3d5a2f4e6b8d0c1a3f";

pub const Update = struct {
    pub const name = "user.update";
    pub const description = "Rename a user or change their roles";
    pub const details =
        \\Admins only. The display name and the roles are replaced together; the email
        \\and the password stay. The last admin cannot lose the `admin` role, and no
        \\admin can take it from themselves. Every session of the account stays open.
        \\With `document`, the custom field values are replaced too, validated against
        \\the groups that apply to the account's new roles (`user get` shows them).
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
        display_name: []const u8,
        roles: []const []const u8,
        document: ?operation.Json = null,
    };
    pub const Out = struct {
        user_id: []const u8,
        roles: []const []const u8,
    };
    pub const example: In = .{
        .user = "editor@example.com",
        .display_name = "Editor",
        .roles = &.{"admin"},
    };
    pub const example_out: Out = .{
        .user_id = example_id,
        .roles = &.{"admin"},
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The user's id or email",
        .display_name = "Name shown in the admin, 1 to 80 characters",
        .roles = "The roles the account holds from now on, comma-separated (`role list`)",
        .document = "The custom field values as JSON, one object per group; omitted, they stay",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user_id = "The user's id",
        .roles = "The roles the account holds now",
    };
};

pub const Delete = struct {
    pub const name = "user.delete";
    pub const description = "Delete a user into the trash and sign out every session they have";
    pub const details =
        \\Admins only. The account waits in the trash with its roles and fields, and
        \\`trash restore` brings it back (signed out: its sessions and devices never come
        \\back). What the person created stays, attributed to their id. You cannot delete
        \\yourself, and the last admin cannot be deleted.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
    };
    pub const Out = struct {
        user_id: []const u8,
        sessions_revoked: u32,
    };
    pub const example: In = .{
        .user = "editor@example.com",
    };
    pub const example_out: Out = .{
        .user_id = example_id,
        .sessions_revoked = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The user's id or email",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user_id = "The deleted user's id",
        .sessions_revoked = "How many of their sessions were signed out",
    };
};
