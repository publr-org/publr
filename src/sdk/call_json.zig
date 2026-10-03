//! Calling an operation by its name with JSON in and out: a built-in operation is parsed
//! and dispatched as any other; one an installed plugin brings goes through the same steps
//! (pre hooks, authorization, the transaction, hooks, events) with its body in the sandbox.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");
const sandboxed_plugins = @import("sandboxed_plugins.zig");
const json = @import("../lib/json.zig");
const Event = @import("middleware.zig").Event;
const contract = @import("../model/contract.zig");
const plugin_names = @import("../model/plugin_contracts.zig");
const Value = std.json.Value;

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
    var trail_state: @import("trail.zig").Trail = .{ .root = operation_id };
    const opened = SDK.trail_open(ctx, &trail_state);

    defer SDK.trail_close(ctx, opened);
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
        SDK.log_failure(ctx, found.name, input, found.secret, err);

        return err;
    };

    ctx.within = found.name;

    const result = run(SDK, ctx, sandboxed, found, input);

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
        SDK.log_failure(ctx, found.name, input, found.secret, err);
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
    try SDK.check_fence(ctx, plugin_names.plugin_of(found.name));

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
    comptime SDK: type,
    ctx: *Ctx,
    sandboxed: *const sandboxed_plugins.SandboxedPlugins,
    found: sandboxed_plugins.Operation,
    input: []const u8,
) Error![]const u8 {
    std.debug.assert(ctx.parent != null);
    std.debug.assert(input.len > 0);

    if (found.kind == .read) {
        return run_pipeline(SDK, ctx, sandboxed, found, input);
    }

    // As `SDK.run`: hooks inside the write's transaction, nested writes as savepoints.
    const previous_failure = ctx.dependency_failure;

    ctx.dependency_failure = false;
    defer ctx.dependency_failure = previous_failure;

    var transaction = try ctx.db.transaction();
    errdefer transaction.rollback();

    const output = try run_pipeline(SDK, ctx, sandboxed, found, input);

    if (ctx.dependency_failure) {
        return error.InvalidationFailed;
    }

    try SDK.log_activity(ctx, found.name, input, found.secret);
    try transaction.commit();

    return output;
}

fn run_pipeline(
    comptime SDK: type,
    ctx: *Ctx,
    sandboxed: *const sandboxed_plugins.SandboxedPlugins,
    found: sandboxed_plugins.Operation,
    input: []const u8,
) Error![]const u8 {
    std.debug.assert(ctx.parent != null);
    std.debug.assert(found.name.len > 0);

    if (found.input.len > 0) {
        const value = std.json.parseFromSliceLeaky(Value, ctx.arena, input, .{}) catch {
            return error.Invalid;
        };

        try @import("../sdk.zig").refuse_broken(ctx, found.input, value);
    }

    const changed = if (sandboxed.hooked(.before, found.name))
        try sandboxed.before(ctx, found.name, input)
    else
        input;
    const resolved = try resolve_references(SDK, ctx, found.input, changed);
    const output = try sandboxed.run(ctx, found, resolved);

    if (sandboxed.hooked(.after, found.name)) {
        try sandboxed.after(ctx, found.name, changed, output);
    }

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

/// An installed operation's references read now, as a compiled-in one's are: each field its
/// shape marks a reference (or a list of them), at the top of the input, becomes
/// `{ id, value }`, the record read with the caller's access.
fn resolve_references(
    comptime SDK: type,
    ctx: *Ctx,
    shape: []const contract.Node,
    input: []const u8,
) Error![]const u8 {
    std.debug.assert(input.len > 0);
    std.debug.assert(shape.len <= contract.nodes_max);

    if (!has_reference(shape)) {
        return input;
    }

    var parsed = std.json.parseFromSliceLeaky(Value, ctx.arena, input, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    for (shape) |node| {
        if (node.kind != .reference or node.parent < 0) {
            continue;
        }

        const holder = shape[@intCast(node.parent)];

        if (node.parent == 0) {
            const value = parsed.object.getPtr(node.name) orelse continue;

            value.* = try record_for(SDK, ctx, node.to, value.*);
        } else if (holder.kind == .list and holder.parent == 0) {
            const list = parsed.object.getPtr(holder.name) orelse continue;

            if (list.* != .array) {
                return error.Invalid;
            }

            for (list.array.items) |*item| {
                item.* = try record_for(SDK, ctx, node.to, item.*);
            }
        }
    }

    return std.json.Stringify.valueAlloc(ctx.arena, parsed, .{}) catch error.OutOfMemory;
}

fn has_reference(shape: []const contract.Node) bool {
    std.debug.assert(shape.len <= contract.nodes_max);

    for (shape) |node| {
        if (node.kind == .reference) {
            return true;
        }
    }

    return false;
}

/// `{ id, value }` for an id: the record of content type `handle`, as `record.get` answers
/// the caller; not found when it is another type's.
fn record_for(comptime SDK: type, ctx: *Ctx, handle: []const u8, id: Value) Error!Value {
    std.debug.assert(handle.len > 0);

    if (id != .string or id.string.len == 0 or id.string.len > 128) {
        return error.Invalid;
    }

    const asked = std.json.Stringify.valueAlloc(ctx.arena, .{ .id = id.string }, .{}) catch {
        return error.OutOfMemory;
    };
    const answer = try call(SDK, ctx, "record.get", asked);
    const Got = struct { record: struct { type: []const u8 }, document: []const u8 };
    const got = std.json.parseFromSliceLeaky(Got, ctx.arena, answer, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;

    if (!std.mem.eql(u8, got.record.type, handle)) {
        return error.NotFound;
    }

    const document = std.json.parseFromSliceLeaky(Value, ctx.arena, got.document, .{}) catch {
        return error.Invalid;
    };
    var pair: std.json.ObjectMap = .empty;

    pair.put(ctx.arena, "id", id) catch return error.OutOfMemory;
    pair.put(ctx.arena, "value", document) catch return error.OutOfMemory;

    return .{ .object = pair };
}
