//! Devices: agents and tools a person lets act for their account, signing in by link. This
//! file is the device's side (asking, collecting its token); `device/people.zig` the
//! person's (approving, listing, revoking).
const operation = @import("../operation.zig");
const device_model = @import("../model/device.zig");

pub const approve_path = "/admin/settings/devices/approve";

pub const namespace: operation.Namespace = .{
    .name = "device",
    .label = "Devices and agents",
    .area = .people,
    .summary = "Agents and tools acting for an account, signed in by link",
    .details =
    \\A device (an agent, the CLI on another machine) asks with `device start` and shows
    \\its person a link; they open it signed in to the admin and approve it, choosing
    \\what it may do: `read`, `drafts` (write, but publishing waits for a person) or
    \\`write`. The device collects its token with `device poll` and sends it as
    \\`Authorization: Bearer <token>`. `publr login <address>` does all of this.
    \\
    \\A device acts as its account with that account's roles, narrowed by its scope. It
    \\never destroys anything for good (deleting a content type, purging a record): that
    \\is done in the admin. Its changes show in the activity log as `token:<id>`.
    \\`device list` and `device revoke` manage them.
    \\
    \\An MCP client signs in the same way through OAuth (`/oauth/authorize`,
    \\`/oauth/token`): `device authorize` makes its request, the person approves it on the
    \\same page, and `device exchange` trades the code it is sent back with for its token.
    ,
};

pub const people = @import("device/people.zig");
pub const oauth = @import("device/oauth.zig");
pub const Offer = @import("device/offer.zig").Offer;
pub const Poll = collect.Poll;
pub const Claim = collect.Claim;
pub const Redeem = collect.Redeem;
const collect = @import("device/collect.zig");

pub const example_device_code = "9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c";

pub const Start = struct {
    pub const name = "device.start";
    pub const description = "Ask to act for an account: answers the link a person approves";
    pub const details =
        \\Anyone may call it. `name` is what the person will see ("An agent on Ada's
        \\laptop"), `scope` what the device asks to do (the person may give less). Show
        \\the person `approve_path` on this site (it carries the user code), then call
        \\`device poll` with `device_code` every `interval_s` seconds until it answers.
        \\The request lapses after ten minutes.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        name: []const u8,
        scope: []const u8 = "production",
    };
    pub const Out = struct {
        device_code: []const u8,
        user_code: []const u8,
        approve_path: []const u8,
        expires_at: i64,
        interval_s: u32,
    };
    pub const example: In = .{
        .name = "An agent on Ada's laptop",
        .scope = "production",
    };
    pub const example_out: Out = .{
        .device_code = example_device_code,
        .user_code = "WXZB-CDFG",
        .approve_path = approve_path ++ "?code=WXZB-CDFG",
        .expires_at = 1792232000000,
        .interval_s = device_model.poll_interval_s,
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "What the person sees, 1 to 80 characters",
        .scope = "What the device asks to do: `read`, `write`, `production` or `publish`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .device_code = "The device's secret for `device poll`; never shown to anyone",
        .user_code = "The code the person approves",
        .approve_path = "Where the person approves it, on this site",
        .expires_at = "When the request lapses, Unix milliseconds",
        .interval_s = "How often to poll, in seconds",
    };
};
