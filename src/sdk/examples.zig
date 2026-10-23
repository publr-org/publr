//! Every `Example:` a plugin's operations give, run as a test against an empty site with the
//! plugin: `zig build`'s `test-native-plugins` runs one per compiled-in plugin. The example
//! is called by an administrator; it passes when the answer has the shape its `out:` shows.
//! A refusal for what an empty site lacks (nothing found, credentials it never issued, a
//! declared failure, someone else's, a service down) passes too; a refusal of the example's
//! own input fails, as does a crash.
const std = @import("std");
const sdk = @import("../sdk.zig");
const shape = @import("shape.zig");

pub const Error = error{ExampleFailed};

/// `registry` is the build's (`publr.registry`), `plugin` the name whose examples run.
pub fn check(comptime registry: type, comptime plugin: []const u8) !void {
    comptime std.debug.assert(plugin.len > 0);

    const declared = registry.registry;
    var failed: u32 = 0;

    inline for (declared.operations, 0..) |Operation, index| {
        const ours = comptime std.mem.eql(u8, declared.operation_owners[index], plugin) and
            @hasDecl(Operation, "definition");

        if (ours) {
            run_one(registry.SDK, Operation) catch |err| {
                std.debug.print("example of {s}: {t}\n", .{ Operation.name, err });
                failed += 1;
            };
        }
    }

    if (failed > 0) {
        return error.ExampleFailed;
    }
}

fn run_one(comptime SDK: type, comptime Operation: type) !void {
    comptime std.debug.assert(Operation.name.len > 0);

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    try SDK.apply_schemas(system.db);
    try SDK.bootstrap(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_example",
            .roles = &.{@import("../model/role.zig").admin},
        },
    });
    const out = SDK.dispatch(&admin, Operation, Operation.example) catch |err| {
        return if (lacking(&admin, Operation, err)) {} else err;
    };

    // The answer as a caller reads it: what it serialises to, read back.
    const text = try sdk.stringify(admin.arena, out);
    const read = try std.json.parseFromSliceLeaky(Operation.Out, admin.arena, text, .{});

    try shape.same(Operation.example_out, read);
}

/// A refusal for what an empty site lacks, never for the example's own input.
fn lacking(ctx: *const sdk.Ctx, comptime Operation: type, err: anyerror) bool {
    std.debug.assert(ctx.now_ms >= 0);

    return switch (err) {
        error.NotFound, error.Denied, error.BadCredentials, error.Conflict => true,
        error.Unavailable => true,
        error.Invalid => ctx.problems.len == 0,
        error.Failed => declared_failure(Operation, ctx.failure),
        else => false,
    };
}

fn declared_failure(comptime Operation: type, failure: ?sdk.operation.Failure) bool {
    comptime std.debug.assert(Operation.name.len > 0);

    const named = failure orelse return false;

    for (Operation.failures) |each| {
        if (std.mem.eql(u8, each.name, named.name)) {
            return true;
        }
    }

    return false;
}
