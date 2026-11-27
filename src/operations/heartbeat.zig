const std = @import("std");
const sdk = @import("../sdk.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

const public = @import("../publr/operations/heartbeat.zig");

pub const version = public.version;
pub const namespace = public.namespace;

pub const Check = struct {
    pub const shape = public.Check;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(echo_len_max > 0);

        if (in.echo.len > echo_len_max) {
            return error.Invalid;
        }

        return .{
            .version = version,
            .echo = in.echo,
            .caller = ctx.caller.label(),
        };
    }
};

const echo_len_max = public.echo_len_max;
pub const operations = [_]type{Check};

test "heartbeat.check echoes and names the caller" {
    const TestSDK = sdk.SDK(.{
        .operations = &operations,
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });
    const out = try TestSDK.dispatch(&ctx, Check, .{
        .echo = "hi",
    });

    try std.testing.expectEqualStrings(version, out.version);
    try std.testing.expectEqualStrings("hi", out.echo);
    try std.testing.expectEqualStrings("u_1", out.caller);
}
