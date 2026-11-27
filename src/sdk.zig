const std = @import("std");
const limits_module = @import("sdk/limits.zig");
const model_operation_override = @import("model/operation_override.zig");
const error_events = @import("sdk/error_events.zig");
const store_settings = @import("store/settings.zig");
/// Rate limits: the general one and an operation's own `.limit`.
pub const limits = limits_module;
const plugin_operations = @import("publr/plugin/operation_define.zig");
const registry_tables = @import("sdk/registry_tables.zig");
const builtin = @import("builtin");
const contract = @import("model/contract.zig");
const AnyRef = @import("publr/plugin/record_define.zig").AnyRef;
const HostApi = @import("sdk/plugin/context.zig").HostApi;
const applied = @import("server/sandboxed_plugins/applied.zig");
const record_computed = @import("publr/plugin/record_computed.zig");
pub const trail = @import("sdk/trail.zig");
pub const db = @import("lib/db.zig");

pub const caller = @import("sdk/caller.zig");
pub const context = @import("sdk/context.zig");
pub const operation = @import("sdk/operation.zig");
/// What a read asks for in each dimension: `--language pl`, `{"language":"pl"}`.
pub const Dimensions = @import("sdk/dimension_input.zig").Dimensions;
pub const dimension_input = @import("sdk/dimension_input.zig");
pub const grant = @import("sdk/grant.zig");
pub const authorize = @import("sdk/authorize.zig");
pub const stored_roles = @import("sdk/roles.zig");
pub const hooks = @import("sdk/hooks.zig");
pub const mods = @import("sdk/mods.zig");
pub const delivery = @import("sdk/delivery.zig");
pub const page_request = @import("sdk/page_request.zig");
pub const provider = @import("sdk/provider.zig");
pub const sandboxed_plugins = @import("sdk/sandboxed_plugins.zig");
pub const plugin_access = @import("sdk/plugin_access.zig");
pub const published = @import("sdk/published.zig");
pub const call_json = @import("sdk/call_json.zig");
pub const help = @import("sdk/help.zig");
pub const changed_units = @import("sdk/changed_units.zig");
pub const Extended = @import("sdk/extended.zig").Extended;
pub const scratch = @import("sdk/scratch.zig");
pub const plugin_memory = @import("sdk/plugin_memory.zig");
pub const moved = @import("sdk/moved.zig");
pub const definition_cache = @import("sdk/definition_cache.zig");
/// Core's operations, whole: `p.operations`.
pub const operations = @import("operations.zig");

pub const Caller = caller.Caller;
pub const Ctx = context.Ctx;

/// What the operation about to run may move of another plugin's ledger: a plugin's operation
/// the accounts of the plugin whose code called it directly (compiled in: `code`, else the
/// installed caller); core's own operations keep what the plugin running was handed.
fn handed_by_of(ctx: *const Ctx, owner: []const u8, code: ?[]const u8) []const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (owner.len == 0) {
        return ctx.handed_by;
    }

    if (code) |running| {
        return running;
    }

    return switch (ctx.caller) {
        .plugin => |calling| calling.name,
        else => "",
    };
}

pub const Reads = context.Reads;
pub const Error = operation.Error;
pub const Grant = grant.Grant;
pub const Policy = authorize.Policy;
pub const Event = hooks.Event;
/// An app loaded from the folder, as the server started or the folder changed: core's own
/// event, emitted outside any operation.
pub const AppsLoaded = @import("publr/apps_loaded.zig").AppsLoaded;
pub const Scratch = scratch.Scratch;
pub const DefinitionCache = definition_cache.DefinitionCache;

pub const operations_max = @import("publr/operation.zig").operations_max;
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
    hooks: []const type = &.{},
    /// The plugin each operation and hook belongs to, by position; empty for the
    /// core's. Left empty, nothing belongs to a plugin.
    operation_owners: []const []const u8 = &.{},
    hook_owners: []const []const u8 = &.{},
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
    /// Core's own queued work (`publr`'s jobs): runs the job by name, answering why it
    /// failed, empty when it ran.
    core_job: ?*const fn (ctx: *Ctx, name: []const u8, input: []const u8) []const u8 = null,
};

pub const schemas_max: u32 = 64;

pub fn SDK(comptime registry: Registry) type {
    comptime validate_registry(registry);

    return struct {
        const SDKSelf = @This();
        const tables = registry_tables.Tables(registry);

        pub const operations = registry.operations;
        pub const namespaces = registry.namespaces;
        pub const schemas = registry.schemas;
        pub const migrations = registry.migrations;
        pub const removal = registry.removal;

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

        /// Whether `Operation` is core's own and its work is core's: not a plugin's
        /// operation, and not the apply of modifiers, which runs plugins' code over the
        /// values. What such an operation works with is core's alone and can be given back
        /// once its answer is copied (`PluginCtx.call`); a compiled-in plugin's own working
        /// data lies where its caller works.
        pub fn core_work(comptime Operation: type) bool {
            comptime {
                const name = Operation.name;

                std.debug.assert(name.len > 0);

                return tables.operation_owner(name).len == 0 and
                    !std.mem.startsWith(u8, name, "mod.");
            }
        }

        /// The operation the core runs for `Given`: itself; for a core operation's public
        /// shape (`publr.operations.money.Text`), the operation that takes it; for one a
        /// plugin made with `publr.operation.define`, the bound operation it became, so a
        /// plugin's own code names its operations by their definitions.
        pub fn bound(comptime Given: type) type {
            comptime {
                if (!@hasDecl(Given, "publr_operation_definition")) {
                    return shaped_by(Given) orelse Given;
                }

                // Each registered operation looked at once.
                @setEvalBranchQuota(1000 + registry.operations.len * 4);

                for (registry.operations) |Candidate| {
                    if (@hasDecl(Candidate, "definition") and Candidate.definition == Given) {
                        return Candidate;
                    }
                }

                @compileError("operation " ++ Given.verb ++ " is not listed in its plugin's " ++
                    "`.operations`");
            }
        }

        /// The registered operation whose public shape `Given` is; null when it is none's.
        fn shaped_by(comptime Given: type) ?type {
            comptime {
                std.debug.assert(Given.name.len > 0);

                const Operation = find(Given.name) orelse return null;
                const takes = Operation != Given and @hasDecl(Operation, "shape");

                return if (takes and Operation.shape == Given) Operation else null;
            }
        }

        pub fn dispatch(ctx: *Ctx, comptime Given: type, in: Given.In) Error!Given.Out {
            const Operation = comptime bound(Given);

            comptime {
                if (find(Operation.name) != Operation) {
                    @compileError("operation not registered: " ++ Operation.name);
                }
            }
            std.debug.assert(@sizeOf(Operation.In) <= in_bytes_max);

            return pipeline(ctx, Compiled(Operation), .{
                .in = in,
            });
        }

        /// The one way every operation runs, compiled in (`Compiled`) or installed
        /// (`sdk/call_json.zig`): its id and trail, admission, its plugin's code marked
        /// running, the read or the write, its events and log entries. `Body` says what
        /// differs: its name, kind, owner, secret fields and input text, how it is admitted,
        /// what runs inside, how its answer is queued and what follows a kept write.
        pub fn pipeline(ctx: *Ctx, comptime Body: type, body: Body) Error!Body.Out {
            const name = body.name();

            std.debug.assert(name.len > 0);

            const operation_id = ctx.allocate_operation_id();
            const parent = ctx.parent;
            const notify = ctx.notify;
            // What the trail keeps grows while nested calls run: never in their working memory.
            var trail_state: trail.Trail = .{
                .root = operation_id,
                .arena = ctx.lasting orelse ctx.arena,
            };
            const opened = trail_open(ctx, &trail_state);
            const installed = request_open(ctx, parent == null);
            defer request_close(installed, ctx, name, parent == null);

            ctx.publishes = ctx.publishes and parent != null;
            ctx.parent = operation_id;
            ctx.notify = &emit_event;
            defer ctx.parent = parent;
            defer ctx.notify = notify;
            defer trail_close(ctx, opened);

            const granted = body.admit(ctx, parent == null) catch |err| {
                emit(ctx, .{
                    .failed = .{
                        .operation_name = name,
                        .operation_id = operation_id,
                    },
                });
                log_failure(ctx, name, body.input_text(ctx), body.secret(), err);

                flush_top(ctx, parent == null);

                return err;
            };

            const within = ctx.within;
            const running = ctx.plugin;
            const owner = body.owner();

            ctx.within = name;
            defer ctx.within = within;

            if (owner.len > 0) {
                ctx.plugin = owner;
            }

            defer ctx.plugin = running;

            const was_code = ctx.plugin_code;
            const was_called = ctx.plugin_called;
            const was_called_by = ctx.called_by;
            const was_handed = ctx.handed_by;

            ctx.plugin_called = was_code;
            ctx.plugin_code = owner.len > 0;
            // Who called, when a compiled-in plugin's code did: what its callee's
            // `ctx.caller().from` names, as an installed plugin's calls name it.
            ctx.called_by = if (was_code) running else "";
            defer ctx.plugin_code = was_code;
            defer ctx.plugin_called = was_called;
            defer ctx.called_by = was_called_by;

            ctx.handed_by = handed_by_of(ctx, owner, if (was_code) running else null);
            defer ctx.handed_by = was_handed;

            const result = run(ctx, Body, body, &granted);

            if (result) |_| {
                emit(ctx, .{
                    .completed = .{
                        .operation_name = name,
                        .operation_id = operation_id,
                    },
                });
                log_lines(ctx, name);
            } else |err| {
                emit(ctx, .{
                    .failed = .{
                        .operation_name = name,
                        .operation_id = operation_id,
                    },
                });
                log_failure(ctx, name, body.input_text(ctx), body.secret(), err);
            }

            flush_top(ctx, parent == null);

            return result;
        }

        /// A compiled-in operation as the pipeline runs it: typed input and answer.
        fn Compiled(comptime Operation: type) type {
            return struct {
                in: Operation.In,

                const Self = @This();
                pub const Out = Operation.Out;

                pub fn name(_: Self) []const u8 {
                    return Operation.name;
                }

                pub fn kind(_: Self) operation.Kind {
                    return Operation.kind;
                }

                pub fn owner(_: Self) []const u8 {
                    return comptime tables.operation_owner(Operation.name);
                }

                pub fn secret(_: Self) []const []const u8 {
                    return comptime trail.secret_of(Operation);
                }

                pub fn input_text(self: Self, ctx: *Ctx) []const u8 {
                    return SDKSelf.input_text(ctx, self.in);
                }

                pub fn admit(self: Self, ctx: *Ctx, top: bool) Error!Grant {
                    try lists_fit(ctx, Operation.In, &self.in, .input);

                    return admit_counted(ctx, Operation, self.in, top);
                }

                pub fn run(self: Self, ctx: *Ctx, granted: *const Grant) Error!Out {
                    const out = try run_pipeline(ctx, Operation, self.in, granted);

                    try lists_fit(ctx, Operation.Out, &out, .output);

                    return out;
                }

                pub fn queue(_: Self, ctx: *Ctx, out: Out) Error!void {
                    return queue_answer(ctx, Operation.name, out);
                }

                /// What a write does outside the database once it is kept, when no other
                /// write encloses it.
                pub fn committed(self: Self, ctx: *Ctx, out: Out) Error!void {
                    if (comptime @hasDecl(Operation, "committed")) {
                        try Operation.committed(ctx, self.in, out);
                    }
                }
            };
        }

        /// Every list of an input or an answer within its limit (`operation/lists.zig`): an
        /// input past it is refused, named at the list; an answer past it fails the call, the
        /// operation's own fault.
        pub fn lists_fit(
            ctx: *Ctx,
            comptime Value: type,
            value: *const Value,
            comptime side: enum { input, output },
        ) Error!void {
            std.debug.assert(ctx.now_ms >= 0);

            const over = operation.lists.over_limit(Value, value) orelse return;
            const message = std.fmt.allocPrint(ctx.arena, switch (side) {
                .input => "At most {d}",
                .output => "The answer holds more than {d} here: answer it a page at a time",
            }, .{over.limit}) catch return error.OutOfMemory;
            const problems = ctx.arena.alloc(operation.Problem, 1) catch {
                return error.OutOfMemory;
            };

            std.debug.assert(over.path.len > 0);

            problems[0] = .{
                .field = over.path,
                .message = message,
            };

            return ctx.refuse(problems);
        }

        /// A top-level call is a request on the installed plugins, inside whatever request
        /// its adapter opened: each plugin is started once for all the call runs, and gone
        /// when it ends (`sandboxed_plugins.SandboxedPlugins.request_begin`).
        fn request_open(ctx: *Ctx, top: bool) ?*const sandboxed_plugins.SandboxedPlugins {
            std.debug.assert(ctx.now_ms >= 0);

            if (!top) {
                return null;
            }

            // What this call keeps past a piece of its work (an event kept outside a write,
            // the site's currencies) lies where the call began, never in a loop's scratch.
            ctx.call_memory = ctx.kept_memory();

            if (ctx.plugins_set_aside) |memory| {
                memory.fresh();
            }

            const installed = ctx.sandboxed_plugins orelse return null;

            if (ctx.calls_set_aside) |working| {
                working.peak_reset();
            }

            installed.request_begin();

            return installed;
        }

        /// The top-level call's request ends, core's own memory told first for the counters.
        fn request_close(
            opened: ?*const sandboxed_plugins.SandboxedPlugins,
            ctx: *Ctx,
            name: []const u8,
            top: bool,
        ) void {
            std.debug.assert(name.len > 0);
            std.debug.assert(opened == null or top);

            if (top) {
                ctx.call_memory = null;
            }

            const installed = opened orelse return;
            const scratch_module = @import("sdk/scratch.zig");
            var told: sandboxed_plugins.Counted = .{
                .label = name,
                .scratch_bytes = if (ctx.calls_set_aside) |working| working.peak_bytes() else 0,
                .arena_bytes = scratch_module.used_of(ctx.arena) orelse 0,
            };

            if (ctx.plugins_set_aside) |memory| {
                told.plugin_bytes = memory.peak_bytes();
                told.plugin_work = memory.begun;
                told.plugin_bytes_max = memory.held.buffer.len;
                told.largest_name = memory.largest_name;
                told.largest_bytes = memory.largest_bytes;
            }

            installed.counted(told);
            installed.request_end();
        }

        /// A top-level call ended: the events it kept outside its write are queued.
        fn flush_top(ctx: *Ctx, top: bool) void {
            std.debug.assert(ctx.now_ms >= 0);

            if (top) {
                flush_kept(ctx);
            }
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

            var said: [256]u8 = undefined;

            // Out of memory in compiled-in plugins: what was largest in it is named.
            if (err == error.OutOfMemory and entry.message.len == 0) {
                entry.message = memory_said(ctx, &said);
            }

            raise_failed(ctx, log.failure(ctx, &entry));
        }

        /// The largest collection a compiled-in plugin made in the request, when one grew.
        fn memory_said(ctx: *const Ctx, buffer: []u8) []const u8 {
            const memory = ctx.plugins_set_aside orelse return "";

            std.debug.assert(buffer.len > 0);

            if (memory.largest_bytes == 0) {
                return "";
            }

            return std.fmt.bufPrint(buffer, "The largest collection a compiled-in plugin " ++
                "made, {s}, held {d} KiB.", .{
                memory.largest_name,
                (memory.largest_bytes + 1023) / 1024,
            }) catch "";
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

        /// What an operation says of its callers: one made with `publr.operation.define` its
        /// `.untrusted_callers` and ready answer; any other (null) only whether it is open.
        pub const Declared = struct {
            untrusted_callers: ?bool,
            answer: ?plugin_operations.Answer = null,
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
        /// outside: their account, else their address, else their visitor id (the visitor
        /// chooses that id, so it counts only where no address is known). A context no
        /// request made has none of them and is not counted. The operation's own limit (and
        /// the site's override of it) counts untrusted callers only: a site's page scripts,
        /// and anyone calling without credentials.
        pub fn check_limits(ctx: *Ctx, name: []const u8, per_minute: ?u32) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(per_minute == null or per_minute.? > 0);

            const table = ctx.limits orelse return;
            const anonymous = if (ctx.address.len > 0) ctx.address else ctx.visitor;
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

            const owner = comptime tables.operation_owner(Operation.name);

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

            const defined = comptime @hasDecl(Operation, "untrusted_callers");
            const answered = try admit_answer(ctx, Operation.name, .{
                .untrusted_callers = if (defined) Operation.untrusted_callers else null,
                .answer = if (defined) Operation.answer else null,
                // A ready answer decides past the roles, as `open` does; so does a plugin's
                // own code calling what only plugins may (`request.read` from a compiled-in
                // hook on a visitor's order), held then to the plugin's grants.
                .open = (@hasDecl(Operation, "open") and Operation.open) or
                    (defined and Operation.answer != null) or
                    ((comptime @hasDecl(Operation, "plugins_only") and Operation.plugins_only) and
                        ctx.plugin_code),
            });

            return authorize_request(ctx, .{
                .operation_name = Operation.name,
                .kind = Operation.kind,
                .type_id = operation.type_of(in),
                .open = answered,
            });
        }

        /// Who may call, checked by the host before anything runs, for any operation,
        /// compiled in or installed. The site's answer (`operation authorize`) stands in for
        /// the code's; a ready answer decides, and the policies then only narrow it (true).
        /// Without one the default stands: administrators and the roles granted it. Through
        /// an app's address administrators are signed-in people like any other, so there the
        /// default is only the roles granted it. Without `.untrusted_callers`, nobody calls an
        /// operation made with `publr.operation.define` without credentials.
        pub fn admit_answer(ctx: *const Ctx, name: []const u8, declared: Declared) Error!bool {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(declared.answer == null or declared.open);

            const through_app = ctx.app_plugins != null;
            const defined = declared.untrusted_callers != null;
            // A plugin's code calling, installed or compiled in: a compiled-in plugin calls
            // as whoever the request is for, a visitor without credentials too.
            const plugin_code = ctx.caller == .plugin or ctx.plugin_code;
            const credentialed = ctx.caller.is_authenticated() or plugin_code;

            if (defined and !declared.untrusted_callers.? and !credentialed) {
                return error.Denied;
            }

            const ready = try answer_override(ctx, name) orelse declared.answer orelse {
                if (defined and through_app and !declared.open and !granted_in_app(ctx, name)) {
                    return error.Denied;
                }

                return declared.open;
            };

            if (!plugin_operations.admits(ready, ctx.caller, through_app, plugin_code)) {
                return error.Denied;
            }

            return true;
        }

        /// Whether a role the caller holds, other than administrator, was granted `name`.
        fn granted_in_app(ctx: *const Ctx, name: []const u8) bool {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.app_plugins != null);

            const held = ctx.caller.roles() orelse return false;
            var others: [role.user_roles_max][]const u8 = undefined;
            var count: u32 = 0;

            for (held) |held_name| {
                if (!std.mem.eql(u8, held_name, role.admin) and count < others.len) {
                    others[count] = held_name;
                    count += 1;
                }
            }

            return stored_roles.allows(ctx, others[0..count], name);
        }

        /// A call made for an app reaches only the plugins the app lists (`.plugins` in its
        /// `app.zon`) and the providers of the contracts they own (a carrier of `shipping`'s
        /// `shipping.method`): an operation of any other is denied before it runs, at any
        /// depth. Core's own operations (no owner) are never fenced here; their grants say
        /// what they reach.
        pub fn check_fence(ctx: *Ctx, owner: []const u8) Error!void {
            std.debug.assert(owner.len <= 128);

            const plugins = ctx.app_plugins orelse return;

            if (owner.len == 0) {
                return;
            }

            const reached = try @import("sdk/contract.zig").with_providers(ctx, plugins);

            for (reached) |listed| {
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

            inline for (comptime tables.hooks_where(is_pre)) |index| {
                try invoke_hook(ctx, index, .{ name, kind });
            }
        }

        /// Calls an operation by name with JSON in and out: a built-in one, or one a
        /// installed plugin brings. What a sandboxed plugin's `publr_call` reaches.
        pub fn call_json(ctx: *Ctx, name: []const u8, input: []const u8) Error![]const u8 {
            return @import("sdk/call_json.zig").call(@This(), ctx, name, input);
        }

        /// Calls an operation an installed plugin brings with a value another plugin handed
        /// over: it reaches the operation's plugin with no JSON in between.
        pub fn call_passed(
            ctx: *Ctx,
            name: []const u8,
            input: sandboxed_plugins.Passed,
        ) Error!sandboxed_plugins.Passed {
            return @import("sdk/call_json.zig").call_passed(@This(), ctx, name, input);
        }

        /// Calls another plugin's operation through what that plugin publishes: `Call`
        /// names the operation and gives its `In` and `Out` (the plugin's `interface.zig`),
        /// never its code. It goes by name, so it reaches the operation whether its plugin
        /// is compiled in or installed, through the same checks as any call.
        pub fn call(ctx: *Ctx, comptime Call: type, in: Call.In) Error!Call.Out {
            comptime std.debug.assert(Call.name.len > 0);

            // Compiled in: dispatched as it is, its input and answer copied across when
            // what the plugin publishes is a copy of the operation's own types.
            if (comptime find(Call.name)) |Operation| {
                const given = try convert(Operation.In, ctx.arena, in);
                const out = try dispatch(ctx, Operation, given);

                return convert(Call.Out, ctx.arena, out);
            }

            const input = try stringify(ctx.arena, in);
            const output = try @import("sdk/call_json.zig").call(@This(), ctx, Call.name, input);

            return json_module.parse(Call.Out, ctx.arena, output, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch error.Invalid;
        }

        /// Whether the caller may call `Operation` at all, whatever the input: what a page
        /// asks before it offers the action, never instead of the call's own check.
        pub fn may(ctx: *const Ctx, comptime Given: type) bool {
            const Operation = comptime bound(Given);

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

            if (comptime !@hasField(OperationsByName, name)) {
                return null;
            }

            const table: OperationsByName = .{};

            return @field(table, name);
        }

        /// Every operation under its name, built once: finding one costs the same however
        /// many there are.
        const OperationsByName = by_name: {
            const list = registry.operations;

            // A few branches an operation, once: the budget grows with the list.
            @setEvalBranchQuota(1000 + list.len * 16);

            var names: [list.len][]const u8 = undefined;
            var types: [list.len]type = undefined;
            var attributes: [list.len]std.builtin.Type.Struct.FieldAttributes = undefined;

            for (list, &names, &types, &attributes) |Operation, *name, *field_type, *attribute| {
                name.* = Operation.name;
                field_type.* = type;
                attribute.* = .{
                    .@"comptime" = true,
                    .default_value_ptr = &Operation,
                };
            }

            const done_names = names;
            const done_types = types;
            const done_attributes = attributes;

            break :by_name @Struct(.auto, null, &done_names, &done_types, &done_attributes);
        };

        fn run(
            ctx: *Ctx,
            comptime Body: type,
            body: Body,
            granted: *const Grant,
        ) Error!Body.Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.parent != null);

            const previous_refusal = ctx.event_refusal;

            ctx.event_refusal = null;
            defer ctx.event_refusal = previous_refusal;

            // A read: no write of its own, its event queued in the enclosing write, if any.
            if (body.kind() == .read) {
                const answer = try run_body(ctx, Body, body, granted);

                if (ctx.event_refusal) |refused| {
                    return refused;
                }

                try body.queue(ctx, answer);

                return answer;
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

            var transaction = try ctx.db.transaction();
            errdefer transaction.rollback();

            const out = try run_body(ctx, Body, body, granted);

            if (ctx.event_refusal) |refused| {
                return refused;
            }

            try body.queue(ctx, out);

            if (ctx.dependency_failure) {
                return error.InvalidationFailed;
            }

            try check_drafts(ctx);

            if (registry.log != null and at_top(ctx)) {
                try log_activity(ctx, body.name(), body.input_text(ctx), body.secret());
            }

            try transaction.commit();
            std.debug.assert(ctx.db.transaction_depth == transaction.depth - 1);

            if (ctx.db.transaction_depth == 0) {
                try body.committed(ctx, out);
            }

            return out;
        }

        /// What runs inside, marked on the trail where it starts.
        fn run_body(
            ctx: *Ctx,
            comptime Body: type,
            body: Body,
            granted: *const Grant,
        ) Error!Body.Out {
            const started = ctx.trail_start;

            ctx.trail_start = if (ctx.trail) |open| open.mark() else 0;
            defer ctx.trail_start = started;

            return body.run(ctx, granted);
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
                note_deprecated(ctx, comptime operation.deprecation_text(Operation), ctx.plugin);
            }

            var input = in;

            inline for (comptime tables.hooks_on(Operation.name)) |index| {
                if (comptime registry.hooks[index].stage == .before) {
                    try before_hook(ctx, index, Operation, &input);
                }
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                if (sandboxed.hooked(.before, Operation.name)) {
                    input = try runtime_before(ctx, sandboxed, Operation, input);
                }
            }

            try resolve_references(ctx, Operation, &input);

            var out = try invoke_run(ctx, Operation, input, granted);
            const extends = comptime @hasField(Operation.Out, "extended");

            if (extends) {
                out.extended = try out.extended.bound(ctx.arena, &ctx.plugin);
            }

            inline for (comptime tables.hooks_on(Operation.name)) |index| {
                if (comptime registry.hooks[index].stage == .after) {
                    const ran = after_hook(ctx, index, Operation, &input, &out);
                    const owner = comptime tables.hook_owner(index);

                    if (extends) extended_or_none(ctx, Operation, owner, ran) else try ran;
                }
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                if (sandboxed.hooked(.after, Operation.name)) {
                    const ran = runtime_after(ctx, sandboxed, Operation, input, out);

                    if (extends) extended_or_none(ctx, Operation, "", ran) else try ran;
                }
            }

            return out;
        }

        /// A hook extending a list read that fails leaves its fields out: the list still loads.
        /// By design: a list every screen reads never fails for one plugin's column. The read
        /// changes nothing stored; the failure is a line under the call in the logs.
        fn extended_or_none(
            ctx: *Ctx,
            comptime Operation: type,
            owner: []const u8,
            ran: Error!void,
        ) void {
            comptime std.debug.assert(@hasField(Operation.Out, "extended"));

            ran catch |err| {
                std.log.warn("a hook extending {s} failed ({t}); its fields stay empty", .{
                    Operation.name,
                    err,
                });
                hook_line(ctx, owner, "A hook adding fields to {s} failed ({t})", .{
                    Operation.name,
                    err,
                });
            };
        }

        /// A hook's failure that does not stop what it hooks, said where an administrator
        /// reads it: a line under the call in the Activity or Error log and, when the plugin
        /// is known here, on its Log. An installed hook's own line names its plugin
        /// (`server/sandboxed_plugins/interface.zig`).
        fn hook_line(
            ctx: *Ctx,
            owner: []const u8,
            comptime format: []const u8,
            args: anytype,
        ) void {
            std.debug.assert(format.len > 0);

            const lines = ctx.lines orelse return;
            var buffer: [256]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);

            writer.print(format, args) catch {
                std.debug.assert(writer.buffered().len > 0);
            };

            lines.add(.{
                .plugin = if (owner.len > 0) owner else "publr",
                .level = .warn,
                .text = writer.buffered(),
            });
        }

        /// Every reference in the input read now, as the caller may see it: an operation
        /// gets the stored records, never what a caller says about them.
        fn resolve_references(
            ctx: *Ctx,
            comptime Operation: type,
            input: *Operation.In,
        ) Error!void {
            std.debug.assert(ctx.parent != null);

            // A reference to any record is read as a record holding one reads it back.
            var host: HostApi = .{
                .inner = ctx,
            };

            try AnyRef.read_all(host.ctx(), input);

            inline for (
                comptime std.meta.fieldNames(Operation.In),
                comptime std.meta.fieldTypes(Operation.In),
            ) |field_name, FieldType| {
                const Field = FieldType;

                if (comptime Field == AnyRef or Field == []const AnyRef) {
                    continue;
                }

                if (comptime is_reference(Field)) {
                    const id = @field(input, field_name).id;

                    @field(input, field_name).value = try load_reference(ctx, Operation, Field, id);
                } else if (comptime is_reference_list(Field)) {
                    const Item = std.meta.Elem(Field);
                    const list = @field(input, field_name);
                    const loaded = ctx.arena.alloc(Item, list.len) catch return error.OutOfMemory;

                    for (list, loaded) |item, *target| {
                        target.* = item;
                        target.value = try load_reference(ctx, Operation, Item, item.id);
                    }

                    @field(input, field_name) = loaded;
                }
            }
        }

        fn load_reference(
            ctx: *Ctx,
            comptime Operation: type,
            comptime Reference: type,
            id: []const u8,
        ) Error!Reference.Document {
            const Get = comptime find_name(registry, "record.get") orelse
                @compileError("an operation taking a reference needs record.get");

            if (id.len == 0 or id.len > 128) {
                return error.Invalid;
            }

            // An internal collection (`internal:test`): the operation's plugin's own.
            const prefix = @import("operations/record/typed.zig").internal_prefix;

            if (comptime std.mem.startsWith(u8, Reference.handle, prefix)) {
                const InternalGet = comptime find_name(registry, "internal.get") orelse
                    @compileError("an operation taking an internal reference needs internal.get");
                const plugin = comptime Operation.name[0 .. std.mem.indexOfScalar(
                    u8,
                    Operation.name,
                    '.',
                ) orelse 0];
                const got = try dispatch(ctx, InternalGet, .{
                    .kind = Reference.handle[prefix.len..],
                    .id = id,
                    .plugin = plugin,
                });

                return json_module.parse(Reference.Document, ctx.arena, got.document.text, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch error.Invalid;
            }

            const got = try dispatch(ctx, Get, .{
                .id = id,
            });

            if (!std.mem.eql(u8, got.record.type, Reference.handle)) {
                return error.NotFound;
            }

            return json_module.parse(Reference.Document, ctx.arena, got.document.text, .{
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
                var wrapped: HostApi = .{
                    .inner = ctx,
                };
                const was_destructive = ctx.destructive;

                // The core operations a plugin's calls may destroy only for a `.destructive` one.
                ctx.destructive = comptime operation.destroys(Operation);
                defer ctx.destructive = was_destructive;

                // Called by a plugin's code, the whole call is in memory of its own already
                // (`PluginCtx.call`); an answer that cannot be copied whole stays where made.
                if (comptime !moved.plain(Operation.Out)) {
                    const ran = Operation.run(wrapped.ctx(), in, granted);

                    return ran catch |err| as_outcome(ctx.db, err);
                }

                if (plugin_memory.is_work(ctx.arena)) {
                    const ran = Operation.run(wrapped.ctx(), in, granted);

                    return ran catch |err| as_outcome(ctx.db, err);
                }

                var work: plugin_memory.Work = undefined;

                work.begin(ctx);

                const result = Operation.run(wrapped.ctx(), in, granted);

                work.leave();
                defer work.end();

                const answer = result catch |err| return as_outcome(ctx.db, err);

                return moved.copy(Operation.Out, ctx.arena, answer);
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
        /// `plugin` is the operation's own, empty for core's: the same line compiled in and
        /// installed.
        pub fn note_deprecated(ctx: *const Ctx, text: []const u8, plugin: []const u8) void {
            std.debug.assert(text.len > 0);

            if (builtin.is_test) {
                return;
            }

            const plugin_word = if (plugin.len > 0) ", plugin " else "";

            std.log.warn("{s} (called by {s}{s}{s})", .{
                text,
                ctx.caller.label(),
                plugin_word,
                plugin,
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

        /// A `before` hook on `Operation`: one naming only the fields it uses (another
        /// plugin's operation, `publr.remote.operation`) reads the input in its own words, and
        /// what it changed is laid over the input.
        fn before_hook(
            ctx: *Ctx,
            comptime index: u32,
            comptime Operation: type,
            input: *Operation.In,
        ) Error!void {
            const Middleware = registry.hooks[index];
            const Own = HookTakes(Middleware, 1);

            std.debug.assert(Middleware.stage == .before);

            if (!about_this(Middleware, Operation, input)) {
                return;
            }

            if (comptime Own == Operation.In) {
                return invoke_hook(ctx, index, .{input});
            }

            var mine = try hook_words.own(Own, ctx.arena, input.*);

            try invoke_hook(ctx, index, .{&mine});
            input.* = try hook_words.laid_over(Operation.In, ctx.arena, input.*, mine);
        }

        /// Whether a hook about one content type (`publr.hook.about`) hears this call: one
        /// whose input names another type is none of its; one that names none is heard.
        /// What the installed plugins' host checks before it starts a plugin
        /// (`sandboxed_plugins/interface.zig`, `hears`), the same for a plugin compiled in.
        fn about_this(
            comptime Middleware: type,
            comptime Operation: type,
            input: *const Operation.In,
        ) bool {
            const named = comptime @hasDecl(Middleware, "about") and Middleware.about.len > 0 and
                @hasField(Operation.In, "type");

            if (comptime !named) {
                return true;
            }

            std.debug.assert(Middleware.about.len <= 128);

            const given: ?[]const u8 = input.type;

            return if (given) |handle| std.mem.eql(u8, handle, Middleware.about) else true;
        }

        /// An `after` hook on `Operation`, the input and answer in its own words when it
        /// names only the fields it uses.
        fn after_hook(
            ctx: *Ctx,
            comptime index: u32,
            comptime Operation: type,
            input: *Operation.In,
            out: *Operation.Out,
        ) Error!void {
            const Middleware = registry.hooks[index];
            const OwnIn = HookTakes(Middleware, 1);
            const OwnOut = HookTakes(Middleware, 2);

            std.debug.assert(Middleware.stage == .after);

            if (!about_this(Middleware, Operation, input)) {
                return;
            }

            if (comptime @hasField(Operation.Out, "extended")) {
                if (own_extension(ctx, comptime tables.hook_owner(index))) {
                    return;
                }
            }

            if (comptime OwnIn == Operation.In and OwnOut == Operation.Out) {
                return invoke_hook(ctx, index, .{ input, out });
            }

            var in_mine = if (comptime OwnIn == Operation.In)
                input.*
            else
                try hook_words.own(OwnIn, ctx.arena, input.*);
            var out_mine = if (comptime OwnOut == Operation.Out)
                out.*
            else
                try hook_words.own(OwnOut, ctx.arena, out.*);

            return invoke_hook(ctx, index, .{ &in_mine, &out_mine });
        }

        /// Whether `owner` is the plugin making this list read: a hook extending a list's rows
        /// adds what others read, so the plugin's own reads skip it.
        fn own_extension(ctx: *const Ctx, owner: []const u8) bool {
            std.debug.assert(owner.len <= 64);
            std.debug.assert(ctx.plugin.len <= 64);

            return owner.len > 0 and std.mem.eql(u8, ctx.plugin, owner);
        }

        /// What a hook's `run` takes at `position` (after its context), pointed at.
        fn HookTakes(comptime Middleware: type, comptime position: u32) type {
            const parameters = @typeInfo(@TypeOf(Middleware.run)).@"fn".param_types;

            comptime std.debug.assert(parameters.len > position);

            return std.meta.Child(parameters[position].?);
        }

        /// Inside an operation, or outside any for an event the server announces itself
        /// (`announce`): `ctx.parent` may be null.
        pub fn invoke_hook(ctx: *Ctx, comptime index: u32, args: anytype) Error!void {
            std.debug.assert(args.len <= 2);

            const Middleware = registry.hooks[index];
            const running = ctx.plugin;
            const owner = comptime tables.hook_owner(index);

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

            // A hook never moves accounts the operation it hooks was handed.
            const was_handed = ctx.handed_by;

            ctx.handed_by = "";
            defer ctx.handed_by = was_handed;

            if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                var wrapped: HostApi = .{
                    .inner = ctx,
                };

                if (comptime !hook_memory.settles(Middleware)) {
                    return @call(.auto, Middleware.run, .{wrapped.ctx()} ++ args);
                }

                return hook_memory.run(ctx, Middleware, wrapped.ctx(), args);
            }

            return @call(.auto, Middleware.run, .{ctx} ++ args);
        }

        /// The `before` or `after` hooks on a sign-in event (`publr.auth.SignedIn`), inside
        /// the write that emits it (`hooks_on`). `before` hooks only read: they can refuse,
        /// never change anything. `spared` (an administrator signing in) is never refused: the
        /// refusal is logged and it goes on.
        pub fn event_hooks(
            ctx: *Ctx,
            comptime stage: hooks.Stage,
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
            comptime stage: hooks.Stage,
            name: []const u8,
            payload: []const u8,
            refusable: bool,
        ) Error!void {
            comptime std.debug.assert(stage == .before or stage == .after);
            std.debug.assert(name.len > 0);

            try hooks_on_compiled(ctx, stage, name, payload, refusable);

            const sandboxed = ctx.sandboxed_plugins orelse return;
            const hook_stage: sandboxed_plugins.Stage = if (stage == .before) .before else .after;

            if (!sandboxed.hooked(hook_stage, name)) {
                return;
            }

            // A `before` hook may hand back the payload changed; an event's stays as emitted.
            const sent: sandboxed_plugins.Passed = .{
                .json = payload,
            };
            const ran: Error!void = if (stage == .before)
                discard(sandboxed.before(ctx, name, sent))
            else
                sandboxed.after(ctx, name, sent, .{
                    .json = "{}",
                }, null);

            try settle_refusal(ctx, "", ran, refusable, name);
        }

        /// The compiled-in plugins' share of `hooks_on`.
        pub fn hooks_on_compiled(
            ctx: *Ctx,
            comptime stage: hooks.Stage,
            name: []const u8,
            payload: []const u8,
            refusable: bool,
        ) Error!void {
            comptime std.debug.assert(stage == .before or stage == .after);
            std.debug.assert(name.len > 0);

            const listening = comptime if (stage == .before) hears_before else hears_after;

            inline for (comptime tables.hooks_where(listening)) |index| {
                const Middleware = registry.hooks[index];

                if (std.mem.eql(u8, Middleware.event, name)) {
                    const ran = typed_hook(ctx, stage, index, payload);
                    const owner = comptime tables.hook_owner(index);

                    try settle_refusal(ctx, owner, ran, refusable, name);
                }
            }
        }

        fn typed_hook(
            ctx: *Ctx,
            comptime stage: hooks.Stage,
            comptime index: u32,
            payload: []const u8,
        ) Error!void {
            const Middleware = registry.hooks[index];

            var value = json_module.parse(Middleware.Payload, ctx.arena, payload, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return error.Invalid;

            if (stage == .before) {
                return invoke_hook(ctx, index, .{&value});
            }

            return invoke_hook(ctx, index, .{ &value, &nothing_of(Middleware) });
        }

        /// The empty answer an `after` hook on an event takes beside the payload.
        fn nothing_of(comptime Middleware: type) Nothing(Middleware) {
            return .{};
        }

        fn Nothing(comptime Middleware: type) type {
            const parameters = @typeInfo(@TypeOf(Middleware.run)).@"fn".param_types;

            return std.meta.Child(parameters[2].?);
        }

        fn discard(answer: Error!sandboxed_plugins.Passed) Error!void {
            const changed = try answer;

            std.debug.assert(changed.bytes().len <= in_bytes_max);
        }

        /// By design an event that cannot be refused (signing out, an administrator signing
        /// in) goes on when a hook on it fails: the hook's failure is said, in the server's
        /// log and as a line under the call. Each write the hook made before it failed was a
        /// whole operation of its own and stays; nothing of the event's own write changes.
        fn settle_refusal(
            ctx: *Ctx,
            owner: []const u8,
            ran: Error!void,
            refusable: bool,
            name: []const u8,
        ) Error!void {
            std.debug.assert(name.len > 0);

            ran catch |err| {
                if (refusable or err == error.OutOfMemory) {
                    return err;
                }

                std.log.warn("a hook on {s} refused ({t}); it does not stop this one", .{
                    name,
                    err,
                });
                hook_line(ctx, owner, "A hook on {s} failed ({t}): it cannot stop it", .{
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
            const answered = try sandboxed.before(ctx, Operation.name, .{
                .json = input,
            });
            const changed = try sandboxed.json_of(ctx.arena, answered, .answer);

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
            const extended = if (comptime @hasField(Operation.Out, "extended"))
                out.extended
            else
                null;

            try sandboxed.after(ctx, Operation.name, .{
                .json = input,
            }, .{
                .json = output,
            }, extended);
        }

        /// Whether any modifier, compiled in or installed, takes values applied as `name`.
        pub fn modified(ctx: *Ctx, name: []const u8) bool {
            std.debug.assert(name.len > 0);
            std.debug.assert(name.len <= mods.name_len_max);

            inline for (comptime tables.hooks_where(is_modifier)) |index| {
                if (mods.matches(registry.hooks[index].pattern, name)) {
                    return true;
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return false;

            return sandboxed.hooked(.modify, name);
        }

        /// Runs every modifier whose name takes `name` over `values`, compiled-in plugins
        /// first in their order, then installed ones, each handed what the one before
        /// answered, and answers them as the last left them. Modifiers run as their plugins,
        /// reading what they are granted, never writing; one that fails refuses the apply.
        pub fn modify_all(
            ctx: *Ctx,
            name: []const u8,
            comptime Value: type,
            values: []const Value,
        ) Error![]const Value {
            std.debug.assert(name.len > 0);
            std.debug.assert(values.len <= mods.items_max);

            if (!modified(ctx, name)) {
                return values;
            }

            const held = try applied.from_typed(Value, ctx.arena, values);
            const changed = try modify_held(ctx, name, held);

            return applied.to_typed(Value, ctx.arena, changed);
        }

        /// `modify_all` for values whose shape comes with the data: what the outer edge
        /// sent as JSON, a record's document as storage keeps it. They come back in place.
        pub fn modify(ctx: *Ctx, name: []const u8, batch: *mods.Batch) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(batch.items.len <= mods.items_max);

            if (!mods.valid(name, false)) {
                return error.Invalid;
            }

            if (!modified(ctx, name)) {
                return;
            }

            const held = try applied.from_trees(ctx.arena, batch.items);
            const changed = try modify_held(ctx, name, held);

            try applied.to_trees(ctx.arena, changed, batch.items);
        }

        /// The values `held` holds laid out (`server/sandboxed_plugins/applied.zig`) through
        /// every modifier of `name`; what they are afterwards, held the same way.
        pub fn modify_held(ctx: *Ctx, name: []const u8, held: []const u8) Error![]const u8 {
            std.debug.assert(name.len > 0);
            std.debug.assert(held.len > 0);

            // A computed field's own function is core's to run, through `compute_held`.
            if (!mods.valid(name, false) or record_computed.reserved(name)) {
                return error.Invalid;
            }

            var reading = ctx.*;
            var current = held;

            reading.reads_only = true;
            reading.applying = null;

            inline for (comptime tables.hooks_where(is_modifier)) |index| {
                if (mods.matches(registry.hooks[index].pattern, name)) {
                    current = try modify_native(&reading, index, current);
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return current;

            if (!sandboxed.hooked(.modify, name)) {
                return current;
            }

            return modified_or_refused(ctx, name, sandboxed.modify(&reading, name, current));
        }

        /// `compute_held` for values as trees: a record's document as storage keeps it. They
        /// come back in place.
        pub fn compute(
            ctx: *Ctx,
            owner: []const u8,
            name: []const u8,
            batch: *mods.Batch,
        ) Error!void {
            std.debug.assert(owner.len > 0);
            std.debug.assert(batch.items.len <= mods.items_max);

            if (batch.items.len == 0) {
                return;
            }

            const held = try applied.from_trees(ctx.arena, batch.items);
            const changed = try compute_held(ctx, owner, name, held);

            try applied.to_trees(ctx.arena, changed, batch.items);
        }

        /// A computed field's values worked out: `owner`'s own function of `name`
        /// (`computed.<record>.<field>`) over the values `held` holds, compiled in or
        /// installed, and no other plugin's. It reads, never writes; its error refuses.
        pub fn compute_held(
            ctx: *Ctx,
            owner: []const u8,
            name: []const u8,
            held: []const u8,
        ) Error![]const u8 {
            std.debug.assert(owner.len > 0);
            std.debug.assert(held.len > 0);

            if (!record_computed.reserved(name) or !mods.valid(name, false)) {
                return error.Invalid;
            }

            var reading = ctx.*;

            reading.reads_only = true;
            reading.applying = null;

            inline for (comptime tables.hooks_where(is_modifier)) |index| {
                const own = std.mem.eql(u8, comptime tables.hook_owner(index), owner);

                if (own and std.mem.eql(u8, registry.hooks[index].pattern, name)) {
                    return modify_native(&reading, index, held);
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return held;

            return modified_or_refused(
                ctx,
                name,
                sandboxed.compute(&reading, owner, name, held),
            );
        }

        /// One compiled-in modifier over the values `current` holds: those that read as its
        /// type are handed to it as its own structs, and what it leaves them as is laid
        /// over the values where they lie, as an installed modifier's answer is.
        fn modify_native(ctx: *Ctx, comptime index: u32, current: []const u8) Error![]const u8 {
            const owner = comptime tables.hook_owner(index);

            std.debug.assert(ctx.reads_only);
            std.debug.assert(current.len > 0);

            ctx.plugin = owner;

            const was_code = ctx.plugin_code;

            ctx.plugin_code = true;
            defer ctx.plugin_code = was_code;

            const was_handed = ctx.handed_by;

            ctx.handed_by = "";
            defer ctx.handed_by = was_handed;

            // The modifier works in memory of its own, the values in its type included:
            // only what it left them as is kept, in the memory the apply works in.
            var work: plugin_memory.Work = undefined;

            work.begin(ctx);

            const answered = modifier_answer(ctx, index, current);

            work.leave();
            defer work.end();

            const last = try answered;

            if (last.ptr == current.ptr or !work.own()) {
                return last;
            }

            return ctx.arena.dupe(u8, last) catch error.OutOfMemory;
        }

        /// What the modifier at `index` left the values of `current` as, in `ctx.arena`.
        fn modifier_answer(
            ctx: *Ctx,
            comptime index: u32,
            current: []const u8,
        ) Error![]const u8 {
            const Middleware = registry.hooks[index];
            const memory = ctx.arena;
            var standing: applied.Opened = undefined;

            comptime std.debug.assert(Middleware.stage == .modify);
            std.debug.assert(current.len > 0);

            try standing.init(memory, current);

            const taken = try applied.fitting(Middleware.Value, memory, &standing);
            var wrapped: HostApi = .{
                .inner = ctx,
            };

            Middleware.run(wrapped.ctx(), taken.values) catch |err| {
                const owner = comptime tables.hook_owner(index);
                const pattern = Middleware.pattern;

                std.log.warn("plugin {s}: modifier on {s}: {t}", .{ owner, pattern, err });

                return err;
            };

            return applied.answered(Middleware.Value, memory, &standing, taken);
        }

        /// What the installed modifiers of `name` answered, or the call refused: a modifier
        /// that ran out of its budget or of memory, trapped or failed in any other way
        /// never leaves the values as they were without a word. The refusal says which name.
        fn modified_or_refused(
            ctx: *Ctx,
            name: []const u8,
            answered: Error![]const u8,
        ) Error![]const u8 {
            std.debug.assert(name.len > 0);

            return answered catch |err| {
                std.log.warn("modifiers on {s}: {t}", .{ name, err });

                if (ctx.failure == null) {
                    ctx.failure = .{
                        .name = "ModifierFailed",
                        .status = 409,
                        .message = modifier_message(ctx.arena, name, err),
                    };
                }

                return if (err == error.OutOfMemory) error.OutOfMemory else error.Failed;
            };
        }

        fn modifier_message(arena: std.mem.Allocator, name: []const u8, err: Error) []const u8 {
            std.debug.assert(name.len > 0);

            const why = switch (err) {
                error.Unavailable => "it ran out of its time or stopped",
                error.OutOfMemory => "it ran out of memory",
                error.Throttled => "it made more calls than it may",
                else => @errorName(err),
            };

            return std.fmt.allocPrint(arena, "A modifier of {s} failed: {s}", .{ name, why }) catch
                "A modifier failed";
        }

        /// Every modifier, compiled in then installed: whose it is, the name it takes, why.
        pub fn modifiers(ctx: *Ctx) Error![]const mods.Modifier {
            std.debug.assert(ctx.now_ms >= 0);

            var out: std.ArrayList(mods.Modifier) = .empty;

            inline for (comptime tables.hooks_where(is_modifier)) |index| {
                const Middleware = registry.hooks[index];

                out.append(ctx.arena, .{
                    .plugin = comptime tables.hook_owner(index),
                    .name = Middleware.pattern,
                    .reason = if (@hasDecl(Middleware, "reason")) Middleware.reason else "",
                }) catch return error.OutOfMemory;
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
        /// loaded from the folder, `AppsLoaded`). `after` hooks hear it now, with nothing to
        /// refuse (a failure is logged); `on` hooks from the queue as any other.
        pub fn announce(ctx: *Ctx, comptime Emitted: type, payload: Emitted.Payload) void {
            comptime std.debug.assert(Emitted.full_name.len > 0);
            std.debug.assert(ctx.parent == null);

            const subject = stringify(ctx.arena, payload) catch |err| {
                std.log.warn("events: {s} not announced: {t}", .{ Emitted.full_name, err });
                return;
            };

            hooks_on(ctx, .after, Emitted.full_name, subject, false) catch |err| {
                std.log.warn("events: hooks on {s} failed: {t}", .{ Emitted.full_name, err });
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
                .emitted => |emitted| open.emitted(emitted.name, emitted.subject),
            }
        }

        /// An event emitted inside a call: kept on the trail, its `after` hooks run now when
        /// `after` (a refusal fails the write before it commits), then queued for the `on`
        /// hooks (`events.zig`).
        pub fn emit_event(ctx: *Ctx, emitted: Event.Emitted, after: bool) void {
            std.debug.assert(emitted.name.len > 0);
            std.debug.assert(emitted.operation_id != 0);

            if (ctx.trail) |open| {
                follow(ctx, open, .{
                    .emitted = emitted,
                });
            }

            if (after) {
                hooks_on(ctx, .after, emitted.name, emitted.subject, true) catch |err| {
                    ctx.event_refusal = ctx.event_refusal orelse err;
                };
            }

            if (events.heard_outside(ctx, emitted.name)) {
                events.queue(ctx, emitted);
            }
        }

        /// An event a plugin's code emits outside any write (an `on` hook's run, which hears
        /// what committed): emitted in a write of its own, its `after` hooks run and its
        /// `on` hooks queued there. Refused or failed, nothing is kept and the log says why.
        pub fn emit_alone(ctx: *Ctx, name: []const u8, payload: []const u8) void {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.parent == null);

            const refused_before = ctx.event_refusal;

            ctx.event_refusal = null;
            defer ctx.event_refusal = refused_before;

            var transaction = ctx.db.transaction() catch |err| {
                std.log.warn("events: {s} not emitted: {t}", .{ name, err });
                return;
            };

            emit_event(ctx, .{
                .operation_id = ctx.allocate_operation_id(),
                .name = name,
                .subject = payload,
            }, true);

            if (ctx.event_refusal) |refused| {
                transaction.rollback();
                std.log.warn("events: {s} not emitted: a hook refused it ({t})", .{
                    name,
                    refused,
                });
                return;
            }

            transaction.commit() catch |err| {
                transaction.rollback();
                std.log.warn("events: {s} not emitted: {t}", .{ name, err });
            };
        }

        /// A write about to commit for a device that may not publish: refused when it
        /// changed what visitors see, so the whole write rolls back and waits for a person.
        pub fn check_drafts(ctx: *Ctx) Error!void {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (ctx.publishes and ctx.drafts_only()) {
                return ctx.fail(operation.drafts_only);
            }
        }

        /// An operation's end, kept on the trail and heard by the hooks naming no event that
        /// `.extend` gives (`host.middleware`: a deployment closing once the write committed);
        /// an installed plugin's change reloads the plugins. An event goes on to its hooks
        /// (`emit_event`). No `on` hook hears an operation's end here: its own event is queued
        /// with its answer inside its write (`queue_answer`).
        pub fn emit(ctx: *Ctx, event: Event) void {
            std.debug.assert(ctx.next_operation_id > 1);
            std.debug.assert(registry.hooks.len <= hooks.hooks_max);

            std.debug.assert(event != .emitted);

            if (ctx.trail) |open| {
                follow(ctx, open, event);
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                sandboxed.event(ctx, event);
            }

            inline for (comptime tables.hooks_where(hears_ends)) |index| {
                _ = run_listener(ctx, index, event);
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

        /// Whether an `on` hook hears operation `name`'s answer: only then is it written
        /// as JSON for the queue.
        pub fn answer_heard(ctx: *const Ctx, name: []const u8) bool {
            std.debug.assert(name.len > 0);

            return events.heard_outside(ctx, name);
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

        /// `queue_answer` for an installed operation's answer as its plugin handed it over:
        /// each hook waits with what its own type names of it (`events.queue_passed`).
        pub fn queue_answer_passed(
            ctx: *Ctx,
            name: []const u8,
            out: sandboxed_plugins.Passed,
        ) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.parent != null);

            if (!events.heard_outside(ctx, name)) {
                return;
            }

            events.queue_passed(ctx, name, out);
        }

        /// One `on` hook hearing a queued event: a typed one gets the payload read into its
        /// type (an operation's answer, an event's payload); a failure is logged in the run.
        /// Answers the hook's own words for why it failed; empty when it ran or never fails.
        pub fn run_listener(ctx: *Ctx, comptime index: u32, event: Event) []const u8 {
            const Middleware = registry.hooks[index];

            comptime std.debug.assert(Middleware.stage == .on);
            std.debug.assert(ctx.now_ms >= 0);

            const running = ctx.plugin;
            const owner = comptime tables.hook_owner(index);

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

            // A hook never moves accounts the operation it hooks was handed.
            const was_handed = ctx.handed_by;

            ctx.handed_by = "";
            defer ctx.handed_by = was_handed;

            // A plugin's hook works in memory of its own, the payload in its type included;
            // only its words for a failure are kept.
            var work: plugin_memory.Work = undefined;

            if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                work.begin(ctx);
            } else {
                work.stay(ctx);
            }

            const said = heard(ctx, Middleware, event);

            work.leave();
            defer work.end();

            return if (said.len > 0 and work.own()) ctx.arena.dupe(u8, said) catch "" else said;
        }

        /// The hook run on `event`, in `ctx.arena`; its words for a failure.
        fn heard(ctx: *Ctx, comptime Middleware: type, event: Event) []const u8 {
            comptime std.debug.assert(Middleware.stage == .on);
            std.debug.assert(ctx.now_ms >= 0);

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
                    var wrapped: HostApi = .{
                        .inner = ctx,
                    };
                    const ran = Middleware.run(wrapped.ctx(), payload);

                    return settle_listener(ctx, Middleware, event, ran);
                }

                return settle_listener(ctx, Middleware, event, Middleware.run(ctx, payload));
            }

            if (comptime plugin_context.takes_plugin_ctx(Middleware.run)) {
                var wrapped: HostApi = .{
                    .inner = ctx,
                };

                const ran = Middleware.run(wrapped.ctx(), event);

                return settle_listener(ctx, Middleware, event, ran);
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

        /// The events' way to the `on` hooks, and an operation's hooks a bulk write runs over
        /// many inputs at once.
        pub const events = @import("sdk/events.zig").Events(@This(), registry);
        pub const bulk = @import("sdk/bulk.zig").Bulk(@This(), registry);
        /// The queued jobs, run between requests.
        pub const jobs = @import("sdk/jobs.zig").Jobs(@This(), registry);
    };
}

const json_module = @import("lib/json.zig");
const hook_words = @import("sdk/hook_words.zig");
const hook_memory = @import("sdk/hook_memory.zig");

/// Whether an `on` hook hears this event: the one it names (`event`), by the operation's
/// name or the event's, as an installed plugin's hook does.
pub fn hears(comptime Middleware: type, event: Event) bool {
    comptime std.debug.assert(Middleware.stage == .on);
    comptime std.debug.assert(Middleware.event.len > 0);

    const name = switch (event) {
        .completed => |completed| completed.operation_name,
        .failed => |failed| failed.operation_name,
        .emitted => |emitted| emitted.name,
    };

    return std.mem.eql(u8, name, Middleware.event);
}

/// `from` as `To` when both describe one shape (an operation's own types and the copy its
/// plugin publishes): fields by name, a missing one from its default, enums and unions by
/// tag name; what `To` leaves out is dropped, as a JSON answer's unknown fields are.
fn convert(comptime To: type, arena: std.mem.Allocator, from: anytype) Error!To {
    const From = @TypeOf(from);

    if (From == To) {
        return from;
    }

    switch (@typeInfo(To)) {
        .optional => |optional| {
            if (@typeInfo(From) == .optional) {
                const present = from orelse return null;

                return try convert(optional.child, arena, present);
            }

            return try convert(optional.child, arena, from);
        },
        .pointer => |pointer| {
            comptime std.debug.assert(pointer.size == .slice);

            if (@typeInfo(From) == .optional) {
                return convert(To, arena, from orelse return error.Invalid);
            }

            if (comptime std.meta.Elem(From) == pointer.child) {
                return from;
            }

            const items = arena.alloc(pointer.child, from.len) catch return error.OutOfMemory;

            for (from, items) |item, *target| {
                target.* = try convert(pointer.child, arena, item);
            }

            return items;
        },
        .@"struct" => |shape| {
            if (@typeInfo(From) == .optional) {
                return convert(To, arena, from orelse return error.Invalid);
            }

            // An object whose keys come with the data (money as `publr.Money` on one side,
            // `operation.Json` on the other): copied through its JSON.
            if (comptime free_object(To) or free_object(From)) {
                return json_module.parse(To, arena, try stringify(arena, from), .{
                    .allocate = .alloc_always,
                    .ignore_unknown_fields = true,
                }) catch error.Invalid;
            }

            var to: To = undefined;

            inline for (
                shape.field_names,
                shape.field_types,
                shape.field_attrs,
            ) |field_name, FieldType, field_attrs| {
                if (comptime @hasField(From, field_name)) {
                    const value = @field(from, field_name);

                    @field(to, field_name) = try convert(FieldType, arena, value);
                } else if (comptime field_attrs.defaultValue(FieldType)) |default| {
                    @field(to, field_name) = default;
                } else {
                    @compileError(@typeName(From) ++ " has no `" ++ field_name ++ "`");
                }
            }

            return to;
        },
        .@"enum" => return std.meta.stringToEnum(To, @tagName(from)) orelse error.Invalid,
        .@"union" => switch (from) {
            inline else => |value, tag| {
                if (comptime !@hasField(To, @tagName(tag))) {
                    return error.Invalid;
                }

                const Field = @FieldType(To, @tagName(tag));

                return @unionInit(To, @tagName(tag), try convert(Field, arena, value));
            },
        },
        .int => return std.math.cast(To, from) orelse error.Invalid,
        else => @compileError("no copy of " ++ @typeName(From) ++ " as " ++ @typeName(To)),
    }
}

/// Written as an object whose keys come with the data: `publr.Money`, `operation.Json`.
fn free_object(comptime Type: type) bool {
    comptime std.debug.assert(@typeInfo(Type) != .void);

    const is_struct = @typeInfo(Type) == .@"struct";

    return is_struct and (@hasDecl(Type, "json_object") or
        @import("model/contract.zig").is_json_map(Type));
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

/// A `pre` hook: every operation's, before authorization.
fn is_pre(comptime Middleware: type) bool {
    return Middleware.stage == .pre;
}

/// A modifier (`mods.zig`).
fn is_modifier(comptime Middleware: type) bool {
    return Middleware.stage == .modify;
}

/// A `before` hook on an event, reading its payload.
fn hears_before(comptime Middleware: type) bool {
    return Middleware.stage == .before and @hasDecl(Middleware, "event") and
        @hasDecl(Middleware, "Payload");
}

/// An `after` hook on an event, reading its payload.
fn hears_after(comptime Middleware: type) bool {
    return Middleware.stage == .after and @hasDecl(Middleware, "event") and
        @hasDecl(Middleware, "Payload");
}

/// An `on` hook naming no event: it hears every operation's end as it happens.
fn hears_ends(comptime Middleware: type) bool {
    return Middleware.stage == .on and !@hasDecl(Middleware, "event");
}

/// Branches the registry's own checks take (roles, namespaces, policies), whatever its size.
const validation_branches_base: u32 = 100_000;
/// Branches one operation's checks add at most: its shapes and examples walked once, the doc
/// lines of its text fields read once (`operation.values`), its name compared with every
/// other's.
const validation_branches_per_operation: u32 = 512;

fn validate_registry(comptime registry: Registry) void {
    comptime {
        @setEvalBranchQuota(validation_branches_base +
            registry.operations.len * validation_branches_per_operation +
            registry.operations.len * registry.operations.len);

        const owned_operations = registry.operation_owners.len;
        const owned_hooks = registry.hook_owners.len;

        if (owned_operations > 0 and owned_operations != registry.operations.len) {
            @compileError("operation_owners names one owner per operation");
        }

        if (owned_hooks > 0 and owned_hooks != registry.hooks.len) {
            @compileError("hook_owners names one owner per hook");
        }

        if (registry.operations.len > operations_max) {
            @compileError("too many operations");
        }

        const too_many_hooks = registry.hooks.len > hooks.hooks_max;

        if (too_many_hooks) {
            @compileError("too many hooks");
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

        for (registry.hooks) |Middleware| {
            hooks.validate(Middleware);
            // A hook on an event (`auth.signed_in`) is named for it, not for an operation.
            const targets_operation = (Middleware.stage == .before or
                Middleware.stage == .after) and !@hasDecl(Middleware, "event");
            const tables = registry_tables.Tables(registry);
            const unknown = targets_operation and
                tables.operation_position(Middleware.operation) == null;

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

        return !registry_tables.Tables(registry).present(plugin_of(name));
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

    const position = registry_tables.Tables(registry).operation_position(name) orelse return null;

    return registry.operations[position];
}

pub const testing = struct {
    const cli = @import("adapters/cli.zig");
    /// A documented answer and a real one compared as documentation can promise.
    pub const shape = @import("sdk/shape.zig");
    /// Every `Example:` of a plugin's operations, run against an empty site with it.
    pub const examples = @import("sdk/examples.zig").check;
    /// What a page's reads named, for tests reading as a page would.
    pub const reads = @import("sdk/reads_testing.zig");
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
        call_scratch_buffer: []u8,
        call_scratch: scratch.Scratch,
        /// Compiled-in plugins' working memory, as small as the arena a test call gets.
        plugin_buffer: plugin_memory.Buffer,
        plugin_memory: plugin_memory.Memory,

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

            harness.call_scratch_buffer = try std.testing.allocator.alloc(u8, scratch.call_bytes);
            errdefer std.testing.allocator.free(harness.call_scratch_buffer);

            harness.call_scratch = .{
                .fixed = .init(harness.call_scratch_buffer),
            };

            harness.plugin_buffer = try std.testing.allocator.alignedAlloc(
                u8,
                plugin_memory.alignment,
                harness_arena_bytes,
            );
            errdefer std.testing.allocator.free(harness.plugin_buffer);

            harness.plugin_memory.init(harness.plugin_buffer);

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
            std.testing.allocator.free(harness.call_scratch_buffer);
            std.testing.allocator.free(harness.plugin_buffer);
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
            made.calls_set_aside = &harness.call_scratch;
            made.plugins_set_aside = &harness.plugin_memory;

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
        pub const stage: hooks.Stage = .before;
        pub const operation = "hello.record";

        pub fn run(ctx: *Ctx, in: *Record.In) Error!void {
            in.note = std.ascii.allocUpperString(ctx.arena, in.note) catch return error.OutOfMemory;
        }
    };

    /// Whether `Gate` vetoes every call, for the test that needs it.
    pub var gate_closed: bool = false;

    pub const Gate = struct {
        pub const stage: hooks.Stage = .pre;

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
        pub const stage: hooks.Stage = .on;
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
    .hooks = &.{ testing.Gate, testing.Shout, testing.Journal },
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
        .grants = &.{"news.*"},
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
    _ = @import("sdk/hook_words.zig");
    _ = @import("sdk/hook_memory.zig");
    _ = @import("sdk/plugin_memory.zig");
    _ = @import("sdk/plugin_memory/work.zig");
    _ = @import("publr/plugin/decimal.zig");
    _ = @import("publr/provider_ref.zig");
    _ = @import("sdk/hook_runs.zig");
    _ = @import("sdk/plugin/checks.zig");
    _ = @import("sdk/plugin/secret_define.zig");
    _ = @import("sdk/plugin/written_secrets.zig");
    _ = @import("sdk/plugin/prepared_queries.zig");
    _ = @import("sdk/plugin/wire_json.zig");
    _ = @import("sdk/plugin/read_memo.zig");
    _ = @import("sdk/plugin/laid_key.zig");
    _ = @import("sdk/plugin/guest_memory/runs.zig");
    _ = @import("sdk/plugin/guest_memory/arena.zig");
    _ = @import("sdk/plugin/guest_memory/large.zig");
    _ = @import("sdk/plugin/guest_memory/heap.zig");
    _ = @import("publr/plugin/modify_define.zig");
    _ = @import("sdk/mods.zig");
    _ = @import("publr/plugin/json_api.zig");
    _ = @import("sdk/plugin/shape_wire.zig");
    _ = @import("server/sandboxed_plugins/described.zig");
    _ = @import("server/sandboxed_plugins/given.zig");
    _ = @import("server/sandboxed_plugins/given_typed.zig");
    _ = @import("server/sandboxed_plugins/laid.zig");
    _ = @import("server/sandboxed_plugins/laid_typed.zig");
    _ = @import("server/sandboxed_plugins/transfer.zig");
    _ = @import("server/sandboxed_plugins/held.zig");
    _ = @import("lib/groq.zig");
    _ = @import("server/plugin_build/check.zig");
    _ = @import("operations/plugin/lifecycle.zig");
    _ = @import("sdk/contract.zig");
    _ = @import("sdk/messaging.zig");
    _ = limits_module;
}

test "a failing after hook rolls back the operation body and earlier hooks" {
    const After = struct {
        pub const stage: hooks.Stage = .after;
        pub const operation = testing.Record.name;
        pub fn run(ctx: *Ctx, _: *testing.Record.In, _: *const testing.Record.Out) Error!void {
            try ctx.db.exec("INSERT INTO notes (note) VALUES ('hook')");
            return error.Conflict;
        }
    };
    const Checked = SDK(.{
        .operations = &.{testing.Record},
        .hooks = &.{After},
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
        pub const stage: hooks.Stage = .before;
        pub const operation = "alpha.act";

        pub fn run(ctx: *Ctx, _: *Act.In) Error!void {
            try Seen.note(ctx);
        }
    };
    const Checked = SDK(.{
        .operations = &.{Act},
        .hooks = &.{Watch},
        .operation_owners = &.{"alpha"},
        .hook_owners = &.{"beta"},
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

test "a compiled-in plugin's work is in memory of its own, given back as each piece ends" {
    const Heavy = struct {
        pub const name = "alpha.heavy";
        pub const description = "Test operation: a megabyte of working data, a short answer";
        pub const kind: operation.Kind = .write;
        pub const In = struct {
            title: []const u8,
            refuse: bool = false,
        };
        pub const Out = struct {
            text: []const u8,
        };
        pub const example: In = .{
            .title = "tea",
        };
        pub const example_out: Out = .{
            .text = "TEA! 1048576",
        };

        pub fn run(ctx: *PluginCtx, in: In, _: *const Grant) Error!Out {
            std.debug.assert(in.title.len > 0);

            const working = try ctx.alloc(u8, 1 << 20);

            @memset(working, 7);

            if (in.refuse) {
                return ctx.fail(.TooHeavy, "{title} is too heavy", .{
                    .title = in.title,
                });
            }

            // A step's memory goes before the call ends; what it keeps stays.
            var step = ctx.scope();

            @memset(try ctx.alloc(u8, 1 << 20), 9);

            const kept = try step.keep(try ctx.print("{d}", .{working.len}));

            step.end();

            return .{
                .text = try ctx.print("{s} {s}", .{ in.title, kept }),
            };
        }
    };
    const Louder = struct {
        pub const stage: hooks.Stage = .before;
        pub const operation = "alpha.heavy";

        pub fn run(ctx: *PluginCtx, in: *Heavy.In) Error!void {
            std.debug.assert(in.title.len > 0);

            @memset(try ctx.alloc(u8, 1 << 20), 3);
            in.title = try ctx.print("{s}!", .{
                std.ascii.allocUpperString(ctx.arena(), in.title) catch return error.OutOfMemory,
            });
        }
    };
    const Checked = SDK(.{
        .operations = &.{Heavy},
        .operation_owners = &.{"alpha"},
        .hooks = &.{Louder},
        .hook_owners = &.{"beta"},
    });
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const before = harness.fixed.end_index;

    // Each call takes three megabytes of working data: sixteen fit in neither the
    // request's four nor the plugins' four unless every piece gives its own back.
    for (0..16) |_| {
        const answered = try Checked.dispatch(&ctx, Heavy, .{
            .title = "tea",
        });

        try std.testing.expectEqualStrings("TEA! 1048576", answered.text);
        try std.testing.expectEqual(@as(u32, 0), harness.plugin_memory.open);
    }

    try std.testing.expect(harness.fixed.end_index - before < 64 << 10);
    try std.testing.expect(harness.plugin_memory.peak_bytes() >= 2 << 20);
    try std.testing.expect(!plugin_memory.is_work(ctx.arena));

    // A refusal's words, made in the work's memory, are read after it is given back.
    try std.testing.expectError(error.Failed, Checked.dispatch(&ctx, Heavy, .{
        .title = "tea",
        .refuse = true,
    }));
    try std.testing.expectEqualStrings("TEA! is too heavy", ctx.failure.?.message);
    try std.testing.expectEqual(@as(u32, 0), harness.plugin_memory.open);
}

test "a compiled-in plugin's call names it to its callee, as an installed one's does" {
    const Asked = struct {
        pub const name = "beta.asked";
        pub const description = "Test operation: who called";
        pub const kind: operation.Kind = .write;
        pub const In = struct {};
        pub const Out = struct {
            from: []const u8,
        };
        pub const example: In = .{};
        pub const example_out: Out = .{
            .from = "alpha",
        };

        pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
            std.debug.assert(ctx.plugin_code);

            var view: @import("sdk/plugin/context.zig").HostApi = .{
                .inner = ctx,
            };
            const from = view.caller().from;

            return .{
                .from = if (from == .plugin) from.plugin else @tagName(from),
            };
        }
    };
    const Asking = SDK(.{
        .operations = &.{Asked},
        .operation_owners = &.{"beta"},
    });
    const Ask = struct {
        pub const name = "alpha.ask";
        pub const description = "Test operation: call beta from alpha's code";
        pub const kind: operation.Kind = .write;
        pub const In = struct {};
        pub const Out = Asked.Out;
        pub const example: In = .{};
        pub const example_out: Out = Asked.example_out;

        pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
            std.debug.assert(ctx.plugin_code);

            return Asking.dispatch(ctx, Asked, .{});
        }
    };
    const Checked = SDK(.{
        .operations = &.{Ask},
        .operation_owners = &.{"alpha"},
    });
    var harness: testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.{
        .user = .{
            .id = "u_admin",
        },
    });
    const asked = try Checked.dispatch(&ctx, Ask, .{});

    try std.testing.expectEqualStrings("alpha", asked.from);
    try std.testing.expectEqualStrings("", ctx.called_by);

    // Called by the person, not a plugin's code: the admin.
    var direct = harness.ctx(.{
        .user = .{
            .id = "u_admin",
        },
    });

    try std.testing.expectEqualStrings("admin", (try Asking.dispatch(&direct, Asked, .{})).from);
}
