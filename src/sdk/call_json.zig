//! Calling an operation by its name with JSON in and out: a built-in operation is parsed
//! and dispatched as any other; one an installed plugin brings goes through the same steps
//! (pre hooks, authorization, the transaction, hooks, events) with its body in the sandbox.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");
const json = @import("../lib/json.zig");
const Event = @import("middleware.zig").Event;

const Error = operation.Error;

pub fn call(comptime SDK: type, ctx: *Ctx, name: []const u8, input: []const u8) Error![]const u8 {
    @setEvalBranchQuota(200_000);

    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    inline for (SDK.operations) |Operation| {
        if (std.mem.eql(u8, Operation.name, name)) {
            const in = json.parse(Operation.In, ctx.arena, input, .{
                .allocate = .alloc_always,
            }) catch return error.Invalid;
            const out = try SDK.dispatch(ctx, Operation, in);

            return @import("../sdk.zig").stringify(ctx.arena, out);
        }
    }

    const sandboxed = ctx.sandboxed_plugins orelse return error.NotFound;
    const found = sandboxed.find(name) orelse return error.NotFound;

    return dispatch(SDK, ctx, sandboxed, found, input);
}

/// The resource an operation is about, read from its input by the same convention built-in
/// operations follow: `type`, `id`, and `to` or `status`.
const ResourceFields = struct {
    type: ?[]const u8 = null,
    id: ?[]const u8 = null,
    to: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

fn dispatch(
    comptime SDK: type,
    ctx: *Ctx,
    sandboxed: *const sandboxed_plugins.SandboxedPlugins,
    found: sandboxed_plugins.Operation,
    input: []const u8,
) Error![]const u8 {
    std.debug.assert(found.name.len > 0);
    std.debug.assert(input.len > 0);

    if (ctx.plugin_depth == sandboxed_plugins.depth_max) {
        return error.Invalid;
    }

    const operation_id = ctx.allocate_operation_id();
    const parent = ctx.parent;
    const notify = ctx.notify;
    const within = ctx.within;

    ctx.parent = operation_id;
    ctx.notify = &SDK.emit_notice;
    ctx.plugin_depth += 1;
    defer ctx.parent = parent;
    defer ctx.notify = notify;
    defer ctx.within = within;
    defer ctx.plugin_depth -= 1;

    admit(SDK, ctx, found, input) catch |err| {
        SDK.emit(ctx, .{ .rejected = .{
            .operation_name = found.name,
            .operation_id = operation_id,
            .err = err,
        } });

        return err;
    };

    ctx.within = found.name;

    const result = run(ctx, sandboxed, found, input);

    if (result) |_| {
        SDK.emit(ctx, .{ .completed = .{
            .operation_name = found.name,
            .operation_id = operation_id,
            .duration_ns = 0,
        } });
    } else |err| {
        SDK.emit(ctx, .{ .failed = .{
            .operation_name = found.name,
            .operation_id = operation_id,
            .err = err,
        } });
    }

    return result;
}

fn admit(
    comptime SDK: type,
    ctx: *Ctx,
    found: sandboxed_plugins.Operation,
    input: []const u8,
) Error!void {
    std.debug.assert(found.name.len > 0);
    std.debug.assert(ctx.parent != null);

    try SDK.run_pre_hooks(ctx, found.name);

    const fields = json.parse(ResourceFields, ctx.arena, input, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.Invalid;

    _ = try SDK.authorize_request(ctx, .{
        .operation_name = found.name,
        .kind = found.kind,
        .resource = .{
            .type_id = fields.type,
            .record_id = fields.id,
            .to_status = fields.to orelse fields.status,
        },
        .open = found.open,
    });
}

fn run(
    ctx: *Ctx,
    sandboxed: *const sandboxed_plugins.SandboxedPlugins,
    found: sandboxed_plugins.Operation,
    input: []const u8,
) Error![]const u8 {
    std.debug.assert(ctx.parent != null);
    std.debug.assert(found.name.len > 0);

    const changed = if (sandboxed.hooked(.before, found.name))
        try sandboxed.before(ctx, found.name, input)
    else
        input;
    const output = try execute(ctx, sandboxed, found, changed);

    if (sandboxed.hooked(.after, found.name)) {
        try sandboxed.after(ctx, found.name, changed, output);
    }

    return output;
}

fn execute(
    ctx: *Ctx,
    sandboxed: *const sandboxed_plugins.SandboxedPlugins,
    found: sandboxed_plugins.Operation,
    input: []const u8,
) Error![]const u8 {
    std.debug.assert(ctx.parent != null);
    std.debug.assert(found.name.len > 0);

    if (found.kind == .read) {
        return sandboxed.run(ctx, found, input);
    }

    var transaction = try ctx.db.transaction();
    errdefer transaction.rollback();

    const output = try sandboxed.run(ctx, found, input);

    try transaction.commit();

    std.debug.assert(output.len > 0);

    return output;
}

test "an unknown name without plugins is not found" {
    var harness: @import("../sdk.zig").testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const TestSDK = @import("../sdk.zig").SDK(.{
        .operations = &.{@import("../sdk.zig").testing.Record},
    });

    try std.testing.expectError(error.NotFound, call(TestSDK, &ctx, "nope.verb", "{}"));

    const out = try call(TestSDK, &ctx, "hello.record", "{\"note\":\"hi\"}");

    try std.testing.expectEqualStrings("{\"rows\":1}", out);
    try std.testing.expectError(error.Invalid, call(TestSDK, &ctx, "hello.record", "{"));
}
