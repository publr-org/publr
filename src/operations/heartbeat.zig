const std = @import("std");
const sdk = @import("../sdk.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const version = "0.2.0";

pub const namespace: sdk.operation.Namespace = .{
    .name = "heartbeat",
    .summary = "Liveness and version checks",
    .details =
    \\Operations that never touch data: use them to check that Publr is up, which
    \\version is running, and who you are calling as.
    ,
};

pub const Check = struct {
    pub const name = "heartbeat.check";
    pub const description = "Check that Publr is alive; reports version and caller";
    pub const details =
        \\The simplest operation there is: it never touches the database and anyone
        \\may call it. Use it to check a deployment, to see which version runs, and
        \\to confirm who you are calling as (`--as`, `--as-admin`, or a session
        \\cookie over HTTP, where it backs `GET /api/health`).
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { echo: []const u8 = "" };
    pub const Out = struct { version: []const u8, echo: []const u8, caller: []const u8 };
    pub const example: In = .{ .echo = "hello" };
    pub const example_out: Out = .{ .version = version, .echo = "hello", .caller = "system" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .echo = "Any text; it comes back unchanged, handy for tracing a request",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .version = "The Publr version answering",
        .echo = "The echo you sent",
        .caller = "Who you are: `anonymous`, `system`, or a user id",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(echo_len_max > 0);

        if (in.echo.len > echo_len_max) {
            return error.Invalid;
        }

        return .{ .version = version, .echo = in.echo, .caller = ctx.caller.label() };
    }
};

pub const echo_len_max: u32 = 256;
pub const operations = [_]type{Check};

test "heartbeat.check echoes and names the caller" {
    const TestSDK = sdk.SDK(.{ .operations = &operations });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.{ .user = .{ .id = "u_1" } });
    const out = try TestSDK.dispatch(&ctx, Check, .{ .echo = "hi" });

    try std.testing.expectEqualStrings(version, out.version);
    try std.testing.expectEqualStrings("hi", out.echo);
    try std.testing.expectEqualStrings("u_1", out.caller);
}
