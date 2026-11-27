//! Giving an account a type of user, or taking one: an account holds any number of them,
//! staff accounts included (an administrator who is also a customer of the shop). A type
//! brings the roles it gives (`.roles`) and takes them when it goes, unless another type the
//! account holds gives them too. The admin is reached by roles alone, so neither ever opens
//! or closes it for staff.
//!
//! A plugin holding `users.own` gives and takes only its own types, on any account: it never
//! touches another role, a password or a sign-in.
const operation = @import("../../operation.zig");

pub const TypeIn = struct {
    user: []const u8,
    user_type: []const u8,
};

pub const TypeOut = struct {
    user_id: []const u8,
    user_types: []const []const u8,
    roles: []const []const u8,
};

const example_in: TypeIn = .{
    .user = "ada@example.com",
    .user_type = "customer",
};

const in_docs: operation.Docs(TypeIn) = .{
    .user = "The account's id or email",
    .user_type = "A type of user a plugin registers (`customer`, `user_type list`)",
};

const out_docs: operation.Docs(TypeOut) = .{
    .user_id = "The account's id",
    .user_types = "The types the account holds now",
    .roles = "The roles the account holds now",
};

pub const AddType = struct {
    pub const name = "user.add_type";
    pub const description = "Give an account a type of user (an administrator becomes a customer)";
    pub const details =
        \\Administrators, and plugins: `users.write`, or `users.own` for the types the plugin
        \\registers, on any account. The account gets the type and the roles the type gives
        \\(`.roles`); its other roles, its password and its sign-ins stay. It may then sign
        \\in to the apps the type opens. Giving a type it holds changes nothing. Fails as
        \\invalid for a type no plugin registers.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = TypeIn;
    pub const Out = TypeOut;
    pub const example = example_in;
    pub const example_out: TypeOut = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .user_types = &.{"customer"},
        .roles = &.{ "admin", "customer" },
    };
    pub const field_docs = in_docs;
    pub const output_docs = out_docs;
};

pub const RemoveType = struct {
    pub const name = "user.remove_type";
    pub const description = "Take a type of user from an account";
    pub const details =
        \\Administrators, and plugins: `users.write`, or `users.own` for the types the plugin
        \\registers, on any account. The account loses the type and the roles it gave, but
        \\keeps any of them another type it holds gives, and every other role, its password
        \\and its sign-ins. An account left with no type and no role keeps signing in to
        \\nothing until it is given one. Taking a type it does not hold changes nothing.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = TypeIn;
    pub const Out = TypeOut;
    pub const example = example_in;
    pub const example_out: TypeOut = .{
        .user_id = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .user_types = &.{},
        .roles = &.{"admin"},
    };
    pub const field_docs = in_docs;
    pub const output_docs = out_docs;
};
