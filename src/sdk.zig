const std = @import("std");
const limits_module = @import("sdk/limits.zig");
const model_operation_override = @import("model/operation_override.zig");
const error_events = @import("sdk/error_events.zig");
const store_settings = @import("store/settings.zig");
/// Rate limits: the general one and an operation's own `.limit`.
pub const limits = limits_module;
const plugin_operations = @import("sdk/plugin/operation_define.zig");
const builtin = @import("builtin");
const contract = @import("model/contract.zig");
pub const trail = @import("sdk/trail.zig");
pub const db = @import("lib/db.zig");

pub const caller = @import("sdk/caller.zig");
pub const context = @import("sdk/context.zig");
pub const operation = @import("sdk/operation.zig");
pub const grant = @import("sdk/grant.zig");
pub const authorize = @import("sdk/authorize.zig");
pub const stored_roles = @import("sdk/roles.zig");
pub const middleware = @import("sdk/middleware.zig");
pub const mods = @import("sdk/mods.zig");
pub const delivery = @import("sdk/delivery.zig");
pub const provider = @import("sdk/provider.zig");
pub const sandboxed_plugins = @import("sdk/sandboxed_plugins.zig");
pub const plugin_access = @import("sdk/plugin_access.zig");
pub const call_json = @import("sdk/call_json.zig");
pub const help = @import("sdk/help.zig");
pub const changed_units = @import("sdk/changed_units.zig");
pub const scratch = @import("sdk/scratch.zig");
pub const definition_cache = @import("sdk/definition_cache.zig");

pub const Caller = caller.Caller;
pub const Ctx = context.Ctx;
pub const Error = operation.Error;
pub const Grant = grant.Grant;
pub const Policy = authorize.Policy;
pub const Event = middleware.Event;
/// An app loaded from the folder, as the server started or the folder changed: core's own
/// event, emitted outside any operation.
pub const AppsLoaded = @import("sdk/plugin/hook_define.zig").event(.{
    .name = "apps.loaded",
    .payload = struct {
        /// The app's name
        app: []const u8,
    },
});
pub const Scratch = scratch.Scratch;
pub const DefinitionCache = definition_cache.DefinitionCache;

pub const operations_max: u32 = 1024;
pub const in_bytes_max: u32 = @import("model/limits.zig").input_bytes_max;

const AuthState = @import("lib/auth.zig").State;
const role = @import("model/role.zig");
const plugin_context = @import("sdk/plugin/context.zig");
const PluginCtx = plugin_context.PluginCtx;

/// A content type a compiled-in plugin declares, and that plugin.
pub const TypeOwner = struct {
    handle: []const u8,
    owner: []const u8,
};

/// What a compiled-in plugin holds: everything its `.permissions` ask for, as asked.
pub const PluginGrants = struct {
    name: []const u8,
    access: plugin_access.Access,
};

pub const Registry = struct {
    operations: []const type,
    namespaces: []const operation.Namespace = &.{},
    policies: []const Policy = &.{},
    middleware: []const type = &.{},
    /// The plugin each operation and middleware belongs to, by position; empty for the
    /// core's. Left empty, nothing belongs to a plugin.
    operation_owners: []const []const u8 = &.{},
    middleware_owners: []const []const u8 = &.{},
    /// The jobs compiled-in plugins declare (`publr.job.define`), and the plugin of each.
    jobs: []const type = &.{},
    job_owners: []const []const u8 = &.{},
    /// The content types compiled-in plugins declare: a plugin's code reaches its own types
    /// whoever it runs for, as an installed plugin's does.
    type_owners: []const TypeOwner = &.{},
    /// Each compiled-in plugin's grants: its code's calls are held to them whoever it runs
    /// for. Null holds nothing to them.
    plugin_grants: ?[]const PluginGrants = null,
    schemas: []const [:0]const u8 = &.{},
    /// The chain a database is migrated along: core's, then each compiled-in plugin's.
    migrations: []const db.migration.Migration = &.{},
    /// Runs as the system once the schema is applied: declared content types and the like.
    bootstrap: ?*const fn (*Ctx) Error!void = null,
    /// Where top-level calls are logged, done or refused; none keeps no log.
    log: ?trail.Log = null,
    /// What a device's removal becomes instead of running (it never destroys): an item on
    /// its removal list for its person, answered as a failure that says where. Without it,
    /// the removal is refused.
    removal: ?*const fn (ctx: *Ctx, operation: []const u8, input: []const u8) Error = null,
};

pub const schemas_max: u32 = 64;

pub fn SDK(comptime registry: Registry) type {
    comptime validate_registry(registry);

    return struct {
        pub const operations = registry.operations;
        pub const namespaces = registry.namespaces;
        pub const schemas = registry.schemas;
        pub const migrations = registry.migrations;

        pub fn apply_schemas(connection: *db.Db) db.Error!void {
            std.debug.assert(connection.transaction_depth <= 1);
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
            const notify = ctx.notify;
            var trail_state: trail.Trail = .{
                .root = operation_id,
                .arena = ctx.arena,
            };
            const opened = trail_open(ctx, &trail_state);

            ctx.publishes = ctx.publishes and parent != null;
            ctx.parent = operation_id;
            ctx.notify = &emit_event;
            defer ctx.parent = parent;
            defer ctx.notify = notify;
            defer trail_close(ctx, opened);

            const granted = admit_counted(ctx, Operation, in, parent == null) catch |err| {
                emit(ctx, .{
                    .failed = .{
                        .operation_name = Operation.name,
                        .operation_id = operation_id,
                    },
                });
                const secret = comptime trail.secret_of(Operation);

                log_failure(ctx, Operation.name, input_text(ctx, in), secret, err);

                if (parent == null) {
                    flush_kept(ctx);
                }

                return err;
            };

            const within = ctx.within;
            const running = ctx.plugin;
            const owners = registry.operation_owners;
            const owner = comptime owner_of(registry.operations, owners, Operation);

            ctx.within = Operation.name;
            defer ctx.within = within;

            if (owner.len > 0) {
                ctx.plugin = owner;
            }

            defer ctx.plugin = running;

            const was_code = ctx.plugin_code;
            const was_called = ctx.plugin_called;

            ctx.plugin_called = was_code;
            ctx.plugin_code = owner.len > 0;
            defer ctx.plugin_code = was_code;
            defer ctx.plugin_called = was_called;

            const result = run(ctx, Operation, in, &granted);

            if (result) |_| {
                emit(ctx, .{
                    .completed = .{
                        .operation_name = Operation.name,
                        .operation_id = operation_id,
                    },
                });
                log_lines(ctx, Operation.name);
            } else |err| {
                emit(ctx, .{
                    .failed = .{
                        .operation_name = Operation.name,
                        .operation_id = operation_id,
                    },
                });
                const secret = comptime trail.secret_of(Operation);

                log_failure(ctx, Operation.name, input_text(ctx, in), secret, err);
            }

            if (parent == null) {
                flush_kept(ctx);
            }

            return result;
        }

        /// A top-level call carries a trail while the registry keeps a log; inner calls add
        /// to it. Answers whether this call opened it.
        pub fn trail_open(ctx: *Ctx, state: *trail.Trail) bool {
            std.debug.assert(state.root != 0);

            if (registry.log == null or ctx.trail != null) {
                return false;
            }

            ctx.trail = state;
            state.lines = .{
                .root = state.root,
                .arena = state.arena,
            };

            if (ctx.lines == null) {
                ctx.lines = &state.lines.?;
            }

            return true;
        }

        pub fn trail_close(ctx: *Ctx, opened: bool) void {
            std.debug.assert(!opened or ctx.trail != null);

            if (opened) {
                if (ctx.lines == &ctx.trail.?.lines.?) {
                    ctx.lines = null;
                }

                ctx.trail = null;
            }
        }

        /// The lines of the top-level call running now when it gathered them itself.
        fn own_lines(ctx: *Ctx) ?*trail.Lines {
            std.debug.assert(ctx.parent != null);

            const lines = ctx.lines orelse return null;

            if (!at_top(ctx) or lines.root != ctx.trail.?.root) {
                return null;
            }

            return lines;
        }

        /// A top-level call answered: what plugins logged in it, when no entry took it (a
        /// read; a write's lines went with its activity entry).
        pub fn log_lines(ctx: *Ctx, name: []const u8) void {
            std.debug.assert(name.len > 0);

            const log = registry.log orelse return;
            const lines = own_lines(ctx) orelse return;

            if (lines.stored or lines.items.items.len == 0) {
                return;
            }

            lines.stored = true;
            raise_failed(ctx, log.lines(ctx, name, lines.kept()));
        }

        /// Whether the call running now is the top-level one its trail was opened for.
        fn at_top(ctx: *Ctx) bool {
            std.debug.assert(ctx.parent != null);

            const open = ctx.trail orelse return false;

            return open.root == ctx.parent.?;
        }

        /// The input as JSON for the log; empty when it cannot be written.
        fn input_text(ctx: *Ctx, in: anytype) []const u8 {
            std.debug.assert(ctx.now_ms >= 0);

            if (registry.log == null) {
                return "";
            }

            return std.json.Stringify.valueAlloc(ctx.arena, in, .{}) catch "";
        }

        /// A top-level write about to commit: its activity entry, in its transaction.
        pub fn log_activity(
            ctx: *Ctx,
            name: []const u8,
            input: []const u8,
            secret: []const []const u8,
        ) Error!void {
            std.debug.assert(name.len > 0);

            const log = registry.log orelse return;

            if (!at_top(ctx)) {
                return;
            }

            var entry = ctx.trail.?.entry(name, input, secret);

            if (own_lines(ctx)) |lines| {
                entry.lines = lines.kept();
                lines.stored = true;
            }

            raise_failed(ctx, try log.activity(ctx, &entry));
        }

        /// A top-level call refused or failed, after its rollback: its error entry.
        pub fn log_failure(
            ctx: *Ctx,
            name: []const u8,
            input: []const u8,
            secret: []const []const u8,
            err: anyerror,
        ) void {
            std.debug.assert(name.len > 0);

            const log = registry.log orelse return;

            if (!at_top(ctx)) {
                return;
            }

            var entry = ctx.trail.?.entry(name, input, secret);
            const own = if (err == error.Failed) ctx.failure else null;

            entry.error_name = @errorName(err);

            if (own_lines(ctx)) |lines| {
                entry.lines = lines.kept();
                lines.stored = true;
            }

            if (entry.failed_in.len == 0) {
                entry.message = if (own) |failure| failure.message else "";
            }

            raise_failed(ctx, log.failure(ctx, &entry));
        }

        /// An Error log entry just written: `publr.errors.Failed` for it when it is an error,
        /// not a refusal, kept outside the write like the entry.
        pub fn raise_failed(ctx: *Ctx, logged: ?trail.Logged) void {
            std.debug.assert(ctx.now_ms >= 0);

            const entry = logged orelse return;

            std.debug.assert(entry.entry > 0);

            if (!error_events.raises(entry.error_name, entry.what)) {
                return;
            }

            ctx.keep(error_events.Failed, entry);

            if (ctx.db.transaction_depth == 0) {
                flush_kept(ctx);
            }
        }

        /// The events kept outside the write (`ctx.keep`) queued for the `on` hooks that hear
        /// them, once no write is open: what a rollback would have dropped.
        pub fn flush_kept(ctx: *Ctx) void {
            std.debug.assert(ctx.now_ms >= 0);

            const list = ctx.kept_events orelse return;

            if (ctx.db.transaction_depth > 0) {
                return;
            }

            ctx.kept_events = null;

            for (list.items) |emitted| {
                if (events.heard_outside(ctx, emitted.name)) {
                    events.queue(ctx, emitted);
                }
            }
        }

        /// What an operation made with `publr.operation.define` says of its callers.
        pub const Declared = struct {
            untrusted_callers: bool,
            answer: ?plugin_operations.Answer,
            open: bool,
        };

        /// The site's answer to who may call `name`; null when the code's stands.
        fn answer_override(ctx: *const Ctx, name: []const u8) Error!?plugin_operations.Answer {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            const override = model_operation_override;
            const key = try override.authorize_key(ctx.arena, name);
            const text = try store_settings.get(ctx.db, ctx.arena, key) orelse return null;

            return override.parse_answer(ctx.arena, text);
        }

        /// The site's limit on `name`, calls a minute per caller (`operation limit`); null
        /// when the code's stands.
        fn limit_override(ctx: *const Ctx, name: []const u8) Error!?u32 {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            const key = try model_operation_override.limit_key(ctx.arena, name);
            const text = try store_settings.get(ctx.db, ctx.arena, key) orelse return null;

            return std.fmt.parseInt(u32, text, 10) catch null;
        }

        /// A top-level call is counted against the rate limits first.
        fn admit_counted(
            ctx: *Ctx,
            comptime Operation: type,
            in: Operation.In,
            top: bool,
        ) Error!Grant {
            std.debug.assert(ctx.parent != null);
            comptime std.debug.assert(Operation.name.len > 0);

            if (top) {
                try check_limits(ctx, Operation.name, comptime limit_of(Operation));
            }

            return admit(ctx, Operation, in);
        }

        /// An operation's own `.limit`, calls a minute per caller; null for none.
        fn limit_of(comptime Operation: type) ?u32 {
            comptime {
                std.debug.assert(Operation.name.len > 0);

                if (!@hasDecl(Operation, "limit")) {
                    return null;
                }

                const declared = Operation.limit orelse return null;

                return declared.per_minute;
            }
        }

        /// The general limit, once a context, then the operation's own, for a caller from
        /// outside: their account, else their visitor id, else their address. A context no
        /// request made has none of them and is not counted. The operation's own limit (and
        /// the site's override of it) counts untrusted callers only: a site's page scripts,
        /// and anyone calling without credentials.
        pub fn check_limits(ctx: *Ctx, name: []const u8, per_minute: ?u32) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(per_minute == null or per_minute.? > 0);

            const table = ctx.limits orelse return;
            const anonymous = if (ctx.visitor.len > 0) ctx.visitor else ctx.address;
            const subject = ctx.caller.user_id() orelse anonymous;

            if (subject.len == 0) {
                return;
            }

            if (!ctx.counted) {
                ctx.counted = true;
                ctx.rate = table.take(subject, "", limits_module.general_per_minute, ctx.now_ms);

                if (!ctx.rate.?.allowed) {
                    return error.Throttled;
                }
            }

            const untrusted = ctx.app_plugins != null or !ctx.caller.is_authenticated();

            if (!untrusted) {
                return;
            }

            const own = try limit_override(ctx, name) orelse per_minute orelse return;
            const outcome = table.take(subject, name, own, ctx.now_ms);

            if (!outcome.allowed) {
                ctx.rate = outcome;
                return error.Throttled;
            }
        }

        fn admit(ctx: *Ctx, comptime Operation: type, in: Operation.In) Error!Grant {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(ctx.now_ms >= 0);

            const listed = registry.operations;
            const owner = comptime owner_of(listed, registry.operation_owners, Operation);

            try run_pre_hooks(ctx, Operation.name, Operation.kind);
            try check_fence(ctx, owner);

            if (comptime operation.destroys(Operation)) {
                if (ctx.caller == .token and !ctx.kept) {
                    const put_on_list = registry.removal orelse {
                        return ctx.fail(operation.needs_person);
                    };
                    const input = std.json.Stringify.valueAlloc(ctx.arena, in, .{}) catch {
                        return error.OutOfMemory;
                    };

                    return put_on_list(ctx, Operation.name, input);
                }
            }

            try admit_declared(ctx, Operation);

            return authorize_request(ctx, .{
                .operation_name = Operation.name,
                .kind = Operation.kind,
                .type_id = operation.type_of(in),
                .open = @hasDecl(Operation, "open") and Operation.open,
            });
        }

        /// What an operation made with `publr.operation.define` says of its callers: without
        /// `.untrusted_callers` nobody calls it without credentials, and a ready answer to
        /// `.authorize` is checked here, by the host, before anything runs.
        fn admit_declared(ctx: *const Ctx, comptime Operation: type) Error!void {
            std.debug.assert(ctx.now_ms >= 0);
            comptime std.debug.assert(Operation.name.len > 0);

            if (comptime !@hasDecl(Operation, "untrusted_callers")) {
                return;
            }

            return admit_answer(ctx, Operation.name, .{
                .untrusted_callers = Operation.untrusted_callers,
                .answer = Operation.answer,
                .open = Operation.open,
            });
        }

        /// The same for any operation, compiled in or installed. Through an app's address an
        /// operation with no `.authorize` is never reached: there, administrators are
        /// signed-in people like any other, and the default answer is theirs.
        pub fn admit_answer(ctx: *const Ctx, name: []const u8, declared: Declared) Error!void {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(declared.answer == null or declared.open);

            const through_app = ctx.app_plugins != null;

            if (!declared.untrusted_callers and !ctx.caller.is_authenticated()) {
                return error.Denied;
            }

            if (through_app and !declared.open) {
                return error.Denied;
            }

            // A site's answer stands in for the code's (`operation authorize`).
            const overridden = try answer_override(ctx, name);
            const ready = overridden orelse declared.answer orelse return;

            if (!plugin_operations.admits(ready, ctx.caller, through_app)) {
                return error.Denied;
            }
        }

        /// A call made for an app reaches only the plugins the app lists (`.plugins` in its
        /// `app.zon`): an operation of any other is denied before it runs. Core's own
        /// operations (no owner) are never fenced here; their grants say what they reach.
        pub fn check_fence(ctx: *Ctx, owner: []const u8) Error!void {
            std.debug.assert(owner.len <= 128);

            const plugins = ctx.app_plugins orelse return;

            if (owner.len == 0) {
                return;
            }

            for (plugins) |listed| {
                if (std.mem.eql(u8, listed, owner)) {
                    return;
                }
            }

            return error.Denied;
        }

        /// The core policy, every plugin's policy, and the roles, for one request.
        pub fn authorize_request(ctx: *Ctx, request: authorize.Request) Error!Grant {
            std.debug.assert(request.operation_name.len > 0);
            std.debug.assert(registry.policies.len <= authorize.policies_max);

            // What only reads (a modifier, a display or `before` hook) never writes, and never
            // reaches outside either.
            const outside = std.mem.startsWith(u8, request.operation_name, "http.");

            if (ctx.reads_only and (request.kind == .write or outside)) {
                return error.Denied;
            }

            var named = request;

            if (owns_type(ctx.plugin, request.type_id)) {
                named.own_types = try ctx.arena.dupe([]const u8, &.{request.type_id.?});
            }

            if (ctx.caller != .plugin and ctx.plugin_code) {
                named.plugin_access = compiled_access(ctx.plugin);
            }

            const granted = try authorize.authorize(
                ctx,
                named,
                registry.policies,
                try held_roles(ctx),
            );

            std.debug.assert(granted.allows());
            std.debug.assert(!(granted.read_only and request.kind == .write));

            return granted;
        }

        /// Every compiled-in plugin's grants.
        pub fn compiled_grants() []const PluginGrants {
            std.debug.assert(registry.operations.len > 0);

            const listed = registry.plugin_grants orelse return &.{};

            std.debug.assert(listed.len <= 1 << 10);

            return listed;
        }

        /// The grants of the compiled-in plugin whose code runs; null for none running.
        pub fn compiled_access(plugin: []const u8) ?*const plugin_access.Access {
            std.debug.assert(plugin.len <= 64);

            const listed = registry.plugin_grants orelse return null;

            if (plugin.len == 0) {
                return null;
            }

            for (listed) |*each| {
                if (std.mem.eql(u8, each.name, plugin)) {
                    return &each.access;
                }
            }

            return null;
        }

        /// Whether the compiled-in plugin whose code runs declares the type a call names.
        pub fn owns_type(plugin: []const u8, type_id: ?[]const u8) bool {
            std.debug.assert(plugin.len <= 64);
            std.debug.assert(registry.type_owners.len <= 64 * 64);

            const handle = type_id orelse return false;

            if (plugin.len == 0) {
                return false;
            }

            for (registry.type_owners) |declared| {
                if (std.mem.eql(u8, declared.handle, handle)) {
                    return std.mem.eql(u8, declared.owner, plugin);
                }
            }

            return false;
        }

        /// The build's roles, with what installed plugins declare merged in.
        /// The stored roles the caller holds, or the account an installed plugin acts for.
        pub fn held_roles(ctx: *const Ctx) Error![]const role.Role {
            std.debug.assert(ctx.now_ms >= 0);

            const names = ctx.caller.roles() orelse switch (ctx.caller) {
                .plugin => |plugin| plugin.roles orelse return &.{},
                .anonymous, .user, .token, .system => return &.{},
            };

            std.debug.assert(names.len <= role.user_roles_max);

            return stored_roles.held(ctx, names);
        }

        /// Runs the pre hooks every native plugin holds, before authorization: each sees the
        /// operation's name and whether it reads or writes.
        pub fn run_pre_hooks(ctx: *Ctx, name: []const u8, kind: operation.Kind) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.parent != null);

            inline for (registry.middleware) |Middleware| {
                if (Middleware.stage == .pre) {
                    try invoke_hook(ctx, Middleware, .{ name, kind });
                }
            }
        }

        /// Calls an operation by name with JSON in and out: a built-in one, or one a
        /// installed plugin brings. What a sandboxed plugin's `publr_call` reaches.
        pub fn call_json(ctx: *Ctx, name: []const u8, input: []const u8) Error![]const u8 {
            return @import("sdk/call_json.zig").call(@This(), ctx, name, input);
        }

        /// Calls another plugin's operation through what that plugin publishes: `Call`
        /// names the operation and gives its `In` and `Out` (the plugin's `interface.zig`),
        /// never its code. It goes by name, so it reaches the operation whether its plugin
        /// is compiled in or installed, through the same checks as any call.
        pub fn call(ctx: *Ctx, comptime Call: type, in: Call.In) Error!Call.Out {
            comptime std.debug.assert(Call.name.len > 0);

            const input = try stringify(ctx.arena, in);
            const output = try @import("sdk/call_json.zig").call(@This(), ctx, Call.name, input);

            return json_module.parse(Call.Out, ctx.arena, output, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch error.Invalid;
        }

        /// Whether the caller may call `Operation` at all, whatever the input: what a page
        /// asks before it offers the action, never instead of the call's own check.
        pub fn may(ctx: *const Ctx, comptime Operation: type) bool {
            comptime std.debug.assert(find(Operation.name) == Operation);
            std.debug.assert(ctx.now_ms >= 0);

            const request: authorize.Request = .{
                .operation_name = Operation.name,
                .kind = Operation.kind,
                .open = @hasDecl(Operation, "open") and Operation.open,
            };
            const held = held_roles(ctx) catch return false;
            const granted = authorize.authorize(ctx, request, registry.policies, held);

            return if (granted) |_| true else |_| false;
        }

        /// `may`, for an operation known only by its name: a built-in one, or one an
        /// installed plugin brings. An operation that does not exist is not allowed.
        pub fn may_named(ctx: *const Ctx, name: []const u8) bool {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            inline for (registry.operations) |Operation| {
                if (std.mem.eql(u8, Operation.name, name)) {
                    return may(ctx, Operation);
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return false;
            const found = sandboxed.find(name) orelse return false;
            const request: authorize.Request = .{
                .operation_name = found.name,
                .kind = found.kind,
                .open = found.open,
            };
            const held = held_roles(ctx) catch return false;
            const granted = authorize.authorize(ctx, request, registry.policies, held);

            return if (granted) |_| true else |_| false;
        }

        /// `may`, for the built-in operation `name` on a record of the type `handle`: a
        /// plugin reaches its own types whoever it runs for.
        pub fn may_on_type(ctx: *Ctx, name: []const u8, handle: []const u8) bool {
            std.debug.assert(name.len > 0);
            std.debug.assert(handle.len > 0);

            inline for (registry.operations) |Operation| {
                if (std.mem.eql(u8, Operation.name, name)) {
                    const asked_by_plugin = ctx.caller != .plugin and ctx.plugin_called;
                    const request: authorize.Request = .{
                        .operation_name = Operation.name,
                        .kind = Operation.kind,
                        .type_id = handle,
                        .plugin_access = if (asked_by_plugin) compiled_access(ctx.plugin) else null,
                    };

                    _ = authorize_request(ctx, request) catch return false;

                    return true;
                }
            }

            return false;
        }

        /// Whether the caller may use the admin: its roles grant some operation of the
        /// admin's, neither one apps call (`.untrusted_callers`) nor one open to everyone.
        /// What an anonymous visitor may read (live public records) does not count: an
        /// account whose roles grant only what apps call never gets in.
        pub fn reaches_admin(ctx: *const Ctx) bool {
            // Each operation's name is read once at comptime, a byte at a time.
            @setEvalBranchQuota(registry.operations.len * operation.name_len_max * 2);

            std.debug.assert(ctx.now_ms >= 0);
            comptime std.debug.assert(registry.operations.len > 0);

            if (ctx.caller == .anonymous) {
                return false;
            }

            inline for (registry.operations) |Operation| {
                const app_only = @hasDecl(Operation, "untrusted_callers") and
                    Operation.untrusted_callers;
                const open = @hasDecl(Operation, "open") and Operation.open;

                if (!app_only and !open) {
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

            return stored_roles.allows(ctx, held, name);
        }

        /// A caller that is not an account (the system, a plugin) may use
        /// the admin when it is the system; a device answers by its account's roles.
        fn may_any(ctx: *const Ctx) bool {
            std.debug.assert(ctx.caller != .user);
            std.debug.assert(ctx.now_ms >= 0);

            return switch (ctx.caller) {
                .system => true,
                .anonymous, .user, .token, .plugin => false,
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

            if (Operation.kind == .read) {
                return run_read(ctx, Operation, in, granted);
            }

            // A write may change a definition: what this request read of them is read again.
            ctx.forget_definitions();
            defer ctx.forget_definitions();

            // Hooks run inside the write's transaction, so a failing hook rolls back the
            // operation it hooks. A nested write is a savepoint: its failure undoes only
            // itself, and the caller decides what happens next.
            const previous_failure = ctx.dependency_failure;

            ctx.dependency_failure = false;
            defer ctx.dependency_failure = previous_failure;

            const previous_refusal = ctx.event_refusal;

            ctx.event_refusal = null;
            defer ctx.event_refusal = previous_refusal;

            var transaction = try ctx.db.transaction();
            errdefer transaction.rollback();

            const out = try run_pipeline(ctx, Operation, in, granted);

            if (ctx.event_refusal) |refused| {
                return refused;
            }

            try queue_answer(ctx, Operation.name, out);

            if (ctx.dependency_failure) {
                return error.InvalidationFailed;
            }

            try check_drafts(ctx);

            if (registry.log != null and at_top(ctx)) {
                const secret = comptime trail.secret_of(Operation);

                try log_activity(ctx, Operation.name, input_text(ctx, in), secret);
            }

            try transaction.commit();
            std.debug.assert(ctx.db.transaction_depth == transaction.depth - 1);

            // What a write does outside the database once it is kept (`committed`), when no
            // other write encloses it.
            if (comptime @hasDecl(Operation, "committed")) {
                if (ctx.db.transaction_depth == 0) {
                    try Operation.committed(ctx, in, out);
                }
            }

            return out;
        }

        /// A read: no write of its own, its event queued in the enclosing write, if any.
        fn run_read(
            ctx: *Ctx,
            comptime Operation: type,
            in: Operation.In,
            granted: *const Grant,
        ) Error!Operation.Out {
            comptime std.debug.assert(Operation.kind == .read);

            const previous_refusal = ctx.event_refusal;

            ctx.event_refusal = null;
            defer ctx.event_refusal = previous_refusal;

            const out = try run_pipeline(ctx, Operation, in, granted);

            if (ctx.event_refusal) |refused| {
                return refused;
            }

            try queue_answer(ctx, Operation.name, out);

            return out;
        }

        fn run_pipeline(
            ctx: *Ctx,
            comptime Operation: type,
            in: Operation.In,
            granted: *const Grant,
        ) Error!Operation.Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.parent != null);

            if (comptime operation.deprecation(Operation) != null) {
                note_deprecated(ctx, comptime operation.deprecation_text(Operation));
            }

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

            try resolve_references(ctx, Operation, &input);

            const started = ctx.trail_start;

            ctx.trail_start = if (ctx.trail) |open| open.mark() else 0;
            defer ctx.trail_start = started;

            const out = try invoke_run(ctx, Operation, input, granted);

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

        /// Every reference in the input read now, as the caller may see it: an operation
        /// gets the stored records, never what a caller says about them.
        fn resolve_references(
            ctx: *Ctx,
            comptime Operation: type,
            input: *Operation.In,
        ) Error!void {
            std.debug.assert(ctx.parent != null);

            inline for (std.meta.fields(Operation.In)) |field| {
                const Field = field.type;

                if (comptime is_reference(Field)) {
                    const id = @field(input, field.name).id;

                    @field(input, field.name).value = try load_reference(ctx, Field, id);
                } else if (comptime is_reference_list(Field)) {
                    const Item = std.meta.Elem(Field);
                    const list = @field(input, field.name);
                    const loaded = ctx.arena.alloc(Item, list.len) catch return error.OutOfMemory;

                    for (list, loaded) |item, *target| {
                        target.* = item;
                        target.value = try load_reference(ctx, Item, item.id);
                    }

                    @field(input, field.name) = loaded;
                }
            }
        }

        fn load_reference(
            ctx: *Ctx,
            comptime Reference: type,
            id: []const u8,
        ) Error!Reference.Document {
            const Get = comptime find_name(registry, "record.get") orelse
                @compileError("an operation taking a reference needs record.get");

            if (id.len == 0 or id.len > 128) {
                return error.Invalid;
            }

            const got = try dispatch(ctx, Get, .{
                .id = id,
            });

            if (!std.mem.eql(u8, got.record.type, Reference.handle)) {
                return error.NotFound;
            }

            return json_module.parse(Reference.Document, ctx.arena, got.document, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch error.Invalid;
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
                var wrapped: PluginCtx = .{
                    .inner = ctx,
                };

                return Operation.run(&wrapped, in, granted) catch |err| as_outcome(ctx.db, err);
            }

            return Operation.run(ctx, in, granted) catch |err| as_outcome(ctx.db, err);
        }

        /// The one place storage errors become outcomes: a taken key or a reference (a
        /// missing parent, a row still in use) is a conflict to the caller. A NOT NULL, a
        /// CHECK or a column's type broken is the code and the database disagreeing: a
        /// failure, logged with SQLite's words, never shown as a conflict.
        fn as_outcome(connection: *db.Db, err: Error) Error {
            std.debug.assert(@errorName(err).len > 0);

            const outcome: Error = switch (err) {
                error.Constraint => switch (connection.constraint_broken()) {
                    .unique, .reference => error.Conflict,
                    .none, .not_null, .check, .datatype, .other => broken(connection),
                },
                else => err,
            };

            std.debug.assert(outcome != error.Constraint);

            return outcome;
        }

        /// A caller used an operation on its way out: logged with who it was, so whoever
        /// runs the site finds the plugin, app or script to change before a major removes it.
        pub fn note_deprecated(ctx: *const Ctx, text: []const u8) void {
            std.debug.assert(text.len > 0);

            if (builtin.is_test) {
                return;
            }

            const plugin_word = if (ctx.plugin.len > 0) ", plugin " else "";

            std.log.warn("{s} (called by {s}{s}{s})", .{
                text,
                ctx.caller.label(),
                plugin_word,
                ctx.plugin,
            });
        }

        fn broken(connection: *db.Db) Error {
            const message = connection.message();

            std.debug.assert(message.len > 0);

            if (builtin.is_test) {
                std.log.debug("database refused a write: {s}", .{message});
            } else {
                std.log.err("database refused a write: {s}", .{message});
            }

            return error.Sqlite;
        }

        pub fn invoke_hook(ctx: *Ctx, comptime Middleware: type, args: anytype) Error!void {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(args.len <= 2);

            const running = ctx.plugin;
            const owners = registry.middleware_owners;
            const owner = comptime owner_of(registry.middleware, owners, Middleware);

            if (hook_off(ctx, owner, Middleware)) {
                return;
            }

            if (owner.len > 0) {
                ctx.plugin = owner;
            }

            defer ctx.plugin = running;

            const was_code = ctx.plugin_code;

            ctx.plugin_code = owner.len > 0;
            defer ctx.plugin_code = was_code;

            if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                var wrapped: PluginCtx = .{
                    .inner = ctx,
                };

                return @call(.auto, Middleware.run, .{&wrapped} ++ args);
            }

            return @call(.auto, Middleware.run, .{ctx} ++ args);
        }

        /// The `before` or `after` hooks on a sign-in event (`publr.auth.SignedIn`), inside
        /// the write that emits it (`hooks_on`). `before` hooks only read: they can refuse,
        /// never change anything. `spared` (an administrator signing in) is never refused: the
        /// refusal is logged and it goes on.
        pub fn event_hooks(
            ctx: *Ctx,
            comptime stage: middleware.Stage,
            comptime Emitted: type,
            payload: Emitted.Payload,
            spared: bool,
        ) Error!void {
            comptime std.debug.assert(stage == .before or stage == .after);
            std.debug.assert(ctx.parent != null);

            const reads_only = ctx.reads_only;

            ctx.reads_only = reads_only or stage == .before;
            defer ctx.reads_only = reads_only;

            const failure = ctx.failure;

            defer if (spared) {
                ctx.failure = failure;
            };

            const json = try stringify(ctx.arena, payload);

            return hooks_on(ctx, stage, Emitted.full_name, json, Emitted.refusable and !spared);
        }

        /// The `before` or `after` hooks on an event by name (a sign-in, a transition, a
        /// plugin's own), compiled in then installed, inside the write that emits it: each
        /// gets the payload read into its own type. A hook's error, trap or spent budget
        /// refuses the event when it is `refusable`; otherwise it is logged and the rest go on.
        pub fn hooks_on(
            ctx: *Ctx,
            comptime stage: middleware.Stage,
            name: []const u8,
            payload: []const u8,
            refusable: bool,
        ) Error!void {
            comptime std.debug.assert(stage == .before or stage == .after);
            std.debug.assert(name.len > 0);

            inline for (registry.middleware) |Middleware| {
                const listening = comptime Middleware.stage == stage and
                    @hasDecl(Middleware, "event") and @hasDecl(Middleware, "Payload");

                if (listening and std.mem.eql(u8, Middleware.event, name)) {
                    const ran = typed_hook(ctx, stage, Middleware, payload);

                    try settle_refusal(ran, refusable, name);
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return;
            const hook_stage: sandboxed_plugins.Stage = if (stage == .before) .before else .after;

            if (!sandboxed.hooked(hook_stage, name)) {
                return;
            }

            // A `before` hook may hand back the payload changed; an event's stays as emitted.
            const ran: Error!void = if (stage == .before)
                discard(sandboxed.before(ctx, name, payload))
            else
                sandboxed.after(ctx, name, payload, "{}");

            try settle_refusal(ran, refusable, name);
        }

        fn typed_hook(
            ctx: *Ctx,
            comptime stage: middleware.Stage,
            comptime Middleware: type,
            payload: []const u8,
        ) Error!void {
            var value = json_module.parse(Middleware.Payload, ctx.arena, payload, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return error.Invalid;

            if (stage == .before) {
                return invoke_hook(ctx, Middleware, .{&value});
            }

            return invoke_hook(ctx, Middleware, .{ &value, &nothing_of(Middleware) });
        }

        /// The empty answer an `after` hook on an event takes beside the payload.
        fn nothing_of(comptime Middleware: type) Nothing(Middleware) {
            return .{};
        }

        fn Nothing(comptime Middleware: type) type {
            const parameters = @typeInfo(@TypeOf(Middleware.run)).@"fn".params;

            return std.meta.Child(parameters[2].type.?);
        }

        fn discard(answer: Error![]const u8) Error!void {
            const changed = try answer;

            std.debug.assert(changed.len <= in_bytes_max);
        }

        fn settle_refusal(ran: Error!void, refusable: bool, name: []const u8) Error!void {
            std.debug.assert(name.len > 0);

            ran catch |err| {
                if (refusable or err == error.OutOfMemory) {
                    return err;
                }

                std.log.warn("a hook on {s} refused ({t}); it does not stop this one", .{
                    name,
                    err,
                });
            };
        }

        /// An installed plugin's `before` hook sees the input as JSON and may hand back another.
        pub fn runtime_before(
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

        pub fn runtime_after(
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

        /// Whether any modifier, compiled in or installed, takes values applied as `name`.
        pub fn modified(ctx: *Ctx, name: []const u8) bool {
            std.debug.assert(name.len > 0);
            std.debug.assert(name.len <= mods.name_len_max);

            inline for (registry.middleware) |Middleware| {
                if (comptime Middleware.stage == .modify) {
                    if (mods.matches(Middleware.pattern, name)) {
                        return true;
                    }
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return false;

            return sandboxed.hooked(.modify, name);
        }

        /// Runs every modifier whose name takes `name` over the batch, compiled-in plugins
        /// first in their order, then installed ones, each handed what the one before
        /// answered. Modifiers run as their plugins, reading what they are granted, never
        /// writing; one that fails changes nothing.
        pub fn modify(ctx: *Ctx, name: []const u8, batch: *mods.Batch) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(batch.items.len <= mods.items_max);

            if (!mods.valid(name, false)) {
                return error.Invalid;
            }

            var reading = ctx.*;
            reading.reads_only = true;

            inline for (registry.middleware) |Middleware| {
                if (comptime Middleware.stage == .modify) {
                    if (mods.matches(Middleware.pattern, name)) {
                        try modify_native(&reading, Middleware, batch);
                    }
                }
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                try modify_sandboxed(&reading, sandboxed, name, batch);
            }
        }

        fn modify_native(ctx: *Ctx, comptime Middleware: type, batch: *mods.Batch) Error!void {
            std.debug.assert(ctx.reads_only);
            std.debug.assert(Middleware.stage == .modify);

            const owners = registry.middleware_owners;
            const owner = comptime owner_of(registry.middleware, owners, Middleware);
            const before_modifier = ctx.arena.dupe(std.json.Value, batch.items) catch {
                return error.OutOfMemory;
            };

            ctx.plugin = owner;

            const was_code = ctx.plugin_code;

            ctx.plugin_code = true;
            defer ctx.plugin_code = was_code;

            var wrapped: PluginCtx = .{
                .inner = ctx,
            };

            Middleware.run(&wrapped, batch) catch |err| {
                const pattern = Middleware.pattern;

                std.log.warn("plugin {s}: modifier on {s}: {t}", .{ owner, pattern, err });
                @memcpy(batch.items, before_modifier);
            };
        }

        fn modify_sandboxed(
            ctx: *Ctx,
            sandboxed: *const sandboxed_plugins.SandboxedPlugins,
            name: []const u8,
            batch: *mods.Batch,
        ) Error!void {
            std.debug.assert(ctx.reads_only);
            std.debug.assert(name.len > 0);

            if (!sandboxed.hooked(.modify, name)) {
                return;
            }

            const input = try stringify(ctx.arena, batch.*);
            const answer = sandboxed.modify(ctx, name, input) catch |err| {
                std.log.warn("modifiers on {s}: {t}", .{ name, err });
                return;
            };
            const changed = json_module.parse(mods.Batch, ctx.arena, answer, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch return;

            _ = mods.take(batch, changed);
        }

        /// Every modifier, compiled in then installed: whose it is, the name it takes, why.
        pub fn modifiers(ctx: *Ctx) Error![]const mods.Modifier {
            std.debug.assert(ctx.now_ms >= 0);

            var out: std.ArrayList(mods.Modifier) = .empty;

            inline for (registry.middleware) |Middleware| {
                if (comptime Middleware.stage == .modify) {
                    const owners = registry.middleware_owners;

                    out.append(ctx.arena, .{
                        .plugin = comptime owner_of(registry.middleware, owners, Middleware),
                        .name = Middleware.pattern,
                        .reason = if (@hasDecl(Middleware, "reason")) Middleware.reason else "",
                    }) catch return error.OutOfMemory;
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return out.items;

            for (sandboxed.manifests()) |manifest| {
                for (manifest.hooks) |hook| {
                    if (hook.stage == .modify) {
                        out.append(ctx.arena, .{
                            .plugin = manifest.name,
                            .name = hook.target,
                            .reason = hook.reason,
                        }) catch return error.OutOfMemory;
                    }
                }
            }

            return out.items;
        }

        /// An event emitted outside any operation: what the server itself did (the apps
        /// loaded from the folder, `AppsLoaded`). `on` hooks hear it from the queue as any
        /// other.
        pub fn announce(ctx: *Ctx, comptime Emitted: type, payload: Emitted.Payload) void {
            comptime std.debug.assert(Emitted.full_name.len > 0);
            std.debug.assert(ctx.parent == null);

            const subject = stringify(ctx.arena, payload) catch |err| {
                std.log.warn("events: {s} not announced: {t}", .{ Emitted.full_name, err });
                return;
            };

            emit_event(ctx, .{
                .operation_id = ctx.allocate_operation_id(),
                .name = Emitted.full_name,
                .subject = subject,
            }, false);
        }

        /// An inner call's end or an event, kept on the top-level call's trail.
        fn follow(ctx: *Ctx, open: *trail.Trail, event: Event) void {
            std.debug.assert(open.root != 0);

            switch (event) {
                .completed => |done| if (done.operation_id != open.root) {
                    open.called(ctx, done.operation_name, false);
                },
                .failed => |failed| if (failed.operation_id != open.root) {
                    open.called(ctx, failed.operation_name, true);
                },
                .emitted => |emitted| open.emitted(.{
                    .name = emitted.name,
                    .subject = emitted.subject,
                }),
            }
        }

        /// An event a write raised, one or one of many (`events.hand_many`): kept on the
        /// trail.
        pub fn follow_event(ctx: *Ctx, emitted: Event.Emitted) void {
            std.debug.assert(emitted.name.len > 0);
            std.debug.assert(emitted.operation_id != 0);

            if (ctx.trail) |open| {
                follow(ctx, open, .{
                    .emitted = emitted,
                });
            }
        }

        /// An event emitted inside a call: kept on the trail, its `after` hooks run now when
        /// `after` (a refusal fails the write before it commits), then handed to the
        /// intrinsic listeners and queued for the `on` hooks (`events.zig`).
        pub fn emit_event(ctx: *Ctx, emitted: Event.Emitted, after: bool) void {
            std.debug.assert(emitted.name.len > 0);
            std.debug.assert(emitted.operation_id != 0);

            follow_event(ctx, emitted);

            if (after) {
                hooks_on(ctx, .after, emitted.name, emitted.subject, true) catch |err| {
                    ctx.event_refusal = ctx.event_refusal orelse err;
                };
            }

            events.hand(ctx, emitted);
        }

        /// A write about to commit for a `drafts` device: refused when it changed what
        /// visitors see, so the whole write rolls back and waits for a person.
        pub fn check_drafts(ctx: *Ctx) Error!void {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const scope = ctx.caller.scope() orelse return;

            if (scope == .drafts and ctx.publishes) {
                return ctx.fail(operation.drafts_only);
            }
        }

        /// An operation's end, kept on the trail and heard by core's intrinsic listeners (a
        /// deployment closing); an installed plugin's change reloads the plugins. An event goes
        /// on to its hooks (`emit_event`). No `on` hook hears an operation's end here: its own
        /// event is queued with its answer inside its write (`queue_answer`).
        pub fn emit(ctx: *Ctx, event: Event) void {
            std.debug.assert(ctx.next_operation_id > 1);
            std.debug.assert(registry.middleware.len <= middleware.middleware_max);

            std.debug.assert(event != .emitted);

            if (ctx.trail) |open| {
                follow(ctx, open, event);
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                sandboxed.event(ctx, event);
            }

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and events.intrinsic(Middleware);

                if (listens and hears(Middleware, event)) {
                    _ = run_listener(ctx, Middleware, event);
                }
            }
        }

        /// An operation succeeded: its event, under its own name and carrying its answer, is
        /// queued inside its write for the `on` hooks that hear it, compiled in or installed.
        /// A nested call's goes into its parent's write; a rollback drops it.
        pub fn queue_answer(ctx: *Ctx, name: []const u8, out: anytype) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.parent != null);

            if (!events.heard_outside(ctx, name)) {
                return;
            }

            return queue_answer_json(ctx, name, try stringify(ctx.arena, out));
        }

        /// `queue_answer` for an installed operation's answer, JSON already.
        pub fn queue_answer_json(ctx: *Ctx, name: []const u8, out: []const u8) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.parent != null);

            if (!events.heard_outside(ctx, name)) {
                return;
            }

            events.queue(ctx, .{
                .operation_id = ctx.parent.?,
                .name = name,
                .subject = out,
            });
        }

        /// One `on` hook hearing a queued event: a typed one gets the payload read into its
        /// type (an operation's answer, an event's payload); a failure is logged in the run.
        /// Answers the hook's own words for why it failed; empty when it ran or never fails.
        pub fn run_listener(ctx: *Ctx, comptime Middleware: type, event: Event) []const u8 {
            comptime std.debug.assert(Middleware.stage == .on);
            std.debug.assert(ctx.now_ms >= 0);

            const running = ctx.plugin;
            const owners = registry.middleware_owners;
            const owner = comptime owner_of(registry.middleware, owners, Middleware);

            if (hook_off(ctx, owner, Middleware)) {
                return "";
            }

            if (owner.len > 0) {
                ctx.plugin = owner;
            }

            defer ctx.plugin = running;

            const was_code = ctx.plugin_code;

            ctx.plugin_code = owner.len > 0;
            defer ctx.plugin_code = was_code;

            if (comptime @hasDecl(Middleware, "Payload")) {
                std.debug.assert(event == .emitted);

                const text = event.emitted.subject;
                const payload = json_module.parse(Middleware.Payload, ctx.arena, text, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch {
                    return settle_listener(ctx, Middleware, event, @as(Error!void, error.Invalid));
                };

                if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                    var wrapped: PluginCtx = .{
                        .inner = ctx,
                    };
                    const ran = Middleware.run(&wrapped, payload);

                    return settle_listener(ctx, Middleware, event, ran);
                }

                return settle_listener(ctx, Middleware, event, Middleware.run(ctx, payload));
            }

            if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                var wrapped: PluginCtx = .{
                    .inner = ctx,
                };

                return settle_listener(ctx, Middleware, event, Middleware.run(&wrapped, event));
            }

            return settle_listener(ctx, Middleware, event, Middleware.run(ctx, event));
        }

        /// An `on` hook answers an error: an event is never refused; its words, or the error's
        /// name, say why, for the run kept as failed.
        fn settle_listener(
            ctx: *Ctx,
            comptime Middleware: type,
            event: Event,
            ran: anytype,
        ) []const u8 {
            comptime std.debug.assert(Middleware.stage == .on);

            if (comptime @typeInfo(@TypeOf(ran)) != .error_union) {
                return "";
            }

            ran catch |err| {
                const name = if (event == .emitted) event.emitted.name else "";
                const said = if (ctx.failure) |failure| failure.message else "";

                std.log.warn("a hook on {s} failed: {t}", .{ name, err });

                return if (said.len > 0) said else @errorName(err);
            };

            return "";
        }

        /// The events' way to the `on` hooks, and the intrinsic operation hooks a bulk
        /// write runs over many inputs at once.
        pub const events = @import("sdk/events.zig").Events(@This(), registry);
        pub const bulk = @import("sdk/bulk.zig").Bulk(@This(), registry);
        /// The queued jobs, run between requests.
        pub const jobs = @import("sdk/jobs.zig").Jobs(@This(), registry);
    };
}

const json_module = @import("lib/json.zig");

/// Whether an event hook sees this event: every one, or only the one it names (`event`),
/// by the operation's name or the event's, as an installed plugin's hook does.
pub fn hears(comptime Middleware: type, event: Event) bool {
    std.debug.assert(Middleware.stage == .on);

    if (!@hasDecl(Middleware, "event")) {
        return true;
    }

    comptime std.debug.assert(Middleware.event.len > 0);

    const name = switch (event) {
        .completed => |completed| completed.operation_name,
        .failed => |failed| failed.operation_name,
        .emitted => |emitted| emitted.name,
    };

    return std.mem.eql(u8, name, Middleware.event);
}

pub fn stringify(arena: std.mem.Allocator, value: anytype) Error![]const u8 {
    const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch return error.OutOfMemory;

    std.debug.assert(text.len > 0);

    return text;
}

/// The plugin `Item` belongs to, from a list and its owners by position; empty for the core's.
/// A compiled-in plugin's hook on one of its remotes that is off (its plugin is not there,
/// or it does not fit) does not run.
fn hook_off(ctx: *const Ctx, owner: []const u8, comptime Middleware: type) bool {
    const target = comptime if (@hasDecl(Middleware, "event"))
        Middleware.event
    else if (@hasDecl(Middleware, "operation"))
        Middleware.operation
    else
        "";

    std.debug.assert(ctx.now_ms >= 0);

    if (owner.len == 0 or target.len == 0) {
        return false;
    }

    const sandboxed = ctx.sandboxed_plugins orelse return false;

    return sandboxed.remote_off(owner, target);
}

fn owner_of(
    comptime items: []const type,
    comptime owners: []const []const u8,
    comptime Item: type,
) []const u8 {
    comptime {
        if (owners.len == 0) {
            return "";
        }

        for (items, owners) |candidate, owner| {
            if (candidate == Item) {
                return owner;
            }
        }

        return "";
    }
}

/// Branches the registry's own checks take (roles, namespaces, policies), whatever its size.
const validation_branches_base: u32 = 100_000;
/// Branches one operation's checks add at most: its shapes walked once, its name compared
/// with every other's.
const validation_branches_per_operation: u32 = 512;

fn validate_registry(comptime registry: Registry) void {
    comptime {
        @setEvalBranchQuota(validation_branches_base +
            registry.operations.len * validation_branches_per_operation +
            registry.operations.len * registry.operations.len);

        const owned_operations = registry.operation_owners.len;
        const owned_middleware = registry.middleware_owners.len;

        if (owned_operations > 0 and owned_operations != registry.operations.len) {
            @compileError("operation_owners names one owner per operation");
        }

        if (owned_middleware > 0 and owned_middleware != registry.middleware.len) {
            @compileError("middleware_owners names one owner per middleware");
        }

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
            // A hook on an event (`auth.signed_in`) is named for it, not for an operation.
            const targets_operation = (Middleware.stage == .before or
                Middleware.stage == .after) and !@hasDecl(Middleware, "event");
            const unknown = targets_operation and find_name(registry, Middleware.operation) == null;

            if (unknown and !absent_plugin(registry, Middleware.operation)) {
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

/// Whether operation `name` belongs to a plugin this build does not compile in: a hook on
/// it runs once that plugin is installed. Known only when the registry names its owners;
/// a core namespace or a compiled-in plugin's is never absent.
fn absent_plugin(comptime registry: Registry, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        if (registry.operation_owners.len == 0) {
            return false;
        }

        const target = plugin_of(name);

        for (registry.operations, registry.operation_owners) |Operation, owner| {
            const namespace = operation.namespace(Operation.name);
            const core = owner.len == 0 and std.mem.eql(u8, namespace, target);

            if (core or std.mem.eql(u8, owner, target)) {
                return false;
            }
        }

        return true;
    }
}

fn is_reference(comptime Type: type) bool {
    comptime {
        return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "reference");
    }
}

fn is_reference_list(comptime Type: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Type) != .void);

        const info = @typeInfo(Type);
        const slice = info == .pointer and info.pointer.size == .slice;

        return slice and is_reference(info.pointer.child);
    }
}

/// The plugin an operation name belongs to: `inventory` for `inventory.adjust`.
pub fn plugin_of(comptime name: []const u8) []const u8 {
    comptime {
        std.debug.assert(std.mem.indexOfScalar(u8, name, '.') != null);

        const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;

        return name[0..dot];
    }
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
        /// One scratch beside the one arena, shared by every context made here, as a
        /// request's calls share theirs.
        scratch_buffer: []u8,
        scratch: scratch.Scratch,

        pub fn init(harness: *Harness) !void {
            std.debug.assert(harness_arena_bytes > 0);
            std.debug.assert(auth_params_test.p == 1);

            try harness.fixture.init();
            errdefer harness.fixture.deinit();

            harness.buffer = try std.testing.allocator.alloc(u8, harness_arena_bytes);
            errdefer std.testing.allocator.free(harness.buffer);

            harness.scratch_buffer = try std.testing.allocator.alloc(u8, scratch.bytes_default);
            errdefer std.testing.allocator.free(harness.scratch_buffer);

            harness.scratch = .{
                .fixed = .init(harness.scratch_buffer),
            };

            const params: AuthState.Options = .{
                .params = auth_params_test,
            };
            try harness.auth.init(std.testing.allocator, std.testing.io, params);
            harness.fixed = std.heap.FixedBufferAllocator.init(harness.buffer);

            var system = harness.ctx(.system);

            try stored_roles.apply(&system, role.owner_core, &role.core);
        }

        pub fn deinit(harness: *Harness) void {
            std.debug.assert(harness.scratch_buffer.len == scratch.bytes_default);

            harness.auth.deinit();
            std.testing.allocator.free(harness.scratch_buffer);
            std.testing.allocator.free(harness.buffer);
            harness.fixture.deinit();
        }

        pub fn ctx(harness: *Harness, who: Caller) Ctx {
            std.debug.assert(harness.fixture.connection.transaction_depth == 0);
            std.debug.assert(harness.buffer.len == harness_arena_bytes);

            var made = Ctx.init(
                &harness.fixture.connection,
                std.testing.io,
                harness.fixed.allocator(),
                &harness.auth,
                who,
                .{},
            );

            made.scratch_set_aside = &harness.scratch;

            return made;
        }
    };

    pub const Record = struct {
        pub const name = "hello.record";
        pub const description = "Test operation: insert a note";
        pub const kind: operation.Kind = .write;
        pub const In = struct {
            note: []const u8,
            fail_after_insert: bool = false,
        };
        pub const Out = struct {
            rows: u32,
        };
        pub const example: In = .{
            .note = "example",
        };
        pub const example_out: Out = .{
            .rows = 1,
        };

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

            return .{
                .rows = try count(ctx, "notes"),
            };
        }
    };

    pub const Shout = struct {
        pub const stage: middleware.Stage = .before;
        pub const operation = "hello.record";

        pub fn run(ctx: *Ctx, in: *Record.In) Error!void {
            in.note = std.ascii.allocUpperString(ctx.arena, in.note) catch return error.OutOfMemory;
        }
    };

    /// Whether `Gate` vetoes every call, for the test that needs it.
    pub var gate_closed: bool = false;

    pub const Gate = struct {
        pub const stage: middleware.Stage = .pre;

        pub fn run(ctx: *Ctx, operation_name: []const u8, kind: operation.Kind) Error!void {
            std.debug.assert(operation_name.len > 0);
            std.debug.assert(ctx.parent != null);

            _ = kind;

            if (gate_closed) {
                return error.Denied;
            }
        }
    };

    /// An `on` hook on `hello.record`: hears its answer from the queue, after the commit.
    pub const Journal = struct {
        pub const stage: middleware.Stage = .on;
        pub const event = "hello.record";
        pub const Payload = Record.Out;

        pub fn run(ctx: *Ctx, out: Payload) Error!void {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(ctx.parent == null);

            try ctx.db.exec("CREATE TABLE IF NOT EXISTS journal (rows INTEGER NOT NULL)");

            var insert = try ctx.db.prepare("INSERT INTO journal (rows) VALUES (?1)");
            defer insert.finalize();

            try insert.bind_int(1, out.rows);
            try insert.exec();
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

test "pre middleware runs before authorization; a refused call emits nothing" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var blocked = harness.ctx(.system);
    testing.gate_closed = true;
    const blocked_call = TestSDK.dispatch(&blocked, testing.Record, .{
        .note = "x",
    });
    testing.gate_closed = false;
    try std.testing.expectError(error.Denied, blocked_call);

    var anon = harness.ctx(.anonymous);
    const denied = TestSDK.dispatch(&anon, testing.Record, .{
        .note = "x",
    });
    try std.testing.expectError(error.Denied, denied);
    try std.testing.expectEqual(@as(u32, 0), try testing.count(&anon, "job_queue"));
}

test "an operation's on hook hears its answer from the queue, after the commit" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var anon = harness.ctx(.anonymous);
    const denied = TestSDK.dispatch(&anon, testing.Record, .{
        .note = "x",
    });
    try std.testing.expectError(error.Denied, denied);

    var admin = harness.ctx(.system);
    const out = try TestSDK.dispatch(&admin, testing.Record, .{
        .note = "kept",
    });
    try std.testing.expectEqual(@as(u32, 1), out.rows);

    var select = try admin.db.prepare("SELECT note FROM notes");
    defer select.finalize();
    try std.testing.expect(try select.step());
    const Note = struct {
        note: []const u8,
    };
    const row = try select.read(Note, harness.fixed.allocator());
    try std.testing.expectEqualStrings("KEPT", row.note);

    // Not inside the request: the hook has not run, its run waits with the answer.
    var journal = try admin.db.prepare(
        "SELECT count(*) FROM sqlite_master WHERE name = 'journal'",
    );
    defer journal.finalize();
    try std.testing.expect(try journal.step());
    try std.testing.expectEqual(@as(i64, 0), journal.read_int());

    var queued = try admin.db.prepare("SELECT plugin, name, input FROM job_queue");
    defer queued.finalize();
    try std.testing.expect(try queued.step());
    const Queued = struct {
        plugin: []const u8,
        name: []const u8,
        input: []const u8,
    };
    const waiting = try queued.read(Queued, harness.fixed.allocator());
    try std.testing.expectEqualStrings("core", waiting.plugin);
    try std.testing.expectEqualStrings("on:hello.record", waiting.name);
    try std.testing.expectEqualStrings("{\"rows\":1}", waiting.input);

    var worker = harness.ctx(.system);
    try std.testing.expectEqual(@as(u32, 1), try TestSDK.jobs.drain(&worker, 8));
    try std.testing.expectEqual(@as(u32, 1), try testing.count(&admin, "journal"));
    try std.testing.expectEqual(@as(u32, 0), try testing.count(&admin, "job_queue"));
}

test "a write that rolls back drops its event; a failure emits nothing" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var admin = harness.ctx(.system);
    _ = try TestSDK.dispatch(&admin, testing.Record, .{
        .note = "kept",
    });

    const failed = TestSDK.dispatch(&admin, testing.Record, .{
        .note = "lost",
        .fail_after_insert = true,
    });
    try std.testing.expectError(error.Invalid, failed);
    try std.testing.expectEqual(@as(u32, 1), try testing.count(&admin, "notes"));
    try std.testing.expectEqual(@as(u32, 0), admin.db.transaction_depth);
    try std.testing.expectEqual(@as(?u64, null), admin.parent);
    try std.testing.expectEqual(@as(u32, 1), try testing.count(&admin, "job_queue"));
}

test "an operation called through what its plugin publishes: by name, the same checks" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const Published = struct {
        pub const name = testing.Record.name;
        pub const In = struct {
            note: []const u8,
        };
        pub const Out = struct {
            rows: u32,
        };
    };
    const Missing = struct {
        pub const name = "nobody.nothing";
        pub const In = struct {};
        pub const Out = struct {};
    };

    var admin = harness.ctx(.system);
    const out = try TestSDK.call(&admin, Published, .{
        .note = "kept",
    });
    try std.testing.expectEqual(@as(u32, 1), out.rows);
    try std.testing.expectError(error.NotFound, TestSDK.call(&admin, Missing, .{}));

    var anon = harness.ctx(.anonymous);
    try std.testing.expectError(error.Denied, TestSDK.call(&anon, Published, .{
        .note = "x",
    }));
}

const Subscribe = struct {
    pub const name = "news.subscribe";
    pub const description = "Test operation an app calls";
    pub const kind: operation.Kind = .read;
    pub const untrusted_callers = true;
    pub const open = false;
    pub const answer: ?@import("model/caller_answer.zig").Answer = null;
    pub const In = struct {};
    pub const Out = struct {
        ok: bool,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .ok = true,
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        return .{
            .ok = true,
        };
    }
};

/// A read an app's pages render with, standing in for the real one.
const ListRecords = struct {
    pub const name = "record.list";
    pub const description = "Test operation: the read app pages make";
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        count: u32,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .count = 0,
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        return .{
            .count = 0,
        };
    }
};

const RolesSDK = SDK(.{
    .operations = &.{ testing.Record, Subscribe, ListRecords },
});

test "roles: an account calls what its roles grant; one granted only apps never gets in" {
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    try stored_roles.apply(&system, "news", &.{.{
        .name = "subscriber",
        .label = "Subscriber",
        .grants = &.{"app.news.*"},
    }});

    var subscriber = harness.ctx(.{
        .user = .{
            .id = "u_1",
            .roles = &.{"subscriber"},
        },
    });
    var editor = harness.ctx(.{
        .user = .{
            .id = "u_2",
            .roles = &.{"editor"},
        },
    });
    var both = harness.ctx(.{
        .user = .{
            .id = "u_3",
            .roles = &.{ "subscriber", "admin" },
        },
    });
    var ghost = harness.ctx(.{
        .user = .{
            .id = "u_4",
            .roles = &.{"unknown"},
        },
    });

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
    _ = @import("sdk/jobs.zig");
    _ = @import("sdk/hook_runs.zig");
    _ = @import("sdk/plugin/checks.zig");
    _ = @import("sdk/plugin/secret_define.zig");
    _ = @import("sdk/plugin/written_secrets.zig");
    _ = limits_module;
}

test "a failing after hook rolls back the operation body and earlier hooks" {
    const After = struct {
        pub const stage: middleware.Stage = .after;
        pub const operation = testing.Record.name;
        pub fn run(ctx: *Ctx, _: *testing.Record.In, _: *const testing.Record.Out) Error!void {
            try ctx.db.exec("INSERT INTO notes (note) VALUES ('hook')");
            return error.Conflict;
        }
    };
    const Checked = SDK(.{
        .operations = &.{testing.Record},
        .middleware = &.{After},
    });
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var ctx = harness.ctx(.system);
    try ctx.db.exec("CREATE TABLE notes (note TEXT NOT NULL)");
    try std.testing.expectError(error.Conflict, Checked.dispatch(&ctx, testing.Record, .{
        .note = "body",
    }));
    try std.testing.expectEqual(@as(u32, 0), try testing.count(&ctx, "notes"));
}

test "a caught nested write failure undoes only itself" {
    const Outer = struct {
        pub const name = "atomic.outer";
        pub const kind: operation.Kind = .write;
        pub const description = "Write, then catch a nested write's failure";
        pub const In = struct {};
        pub const Out = struct {};
        pub const example: In = .{};
        pub const example_out: Out = .{};
        pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
            std.debug.assert(ctx.db.transaction_depth > 0);
            std.debug.assert(ctx.parent != null);

            const Nested = SDK(.{
                .operations = &.{testing.Record},
            });
            _ = try Nested.dispatch(ctx, testing.Record, .{
                .note = "earlier",
            });
            var copied = ctx.*;
            _ = Nested.dispatch(&copied, testing.Record, .{
                .note = "failure",
                .fail_after_insert = true,
            }) catch |err| {
                std.debug.assert(err == error.Invalid);
            };
            return .{};
        }
    };
    const Checked = SDK(.{
        .operations = &.{Outer},
    });
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var ctx = harness.ctx(.system);
    try ctx.db.exec("CREATE TABLE notes (note TEXT NOT NULL)");
    _ = try Checked.dispatch(&ctx, Outer, .{});
    try std.testing.expectEqual(@as(u32, 1), try testing.count(&ctx, "notes"));
    try std.testing.expectEqual(@as(u32, 0), ctx.db.transaction_depth);
}

test "ctx.plugin: an operation's plugin, a hook's own, kept by a core call" {
    const Seen = struct {
        fn note(ctx: *Ctx) Error!void {
            std.debug.assert(ctx.parent != null);

            try ctx.db.exec("CREATE TABLE IF NOT EXISTS seen (who TEXT NOT NULL)");

            var insert = try ctx.db.prepare("INSERT INTO seen (who) VALUES (?1)");
            defer insert.finalize();

            try insert.bind_text(1, ctx.plugin);
            try insert.exec();
        }
    };
    const Peek = struct {
        pub const name = "core.peek";
        pub const description = "Test operation: note who runs";
        pub const kind: operation.Kind = .write;
        pub const In = struct {};
        pub const Out = struct {};
        pub const example: In = .{};
        pub const example_out: Out = .{};

        pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
            try Seen.note(ctx);

            return .{};
        }
    };
    const Act = struct {
        pub const name = "alpha.act";
        pub const description = "Test operation: note who runs, then call the core";
        pub const kind: operation.Kind = .write;
        pub const In = struct {};
        pub const Out = struct {};
        pub const example: In = .{};
        pub const example_out: Out = .{};

        const Peeking = SDK(.{
            .operations = &.{Peek},
        });

        pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
            try Seen.note(ctx);
            _ = try Peeking.dispatch(ctx, Peek, .{});

            return .{};
        }
    };
    const Watch = struct {
        pub const stage: middleware.Stage = .before;
        pub const operation = "alpha.act";

        pub fn run(ctx: *Ctx, _: *Act.In) Error!void {
            try Seen.note(ctx);
        }
    };
    const Checked = SDK(.{
        .operations = &.{Act},
        .middleware = &.{Watch},
        .operation_owners = &.{"alpha"},
        .middleware_owners = &.{"beta"},
    });
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    _ = try Checked.dispatch(&ctx, Act, .{});
    try std.testing.expectEqualStrings("", ctx.plugin);

    var select = try ctx.db.prepare("SELECT who FROM seen ORDER BY rowid");
    defer select.finalize();

    const expected = [_][]const u8{ "beta", "alpha", "alpha" };

    for (expected) |who| {
        try std.testing.expect(try select.step());
        const row = try select.read(struct {
            who: []const u8,
        }, harness.fixed.allocator());

        try std.testing.expectEqualStrings(who, row.who);
    }

    try std.testing.expect(!try select.step());
}
