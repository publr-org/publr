//! A device collecting its token: asking whether its person decided (`poll`, a read, so
//! waiting writes nothing), then taking the token once (`claim`); or getting one at once
//! through the trusted issuer (`redeem`).
const operation = @import("../../operation.zig");
const device = @import("../device.zig");

pub const Poll = struct {
    pub const name = "device.poll";
    /// Never written to the logs.
    pub const secret = .{"device_code"};
    pub const description = "Whether a device's person decided yet";
    pub const details =
        \\Anyone holding the device code may call it. `state` is `pending` (ask again
        \\after `interval_s`), `approved` (take the token with `device claim`), `denied`, or
        \\`expired` (or unknown). It writes nothing, so asking often costs nothing.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        device_code: []const u8,
    };
    pub const Out = struct {
        state: []const u8,
    };
    pub const example: In = .{
        .device_code = device.example_device_code,
    };
    pub const example_out: Out = .{
        .state = "pending",
    };
    pub const field_docs: operation.Docs(In) = .{
        .device_code = "What `device start` answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .state = "`pending`, `approved`, `denied` or `expired`",
    };
};

pub const Claim = struct {
    pub const name = "device.claim";
    /// Never written to the logs.
    pub const secret = .{"device_code"};
    pub const description = "Take an approved device's token, once";
    pub const details =
        \\Anyone holding the device code may call it, once `device poll` says `approved`.
        \\The token is given once and the request used up; keep the token like a password.
        \\Not found while the request waits, or once it was denied, lapsed or claimed.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        device_code: []const u8,
        /// For a sign-in offered from the admin, which has no name of the device's own.
        name: ?[]const u8 = null,
    };
    pub const Out = struct {
        token: []const u8,
        user_id: []const u8,
        scope: []const u8,
    };
    pub const example: In = .{
        .device_code = device.example_device_code,
    };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .scope = "production",
    };
    pub const field_docs: operation.Docs(In) = .{
        .device_code = "What `device start` answered, or the code `device offer` answered",
        .name = "What the device is called, 1 to 80 characters; the request's own name " ++
            "when left out",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .token = "`id.secret`, for `Authorization: Bearer`",
        .user_id = "The account it acts for",
        .scope = "What the person let it do",
    };
};

pub const Redeem = struct {
    pub const name = "device.redeem";
    /// Never written to the logs.
    pub const secret = .{"token"};
    pub const description = "Get a device's token with a sign-on token the trusted issuer signed";
    pub const details =
        \\Anyone may call it: the sign-on token is the credential, as for `sign_on redeem`,
        \\and is used up. The issuer (a Publr Cloud dashboard) has its person's approval
        \\already; the device it names acts for the account the token names, under `scope`.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        token: []const u8,
        name: []const u8,
        scope: []const u8,
    };
    pub const Out = struct {
        token: []const u8,
        user_id: []const u8,
        device_id: []const u8,
    };
    pub const example: In = .{
        .token = "eyJhdWQiOiJhMWIyYzNkNGU1ZjZhN2I4Ii4uLn0.c2lnbmF0dXJl...",
        .name = "A chat app",
        .scope = "production",
    };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .device_id = "56a0794f6b1c67062563204a",
    };
    pub const field_docs: operation.Docs(In) = .{
        .token = "The sign-on token the issuer signed",
        .name = "What the device is called, 1 to 80 characters",
        .scope = "`read`, `write`, `production` or `publish`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .token = "The device's token, `id.secret`; treat it like a password",
        .user_id = "The account it acts for",
        .device_id = "The device, as `device list` shows it",
    };
};
