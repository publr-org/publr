//! A sign-in offered to a person's own computer: approved as it is made, by the person signed
//! in to the admin, and collected once with `device claim` by whoever holds its code within
//! ten minutes. What the Overview's agent command carries, so setting up a computer is one
//! command with nothing to approve.
const operation = @import("../../operation.zig");

pub const Offer = struct {
    /// Its example runs as a signed-in account (`--as`).
    pub const example_signed_in = true;
    pub const name = "device.offer";
    pub const description = "Offer this account's sign-in to a computer, as a one-time code";
    pub const details =
        \\Signed-in people only (not a device). Makes a device request already approved for
        \\the caller's account under `scope`, and answers its code: whoever holds it takes
        \\the token once with `device claim --device_code <code>`, within ten minutes. Treat
        \\the code like a password until it is used or lapses.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        scope: []const u8 = "publish",
    };
    pub const Out = struct {
        code: []const u8,
        expires_at: i64,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .code = "k7q2xm4pw9tz3hbd",
        .expires_at = 1792232000000,
    };
    pub const field_docs: operation.Docs(In) = .{
        .scope = "What the computer may do: `read`, `write`, `production` or `publish` " ++
            "(the default)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .code = "The one-time code, for `device claim`",
        .expires_at = "When it lapses, Unix milliseconds",
    };
};
