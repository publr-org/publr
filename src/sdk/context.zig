const std = @import("std");
const db = @import("../lib/db.zig");
const Caller = @import("caller.zig").Caller;
const AuthState = @import("../lib/auth.zig").State;
const Notice = @import("middleware.zig").Event.Notice;

pub const OperationId = u64;
pub const request_id_len_max: u32 = 64;

pub const Notify = *const fn (ctx: *Ctx, notice: Notice) void;

pub const Ctx = struct {
    dependencies: ?*@import("dependencies.zig").Collector = null,
    dependency_failure: bool = false,
    /// Why the last operation ended with `error.Failed`: set by `fail`, read by adapters.
    failure: ?@import("operation.zig").Failure = null,
    publish_policy: ?*const fn (*Ctx, OperationPolicy) anyerror!void = null,
    caller: Caller,
    /// Reads made to render a page for a visitor: live records only and never a write,
    /// whoever the caller is, so a signed-in visitor never sees a draft on the site.
    delivery: bool = false,
    /// The operation whose run made this call, empty for a call an adapter made: a policy
    /// tells a plugin operation's own writes from the same caller writing directly.
    within: []const u8 = "",
    db: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    auth: *AuthState,
    request_id: []const u8 = "",
    parent: ?OperationId = null,
    now_ms: i64,
    next_operation_id: OperationId = 1,
    notify: ?Notify = null,
    /// The installed plugins installed in the project: their operations and hooks.
    sandboxed_plugins: ?*const @import("sandboxed_plugins.zig").SandboxedPlugins = null,
    /// How deep calls nest through installed plugins, bounded by `plugins.depth_max`.
    plugin_depth: u32 = 0,

    pub fn init(options: Options) Ctx {
        std.debug.assert(options.request_id.len <= request_id_len_max);
        std.debug.assert(options.now_ms >= 0);

        return .{
            .caller = options.caller,
            .db = options.db,
            .io = options.io,
            .arena = options.arena,
            .auth = options.auth,
            .request_id = options.request_id,
            .now_ms = options.now_ms,
        };
    }

    pub const OperationPolicy = struct {
        revision: u64,
        no_store: bool,
        revalidate: bool,
        expires: ?i64,
        tags: []const []const u8,
    };

    /// Called by name from the PJSX runtime, hence the name.
    pub fn publrPolicy(ctx: *Ctx, policy: anytype) !void {
        std.debug.assert(policy.expires == null or policy.expires.? >= 0);

        const restricted = policy.no_store or policy.revalidate or
            policy.expires != null or policy.tags.len > 0;

        if (ctx.publish_policy) |publish| {
            return publish(ctx, .{
                .revision = policy.revision,
                .no_store = policy.no_store,
                .revalidate = policy.revalidate,
                .expires = policy.expires,
                .tags = policy.tags,
            });
        }

        if (restricted) {
            return error.PolicyHeadersRequired;
        }
    }

    pub fn collecting(ctx: *Ctx, collector: *@import("dependencies.zig").Collector) Ctx {
        std.debug.assert(collector != ctx.dependencies);
        std.debug.assert(collector.keys.items.len == 0);

        var owned = ctx.*;

        collector.parent = ctx.dependencies;
        owned.dependencies = collector;

        return owned;
    }

    pub fn depend(ctx: *Ctx, prefix: []const u8, id: []const u8) void {
        std.debug.assert(prefix.len + id.len > 0);

        if (ctx.dependencies) |collector| {
            collector.depend(prefix, id);
        }
    }

    /// Ends the operation with a failure its plugin declares: `return ctx.fail(unverified);`.
    /// The write is rolled back like any other error's.
    pub fn fail(ctx: *Ctx, failure: @import("operation.zig").Failure) error{Failed} {
        std.debug.assert(failure.name.len > 0);
        std.debug.assert(failure.status >= 400 and failure.status <= 599);

        ctx.failure = failure;

        return error.Failed;
    }

    pub fn notice(ctx: *Ctx, name: []const u8, subject: []const u8) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.parent != null);

        const emit = ctx.notify orelse return;
        emit(ctx, .{ .operation_id = ctx.parent.?, .name = name, .subject = subject });
    }

    pub fn allocate_operation_id(ctx: *Ctx) OperationId {
        const id = ctx.next_operation_id;
        std.debug.assert(id != 0);

        ctx.next_operation_id += 1;
        std.debug.assert(ctx.next_operation_id > id);

        return id;
    }

    pub const Options = struct {
        caller: Caller,
        db: *db.Db,
        io: std.Io,
        arena: std.mem.Allocator,
        auth: *AuthState,
        request_id: []const u8 = "",
        now_ms: i64 = 0,
    };
};

pub fn wall_clock_ms(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    const ms: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    std.debug.assert(ms >= 0);
    std.debug.assert(ms < std.math.maxInt(i64) / 2);

    return ms;
}

test "operation ids are unique and increasing within a ctx" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var auth_state: AuthState = undefined;
    const params = @import("../lib/auth.zig").password.params_test;
    try auth_state.init(std.testing.allocator, std.testing.io, .{ .params = params });
    defer auth_state.deinit();

    var buffer: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var ctx = Ctx.init(.{
        .caller = .system,
        .db = &fixture.connection,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .auth = &auth_state,
    });

    const first = ctx.allocate_operation_id();
    const second = ctx.allocate_operation_id();

    try std.testing.expect(second > first);
    try std.testing.expectEqual(@as(?OperationId, null), ctx.parent);
    try std.testing.expect(wall_clock_ms(std.testing.io) > 1_700_000_000_000);
}
