const std = @import("std");
const sdk = @import("../sdk.zig");
const release = @import("../model/release.zig");
const heartbeat = @import("heartbeat.zig");
const public = @import("../publr/operations/update.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

const managed_failure = public.managed_failure;
const not_started = public.not_started;
const unreachable_failure = public.unreachable_failure;

pub const Status = struct {
    pub const shape = public.Status;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(heartbeat.version.len > 0);

        const updater = ctx.updater orelse return .{
            .version = heartbeat.version,
            .managed = false,
            .step = "idle",
            .target = "",
            .message = "",
            .previous = null,
            .backups = &.{},
        };
        const status = updater.status(updater.context, ctx.arena);

        return .{
            .version = heartbeat.version,
            .managed = updater.managed,
            .step = status.step,
            .target = status.target,
            .message = status.message,
            .previous = status.previous,
            .backups = status.backups,
        };
    }
};

pub const Check = struct {
    pub const shape = public.Check;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const failures = shape.failures;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(heartbeat.version.len > 0);

        const updater = ctx.updater orelse return error.Unavailable;
        const found = updater.releases(updater.context, ctx.arena);

        if (!found.looking and found.problem.len > 0) {
            return ctx.fail(unreachable_failure);
        }

        return .{
            .version = heartbeat.version,
            .managed = updater.managed,
            .releases = found.releases,
            .looking = found.looking,
        };
    }
};

pub const Apply = struct {
    pub const shape = public.Apply;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const failures = shape.failures;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(heartbeat.version.len > 0);

        if (!release.newer(heartbeat.version, in.version)) {
            return error.Invalid;
        }

        const updater = ctx.updater orelse return error.Unavailable;

        if (updater.managed) {
            return ctx.fail(managed_failure);
        }

        if (updater.start(updater.context, .apply, in.version)) |why| {
            std.log.warn("update to {s}: {s}", .{ in.version, why });
            return ctx.fail(not_started);
        }

        const update_kind = release.kind_between(heartbeat.version, in.version) catch
            return error.Invalid;

        return .{
            .started = true,
            .kind = update_kind,
        };
    }
};

pub const Rollback = struct {
    pub const shape = public.Rollback;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const failures = shape.failures;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(heartbeat.version.len > 0);

        const updater = ctx.updater orelse return error.Unavailable;

        if (updater.managed) {
            return ctx.fail(managed_failure);
        }

        const previous = updater.status(updater.context, ctx.arena).previous orelse
            return error.NotFound;

        if (updater.start(updater.context, .rollback, previous)) |why| {
            std.log.warn("rollback to {s}: {s}", .{ previous, why });
            return ctx.fail(not_started);
        }

        return .{
            .started = true,
            .to = previous,
        };
    }
};

pub const operations = [_]type{ Status, Check, Apply, Rollback };

test "update.status answers this release with no updater, and apply is unavailable" {
    const TestSDK = sdk.SDK(.{
        .operations = &operations,
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const status = try TestSDK.dispatch(&ctx, Status, .{});

    try std.testing.expectEqualStrings(heartbeat.version, status.version);
    try std.testing.expectEqualStrings("idle", status.step);
    try std.testing.expectError(error.Unavailable, TestSDK.dispatch(&ctx, Apply, .{
        .version = "99.0.0",
    }));
    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&ctx, Apply, .{
        .version = "0.0.1",
    }));
}
