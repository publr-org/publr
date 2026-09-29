const std = @import("std");
pub const db = @import("lib/db.zig");

pub const dependencies = @import("sdk/dependencies.zig");
pub const caller = @import("sdk/caller.zig");
pub const context = @import("sdk/context.zig");
pub const operation = @import("sdk/operation.zig");
pub const grant = @import("sdk/grant.zig");
pub const authorize = @import("sdk/authorize.zig");
pub const middleware = @import("sdk/middleware.zig");
pub const delivery = @import("sdk/delivery.zig");
pub const provider = @import("sdk/provider.zig");
pub const sandboxed_plugins = @import("sdk/sandboxed_plugins.zig");
pub const plugin_access = @import("sdk/plugin_access.zig");
pub const call_json = @import("sdk/call_json.zig");

pub const Caller = caller.Caller;
pub const Ctx = context.Ctx;
pub const Error = operation.Error;
pub const Grant = grant.Grant;
pub const Policy = authorize.Policy;
pub const Event = middleware.Event;

pub const operations_max: u32 = 1024;
pub const in_bytes_max: u32 = 64 << 10;

const AuthState = @import("lib/auth.zig").State;
const role = @import("model/role.zig");
const plugin_context = @import("sdk/plugin/context.zig");
const PluginCtx = plugin_context.PluginCtx;

pub const Registry = struct {
    operations: []const type,
    namespaces: []const operation.Namespace = &.{},
    policies: []const Policy = &.{},
    middleware: []const type = &.{},
    schemas: []const [:0]const u8 = &.{},
    /// What a signed-in account's roles grant: the core's, with the plugins' merged in.
    roles: []const role.Role = &role.core,
    /// Runs as the system once the schema is applied: declared content types and the like.
    bootstrap: ?*const fn (*Ctx) Error!void = null,
};

pub const schemas_max: u32 = 64;

pub fn SDK(comptime registry: Registry) type {
    comptime validate_registry(registry);

    return struct {
        pub const operations = registry.operations;
        pub const namespaces = registry.namespaces;
        pub const schemas = registry.schemas;
        pub const roles = registry.roles;

        pub fn apply_schemas(connection: *db.Db) db.Error!void {
            std.debug.assert(connection.transaction_depth == 0);
            comptime std.debug.assert(schemas.len <= schemas_max);

            inline for (schemas) |sql| {
                try connection.exec(sql);
            }
        }

        /// Bring an opened database up to date with what the build declares.
        pub fn bootstrap(ctx: *Ctx) Error!void {
            std.debug.assert(ctx.caller == .system);
            std.debug.assert(ctx.db.transaction_depth == 0);

            const hook = registry.bootstrap orelse return;

            try hook(ctx);
        }

        pub fn namespace_of(comptime name: []const u8) ?operation.Namespace {
            comptime std.debug.assert(name.len > 0);
            comptime std.debug.assert(name.len <= operation.name_len_max);

            inline for (registry.namespaces) |namespace| {
                if (comptime std.mem.eql(u8, namespace.name, name)) {
                    return namespace;
                }
            }

            return null;
        }

        pub fn dispatch(ctx: *Ctx, comptime Operation: type, in: Operation.In) Error!Operation.Out {
            comptime {
                if (find(Operation.name) != Operation) {
                    @compileError("operation not registered: " ++ Operation.name);
                }
            }
            std.debug.assert(@sizeOf(Operation.In) <= in_bytes_max);

            const operation_id = ctx.allocate_operation_id();
            const parent = ctx.parent;
            const started = std.Io.Clock.awake.now(ctx.io);

            const notify = ctx.notify;

            ctx.parent = operation_id;
            ctx.notify = &emit_notice;
            defer ctx.parent = parent;
            defer ctx.notify = notify;

            const granted = admit(ctx, Operation, in) catch |err| {
                emit(ctx, .{ .rejected = .{
                    .operation_name = Operation.name,
                    .operation_id = operation_id,
                    .err = err,
                } });
                return err;
            };

            const within = ctx.within;

            ctx.within = Operation.name;
            defer ctx.within = within;

            const result = run(ctx, Operation, in, &granted);

            if (result) |_| {
                const ended = std.Io.Clock.awake.now(ctx.io);
                const elapsed: u64 = @intCast(@max(0, started.durationTo(ended).nanoseconds));
                emit(ctx, .{ .completed = .{
                    .operation_name = Operation.name,
                    .operation_id = operation_id,
                    .duration_ns = elapsed,
                } });
            } else |err| {
                emit(ctx, .{ .failed = .{
                    .operation_name = Operation.name,
                    .operation_id = operation_id,
                    .err = err,
                } });
            }

            return result;
        }

        fn admit(ctx: *Ctx, comptime Operation: type, in: Operation.In) Error!Grant {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(ctx.now_ms >= 0);

            try run_pre_hooks(ctx, Operation.name);

            return authorize_request(ctx, .{
                .operation_name = Operation.name,
                .kind = Operation.kind,
                .resource = operation.resource_of(in),
                .open = @hasDecl(Operation, "open") and Operation.open,
            });
        }

        /// The core policy, every plugin's policy, and the roles, for one request.
        pub fn authorize_request(ctx: *Ctx, request: authorize.Request) Error!Grant {
            std.debug.assert(request.operation_name.len > 0);
            std.debug.assert(registry.policies.len <= authorize.policies_max);

            const granted = try authorize.authorize(
                ctx,
                request,
                registry.policies,
                roles_in_force(ctx),
            );

            std.debug.assert(granted.allows());
            std.debug.assert(!(granted.read_only and request.kind == .write));

            return granted;
        }

        /// The build's roles, with what installed plugins declare merged in.
        fn roles_in_force(ctx: *const Ctx) []const role.Role {
            std.debug.assert(registry.roles.len > 0);

            const sandboxed = ctx.sandboxed_plugins orelse return registry.roles;
            const merged = sandboxed.roles() orelse return registry.roles;

            std.debug.assert(merged.len >= registry.roles.len);

            return merged;
        }

        /// Runs the pre hooks every native plugin holds, before authorization.
        pub fn run_pre_hooks(ctx: *Ctx, name: []const u8) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.parent != null);

            inline for (registry.middleware) |Middleware| {
                if (Middleware.stage == .pre) {
                    try invoke_hook(ctx, Middleware, .{name});
                }
            }
        }

        /// Calls an operation by name with JSON in and out: a built-in one, or one a
        /// installed plugin brings. What a sandboxed plugin's `publr_call` reaches.
        pub fn call_json(ctx: *Ctx, name: []const u8, input: []const u8) Error![]const u8 {
            return @import("sdk/call_json.zig").call(@This(), ctx, name, input);
        }

        /// Whether the caller may call `Operation` at all, whatever the input: what a page
        /// asks before it offers the action, never instead of the call's own check.
        pub fn may(ctx: *const Ctx, comptime Operation: type) bool {
            comptime std.debug.assert(find(Operation.name) == Operation);
            std.debug.assert(ctx.now_ms >= 0);

            const request: authorize.Request = .{
                .operation_name = Operation.name,
                .kind = Operation.kind,
                .resource = .{},
                .open = @hasDecl(Operation, "open") and Operation.open,
            };
            const granted = authorize.authorize(ctx, request, registry.policies, registry.roles);

            return if (granted) |_| true else |_| false;
        }

        /// Whether the caller may use the admin: its roles grant some operation of the
        /// admin's, neither an app's (`app.*`) nor one open to everyone. What an anonymous
        /// visitor may read (live public records) does not count: an account whose roles
        /// grant only what apps call never gets in.
        pub fn reaches_admin(ctx: *const Ctx) bool {
            std.debug.assert(ctx.now_ms >= 0);
            comptime std.debug.assert(registry.operations.len > 0);

            if (ctx.caller == .anonymous) {
                return false;
            }

            inline for (registry.operations) |Operation| {
                const app_only = comptime operation.is_app(Operation.name);
                const open = @hasDecl(Operation, "open") and Operation.open;

                if (!app_only and !open and !authorize.is_open_operation(Operation.name)) {
                    if (granted_by_role(ctx, Operation.name)) {
                        return true;
                    }
                }
            }

            return false;
        }

        /// Whether a role the caller holds names the operation: what the admin's door asks,
        /// never the whole policy (which also lets anyone read live public records).
        fn granted_by_role(ctx: *const Ctx, name: []const u8) bool {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.caller != .anonymous);

            const held = ctx.caller.roles() orelse return may_any(ctx);

            return role.permit(registry.roles, held, name);
        }

        /// A caller that is not an account (the system, a plugin, a machine token) may use
        /// the admin when the core policy lets it list the content types.
        fn may_any(ctx: *const Ctx) bool {
            std.debug.assert(ctx.caller != .user);
            std.debug.assert(ctx.now_ms >= 0);

            return switch (ctx.caller) {
                .system, .token => true,
                .anonymous, .user, .machine, .plugin => false,
            };
        }

        pub fn find(comptime name: []const u8) ?type {
            comptime std.debug.assert(name.len > 0);
            comptime std.debug.assert(name.len <= operation.name_len_max);

            inline for (registry.operations) |Operation| {
                if (comptime std.mem.eql(u8, Operation.name, name)) {
                    return Operation;
                }
            }

            return null;
        }

        fn run(
            ctx: *Ctx,
            comptime Operation: type,
            in: Operation.In,
            granted: *const Grant,
        ) Error!Operation.Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.parent != null);

            var input = in;

            inline for (registry.middleware) |Middleware| {
                const applies = comptime middleware.applies(Middleware, Operation);

                if (applies and Middleware.stage == .before) {
                    try invoke_hook(ctx, Middleware, .{&input});
                }
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                if (sandboxed.hooked(.before, Operation.name)) {
                    input = try runtime_before(ctx, sandboxed, Operation, input);
                }
            }

            const out = try execute(ctx, Operation, input, granted);

            inline for (registry.middleware) |Middleware| {
                const applies = comptime middleware.applies(Middleware, Operation);

                if (applies and Middleware.stage == .after) {
                    try invoke_hook(ctx, Middleware, .{ &input, &out });
                }
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                if (sandboxed.hooked(.after, Operation.name)) {
                    try runtime_after(ctx, sandboxed, Operation, input, out);
                }
            }

            return out;
        }

        fn execute(
            ctx: *Ctx,
            comptime Operation: type,
            in: Operation.In,
            granted: *const Grant,
        ) Error!Operation.Out {
            if (Operation.kind == .read) {
                return invoke_run(ctx, Operation, in, granted);
            }

            const previous_failure = ctx.dependency_failure;
            ctx.dependency_failure = false;
            defer ctx.dependency_failure = previous_failure;
            var transaction = try ctx.db.transaction();
            errdefer transaction.rollback();

            std.debug.assert(ctx.db.transaction_depth >= 1);

            const out = try invoke_run(ctx, Operation, in, granted);

            if (ctx.dependency_failure) {
                return error.InvalidationFailed;
            }

            try transaction.commit();
            std.debug.assert(ctx.db.transaction_depth == transaction.depth - 1);

            return out;
        }

        fn invoke_run(
            ctx: *Ctx,
            comptime Operation: type,
            in: Operation.In,
            granted: *const Grant,
        ) Error!Operation.Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.parent != null);

            if (comptime plugin_context.takes_plugin_ctx(Operation.run)) {
                var wrapped: PluginCtx = .{ .inner = ctx };

                return Operation.run(&wrapped, in, granted) catch |err| as_outcome(err);
            }

            return Operation.run(ctx, in, granted) catch |err| as_outcome(err);
        }

        /// The one place storage errors become outcomes: a broken constraint (a duplicate
        /// key, a missing parent) is a conflict to the caller. Everything else passes as is.
        fn as_outcome(err: Error) Error {
            std.debug.assert(@errorName(err).len > 0);

            const outcome: Error = switch (err) {
                error.Constraint => error.Conflict,
                else => err,
            };

            std.debug.assert(outcome != error.Constraint);

            return outcome;
        }

        fn invoke_hook(ctx: *Ctx, comptime Middleware: type, args: anytype) Error!void {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(args.len <= 2);

            if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                var wrapped: PluginCtx = .{ .inner = ctx };

                return @call(.auto, Middleware.run, .{&wrapped} ++ args);
            }

            return @call(.auto, Middleware.run, .{ctx} ++ args);
        }

        /// An installed plugin's `before` hook sees the input as JSON and may hand back another.
        fn runtime_before(
            ctx: *Ctx,
            sandboxed: *const sandboxed_plugins.SandboxedPlugins,
            comptime Operation: type,
            in: Operation.In,
        ) Error!Operation.In {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(Operation.name.len > 0);

            const input = try stringify(ctx.arena, in);
            const changed = try sandboxed.before(ctx, Operation.name, input);

            return json_module.parse(Operation.In, ctx.arena, changed, .{
                .allocate = .alloc_always,
            }) catch error.Invalid;
        }

        fn runtime_after(
            ctx: *Ctx,
            sandboxed: *const sandboxed_plugins.SandboxedPlugins,
            comptime Operation: type,
            in: Operation.In,
            out: Operation.Out,
        ) Error!void {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(Operation.name.len > 0);

            const input = try stringify(ctx.arena, in);
            const output = try stringify(ctx.arena, out);

            try sandboxed.after(ctx, Operation.name, input, output);
        }

        pub fn emit_notice(ctx: *Ctx, notice: Event.Notice) void {
            std.debug.assert(notice.name.len > 0);
            std.debug.assert(notice.operation_id != 0);
            emit(ctx, .{ .notice = notice });
        }

        pub fn emit(ctx: *Ctx, event: Event) void {
            std.debug.assert(ctx.next_operation_id > 1);
            std.debug.assert(registry.middleware.len <= middleware.middleware_max);

            if (ctx.sandboxed_plugins) |sandboxed| {
                sandboxed.event(ctx, event);
            }

            inline for (registry.middleware) |Middleware| {
                if (Middleware.stage == .on) {
                    if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                        var wrapped: PluginCtx = .{ .inner = ctx };
                        Middleware.run(&wrapped, event);
                    } else {
                        Middleware.run(ctx, event);
                    }
                }
            }
        }
    };
}

const json_module = @import("lib/json.zig");

pub fn stringify(arena: std.mem.Allocator, value: anytype) Error![]const u8 {
    const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch return error.OutOfMemory;

    std.debug.assert(text.len > 0);

    return text;
}

fn validate_registry(comptime registry: Registry) void {
    comptime {
        @setEvalBranchQuota(100_000);

        if (registry.operations.len > operations_max) {
            @compileError("too many operations");
        }

        const too_many_middlewares = registry.middleware.len > middleware.middleware_max;

        if (too_many_middlewares) {
            @compileError("too many middlewares");
        }

        if (registry.policies.len > authorize.policies_max) {
            @compileError("too many policies");
        }

        if (role.problem(registry.roles)) |message| {
            @compileError("roles: " ++ message);
        }

        for (registry.namespaces) |namespace| {
            const documented = namespace.name.len > 0 and namespace.summary.len > 0 and
                namespace.details.len > 0;

            if (!documented) {
                @compileError("namespace docs incomplete: " ++ namespace.name);
            }
        }

        for (registry.operations, 0..) |Operation, index| {
            operation.validate(Operation);

            const namespace_name = operation.namespace(Operation.name);

            if (registry.namespaces.len > 0 and !has_namespace(registry, namespace_name)) {
                @compileError("operation without a documented namespace: " ++ Operation.name);
            }
            for (registry.operations[index + 1 ..]) |Other| {
                if (std.mem.eql(u8, Operation.name, Other.name)) {
                    @compileError("duplicate operation: " ++ Operation.name);
                }
            }
        }

        for (registry.middleware) |Middleware| {
            middleware.validate(Middleware);
            const targets_operation = Middleware.stage == .before or Middleware.stage == .after;
            if (targets_operation and find_name(registry, Middleware.operation) == null) {
                @compileError("middleware targets unknown operation: " ++ Middleware.operation);
            }
        }
    }
}

fn has_namespace(comptime registry: Registry, comptime name: []const u8) bool {
    if (name.len == 0) {
        @compileError("empty namespace");
    }

    if (registry.namespaces.len == 0) {
        @compileError("registry has no namespaces");
    }

    for (registry.namespaces) |namespace| {
        if (std.mem.eql(u8, namespace.name, name)) {
            return true;
        }
    }

    return false;
}

fn find_name(comptime registry: Registry, comptime name: []const u8) ?type {
    if (name.len == 0) {
        @compileError("empty operation name");
    }

    if (registry.operations.len == 0) {
        @compileError("registry has no operations");
    }

    for (registry.operations) |Operation| {
        if (std.mem.eql(u8, Operation.name, name)) {
            return Operation;
        }
    }

    return null;
}

pub const testing = struct {
    const cli = @import("adapters/cli.zig");
    const auth_params_test = @import("lib/auth.zig").password.params_test;

    pub const harness_arena_bytes: u32 = 4 << 20;

    pub const Harness = struct {
        fixture: db.testing.Fixture,
        buffer: []u8,
        fixed: std.heap.FixedBufferAllocator,
        auth: AuthState,

        pub fn init(harness: *Harness) !void {
            std.debug.assert(harness_arena_bytes > 0);
            std.debug.assert(auth_params_test.p == 1);

            try harness.fixture.init();
            errdefer harness.fixture.deinit();

            harness.buffer = try std.testing.allocator.alloc(u8, harness_arena_bytes);
            errdefer std.testing.allocator.free(harness.buffer);

            const params: AuthState.Options = .{ .params = auth_params_test };
            try harness.auth.init(std.testing.allocator, std.testing.io, params);
            harness.fixed = std.heap.FixedBufferAllocator.init(harness.buffer);
        }

        pub fn deinit(harness: *Harness) void {
            harness.auth.deinit();
            std.testing.allocator.free(harness.buffer);
            harness.fixture.deinit();
        }

        pub fn ctx(harness: *Harness, who: Caller) Ctx {
            std.debug.assert(harness.fixture.connection.transaction_depth == 0);
            std.debug.assert(harness.buffer.len == harness_arena_bytes);

            return Ctx.init(.{
                .caller = who,
                .db = &harness.fixture.connection,
                .io = std.testing.io,
                .arena = harness.fixed.allocator(),
                .auth = &harness.auth,
            });
        }
    };

    pub const Record = struct {
        pub const name = "hello.record";
        pub const description = "Test operation: insert a note";
        pub const kind: operation.Kind = .write;
        pub const In = struct { note: []const u8, fail_after_insert: bool = false };
        pub const Out = struct { rows: u32 };
        pub const example: In = .{ .note = "example" };
        pub const example_out: Out = .{ .rows = 1 };

        pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
            std.debug.assert(in.note.len > 0);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            try ctx.db.exec("CREATE TABLE IF NOT EXISTS notes (note TEXT NOT NULL)");

            var insert = try ctx.db.prepare("INSERT INTO notes (note) VALUES (?1)");
            defer insert.finalize();

            try insert.bind_text(1, in.note);
            try insert.exec();

            if (in.fail_after_insert) {
                return error.Invalid;
            }

            return .{ .rows = try count(ctx, "notes") };
        }
    };

    pub const Shout = struct {
        pub const stage: middleware.Stage = .before;
        pub const operation = "hello.record";

        pub fn run(ctx: *Ctx, in: *Record.In) Error!void {
            in.note = std.ascii.allocUpperString(ctx.arena, in.note) catch return error.OutOfMemory;
        }
    };

    pub const Gate = struct {
        pub const stage: middleware.Stage = .pre;

        pub fn run(ctx: *Ctx, operation_name: []const u8) Error!void {
            std.debug.assert(operation_name.len > 0);
            std.debug.assert(ctx.parent != null);

            if (ctx.request_id.len != 0 and std.mem.eql(u8, ctx.request_id, "blocked")) {
                return error.Vetoed;
            }
        }
    };

    pub const Journal = struct {
        pub const stage: middleware.Stage = .on;

        pub fn run(ctx: *Ctx, event: Event) void {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(event != .completed or event.completed.operation_id != 0);

            const ddl = "CREATE TABLE IF NOT EXISTS journal " ++
                "(operation TEXT NOT NULL, ok INTEGER NOT NULL)";

            ctx.db.exec(ddl) catch return;

            const insert_sql = "INSERT INTO journal (operation, ok) VALUES (?1, ?2)";
            var insert = ctx.db.prepare(insert_sql) catch return;
            defer insert.finalize();

            const operation_name = switch (event) {
                .completed => |event_info| event_info.operation_name,
                .rejected, .failed => |event_info| event_info.operation_name,
                .notice => |notice| notice.name,
            };
            const ok: i64 = if (event == .completed) 1 else 0;

            insert.bind_text(1, operation_name) catch return;
            insert.bind_int(2, ok) catch return;
            _ = insert.step() catch return;
        }
    };

    pub fn count(ctx: *Ctx, comptime table: []const u8) Error!u32 {
        comptime std.debug.assert(table.len > 0);

        var select = try ctx.db.prepare("SELECT count(*) FROM " ++ table);
        defer select.finalize();

        std.debug.assert(try select.step());

        return @intCast(select.read_int());
    }
};

const TestSDK = SDK(.{
    .operations = &.{testing.Record},
    .middleware = &.{ testing.Gate, testing.Shout, testing.Journal },
});

test "pre middleware runs before authorization and a denial is journaled as rejected" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var blocked = harness.ctx(.system);
    blocked.request_id = "blocked";
    const vetoed = TestSDK.dispatch(&blocked, testing.Record, .{ .note = "x" });
    try std.testing.expectError(error.Vetoed, vetoed);

    var anon = harness.ctx(.anonymous);
    const denied = TestSDK.dispatch(&anon, testing.Record, .{ .note = "x" });
    try std.testing.expectError(error.Denied, denied);

    var select = try anon.db.prepare("SELECT count(*) FROM journal WHERE ok = 0");
    defer select.finalize();
    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(i64, 2), select.read_int());
}

test "write operation: anonymous denied, system commits, before-middleware, events journaled" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var anon = harness.ctx(.anonymous);
    const denied = TestSDK.dispatch(&anon, testing.Record, .{ .note = "x" });
    try std.testing.expectError(error.Denied, denied);

    var admin = harness.ctx(.system);
    const out = try TestSDK.dispatch(&admin, testing.Record, .{ .note = "kept" });
    try std.testing.expectEqual(@as(u32, 1), out.rows);

    var select = try admin.db.prepare("SELECT note FROM notes");
    defer select.finalize();
    try std.testing.expect(try select.step());
    const Note = struct { note: []const u8 };
    const row = try select.read(Note, harness.fixed.allocator());
    try std.testing.expectEqualStrings("KEPT", row.note);

    try std.testing.expectEqual(@as(u32, 2), try testing.count(&admin, "journal"));
}

test "write operation failure rolls back and journals a failed event" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.system);
    _ = try TestSDK.dispatch(&admin, testing.Record, .{ .note = "kept" });

    const failed = TestSDK.dispatch(&admin, testing.Record, .{
        .note = "lost",
        .fail_after_insert = true,
    });
    try std.testing.expectError(error.Invalid, failed);
    try std.testing.expectEqual(@as(u32, 1), try testing.count(&admin, "notes"));
    try std.testing.expectEqual(@as(u32, 0), admin.db.transaction_depth);
    try std.testing.expectEqual(@as(?u64, null), admin.parent);

    var select = try admin.db.prepare("SELECT count(*) FROM journal WHERE ok = 0");
    defer select.finalize();
    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(i64, 1), select.read_int());
}

const Subscribe = struct {
    pub const name = "app.news.subscribe";
    pub const description = "Test operation an app calls";
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { ok: bool };
    pub const example: In = .{};
    pub const example_out: Out = .{ .ok = true };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        return .{ .ok = true };
    }
};

/// A read an app's pages render with, standing in for the real one.
const ListRecords = struct {
    pub const name = "record.list";
    pub const description = "Test operation: the read app pages make";
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { count: u32 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .count = 0 };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        return .{ .count = 0 };
    }
};

const RolesSDK = SDK(.{
    .operations = &.{ testing.Record, Subscribe, ListRecords },
    .roles = &(role.core ++ [_]role.Role{
        .{ .name = "subscriber", .label = "Subscriber", .grants = &.{"app.news.*"} },
    }),
});

test "roles: an account calls what its roles grant; one granted only apps never gets in" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var subscriber = harness.ctx(.{ .user = .{ .id = "u_1", .roles = &.{"subscriber"} } });
    var editor = harness.ctx(.{ .user = .{ .id = "u_2", .roles = &.{"editor"} } });
    var both = harness.ctx(.{ .user = .{ .id = "u_3", .roles = &.{ "subscriber", "admin" } } });
    var ghost = harness.ctx(.{ .user = .{ .id = "u_4", .roles = &.{"unknown"} } });

    try std.testing.expect((try RolesSDK.dispatch(&subscriber, Subscribe, .{})).ok);
    try std.testing.expectError(error.Denied, RolesSDK.dispatch(&subscriber, testing.Record, .{
        .note = "x",
    }));
    try std.testing.expectError(error.Denied, RolesSDK.dispatch(&editor, Subscribe, .{}));
    try std.testing.expect(RolesSDK.may(&both, Subscribe));
    try std.testing.expect(RolesSDK.may(&both, testing.Record));
    try std.testing.expect(!RolesSDK.may(&ghost, Subscribe));

    // Reading live public records, as any visitor may, is not the admin.
    try std.testing.expect(RolesSDK.may(&subscriber, ListRecords));
    try std.testing.expect(!RolesSDK.reaches_admin(&subscriber));
    try std.testing.expect(!RolesSDK.reaches_admin(&ghost));
    try std.testing.expect(RolesSDK.reaches_admin(&both));

    var anonymous = harness.ctx(.anonymous);
    try std.testing.expect(!RolesSDK.reaches_admin(&anonymous));
}

test {
    std.testing.refAllDecls(@This());
}
