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

    inline for (comptime owned(declared, plugin)) |index| {
        const Operation = declared.operations[index];

        run_one(registry.SDK, Operation) catch |err| {
            std.debug.print("example of {s}: {t}\n", .{ Operation.name, err });
            failed += 1;
        };
    }

    if (failed > 0) {
        return error.ExampleFailed;
    }
}

/// Where the plugin's own operations (`publr.operation.define`) are in the registry, found
/// once: a budget that grows with the registry, never a scan per operation.
fn owned(comptime declared: sdk.Registry, comptime plugin: []const u8) []const u32 {
    comptime {
        // Each owner's name compared once, a few branches a byte.
        @setEvalBranchQuota(1000 + declared.operations.len * (plugin.len + 16) * 4);

        std.debug.assert(declared.operation_owners.len == declared.operations.len);

        var found: []const u32 = &.{};

        for (declared.operations, declared.operation_owners, 0..) |Operation, owner, index| {
            if (std.mem.eql(u8, owner, plugin) and @hasDecl(Operation, "definition")) {
                found = found ++ .{index};
            }
        }

        return found;
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
        error.Failed => declared_failure(Operation, ctx.failure) or not_found(ctx.failure),
        else => false,
    };
}

/// Nothing found, or the site's state, in the words of an operation the example's own
/// called (a ledger account an empty site never opened, nothing owed on it yet): a 404 or a
/// 409 is never a refusal of the example's input, as `NotFound` and `Conflict` are not.
fn not_found(failure: ?sdk.operation.Failure) bool {
    const named = failure orelse return false;

    std.debug.assert(named.status >= 400);
    std.debug.assert(named.status <= 599);

    return named.status == 404 or named.status == 409;
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
