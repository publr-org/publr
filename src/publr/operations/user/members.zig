//! Members' own accounts of a user type on the site: signing up and asking for
//! a new password, each answered with a set-password link sent by email to a page of the app
//! they are on (the type's `password_page`), redeemed with `user.set_password`. Neither ever
//! says whether an account exists. Staff never use them: their links open the admin.
//!
//! A plugin managing its own type's accounts asks for `users.own`: `user.create`,
//! `user.update` and `user.delete` reach only accounts of the types it registers, never staff
//! or another plugin's.
const operation = @import("../../operation.zig");

pub const Sent = struct {
    sent: bool,
};

pub const SignUp = struct {
    pub const name = "user.sign_up";
    pub const open = true;
    pub const description = "Make an account of a user type on the app the visitor is on";
    pub const details =
        \\Anyone, from an app's page (`POST /api/auth/sign-up` on the site). The type must
        \\let visitors sign up and open the app. The account starts without a password: an
        \\email with a one-hour link to the type's password page on the app sets it, which
        \\proves the address. An address that has an account of the type already gets a
        \\link to set a new password instead. The answer is the same either way, and a
        \\refusal names no reason.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        user_type: []const u8,
        email: []const u8,
        display_name: []const u8,
    };
    pub const Out = Sent;
    pub const example: In = .{
        .user_type = "customer",
        .email = "ada@example.com",
        .display_name = "Ada",
    };
    pub const example_out: Out = .{
        .sent = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .user_type = "The type of account (`customer`)",
        .email = "Where the link goes; the account's sign-in email",
        .display_name = "The person's name",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .sent = "Always true: whether an account existed is never said",
    };
};

pub const RequestReset = struct {
    pub const name = "user.request_reset";
    pub const open = true;
    pub const description = "Send a visitor who forgot their password a link to set a new one";
    pub const details =
        \\Anyone, from an app's page (`POST /api/auth/reset` on the site). When the address
        \\is the sign-in email of an account of a user type that opens the app, it gets a
        \\one-hour link to the type's password page there; the account's earlier link stops
        \\working. The answer is the same whether or not such an account exists.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        email: []const u8,
    };
    pub const Out = Sent;
    pub const example: In = .{
        .email = "ada@example.com",
    };
    pub const example_out: Out = .{
        .sent = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .email = "The account's sign-in email",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .sent = "Always true: whether an account exists is never said",
    };
};
