//! An event's way to its hooks. An intrinsic listener (`pub const intrinsic = true`, core's
//! own `.on` middleware) is part of the write: it hears the event inside the write's
//! transaction, so what it keeps commits or rolls back with the write, and a write over many
//! records hands it all of them at once when it has a set form (`run_many`). Every `on` hook,
//! compiled in or installed, hears it from the queue: a job per hook (`job_queue`), queued in
//! the write's transaction and run once the write has committed, by the worker beside the
//! server, retried as any job.
const std = @import("std");
const sdk = @import("../sdk.zig");
const job_queue = @import("../store/job_queue.zig");
const hook_runs = @import("hook_runs.zig");

const Ctx = sdk.Ctx;
const Event = sdk.Event;
const Emitted = Event.Emitted;

pub fn Events(comptime SDK: type, comptime registry: sdk.Registry) type {
    return struct {
        /// Whether a compiled-in listener is part of the write that emits an event.
        pub fn intrinsic(comptime Middleware: type) bool {
            comptime std.debug.assert(Middleware.stage == .on);

            return @hasDecl(Middleware, "intrinsic") and Middleware.intrinsic;
        }

        /// One event: the intrinsic listeners now, the `on` hooks from the queue.
        pub fn hand(ctx: *Ctx, emitted: Emitted) void {
            std.debug.assert(emitted.name.len > 0);
            std.debug.assert(emitted.operation_id != 0);

            const event: Event = .{
                .emitted = emitted,
            };

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and intrinsic(Middleware);

                if (listens and sdk.hears(Middleware, event)) {
                    _ = SDK.run_listener(ctx, Middleware, event);
                }
            }

            if (heard_outside(ctx, emitted.name)) {
                queue(ctx, emitted);
            }
        }

        /// Many events of one write: an intrinsic listener with a set form hears them in one
        /// call, the others one by one; each is queued for the `on` hooks.
        pub fn hand_many(ctx: *Ctx, many: []const Emitted) sdk.Error!void {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(many.len > 0);

            for (many) |emitted| {
                SDK.follow_event(ctx, emitted);
            }

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and intrinsic(Middleware);

                if (listens) {
                    try hand_to(ctx, Middleware, many);
                }
            }

            for (many) |emitted| {
                if (heard_outside(ctx, emitted.name)) {
                    queue(ctx, emitted);
                }
            }
        }

        fn hand_to(ctx: *Ctx, comptime Middleware: type, many: []const Emitted) sdk.Error!void {
            comptime std.debug.assert(intrinsic(Middleware));
            std.debug.assert(many.len > 0);

            if (comptime !@hasDecl(Middleware, "run_many")) {
                for (many) |emitted| {
                    const event: Event = .{
                        .emitted = emitted,
                    };

                    if (sdk.hears(Middleware, event)) {
                        _ = SDK.run_listener(ctx, Middleware, event);
                    }
                }

                return;
            }

            var heard: std.ArrayList(Emitted) = .empty;

            for (many) |emitted| {
                const event: Event = .{
                    .emitted = emitted,
                };

                if (sdk.hears(Middleware, event)) {
                    heard.append(ctx.arena, emitted) catch return error.OutOfMemory;
                }
            }

            if (heard.items.len > 0) {
                Middleware.run_many(ctx, heard.items);
            }
        }

        /// Kept for the `on` hooks, in the write's transaction: one job per hook that hears
        /// it (`on:<event>`, `#2` for a plugin's second), its payload the job's input, run
        /// from the queue once the write commits. A hook that could not be queued fails the
        /// write, as a site change not raised does: it would never hear it.
        pub fn queue(ctx: *Ctx, emitted: Emitted) void {
            std.debug.assert(emitted.name.len > 0);
            std.debug.assert(emitted.operation_id != 0);

            queue_hooks(ctx, emitted) catch |err| {
                ctx.dependency_failure = true;
                std.log.warn("events: {s} not queued: {t}", .{ emitted.name, err });
            };
        }

        fn queue_hooks(ctx: *Ctx, emitted: Emitted) job_queue.Error!void {
            std.debug.assert(emitted.name.len > 0);

            const event: Event = .{
                .emitted = emitted,
            };

            inline for (registry.middleware, 0..) |Middleware, index| {
                const listens = comptime Middleware.stage == .on and !intrinsic(Middleware);

                if (listens and sdk.hears(Middleware, event)) {
                    const ordinal = ordinal_of(index, event);

                    try queue_one(ctx, comptime owner_at(index), ordinal, emitted);
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return;
            const hooks = sandboxed.on_hooks(ctx.arena, emitted.name) catch
                return error.OutOfMemory;

            for (hooks) |hook| {
                try queue_one(ctx, hook.plugin, hook.ordinal, emitted);
            }
        }

        /// One hook's run, due now. A payload over a job's input limit cannot wait in the
        /// queue: the run is kept failed at once, saying so.
        fn queue_one(
            ctx: *Ctx,
            plugin: []const u8,
            ordinal: u32,
            emitted: Emitted,
        ) job_queue.Error!void {
            std.debug.assert(plugin.len > 0);
            std.debug.assert(emitted.subject.len > 0);

            const job: job_queue.Queued = .{
                .plugin = plugin,
                .name = try hook_runs.name_of(ctx.arena, emitted.name, ordinal),
                .input = emitted.subject,
                .due_at_ms = ctx.now_ms,
                .now_ms = ctx.now_ms,
            };

            if (emitted.subject.len <= job_queue.input_bytes_max) {
                return job_queue.push(ctx.db, job);
            }

            var kept = job;

            kept.input = "null";
            std.log.warn("events: {s} is over 64 KiB; its hook is not run", .{emitted.name});

            return job_queue.push_failed(ctx.db, kept, too_large);
        }

        const too_large = "Not run: its event is over 64 KiB";

        /// Whether an `on` hook, compiled in or installed, names the event.
        pub fn heard_outside(ctx: *const Ctx, name: []const u8) bool {
            std.debug.assert(name.len > 0);
            std.debug.assert(registry.middleware.len <= sdk.middleware.middleware_max);

            inline for (registry.middleware) |Middleware| {
                const listens = comptime Middleware.stage == .on and !intrinsic(Middleware);

                if (listens and std.mem.eql(u8, Middleware.event, name)) {
                    return true;
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return false;

            return sandboxed.hooked(.event, name);
        }

        /// What the hooks logged on one event, on their plugins' Log as `event:<name>`.
        pub fn keep_lines(
            ctx: *Ctx,
            name: []const u8,
            lines: *sdk.trail.Lines,
        ) error{OutOfMemory}!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(ctx.lines == null or ctx.lines.? == lines);

            const log = registry.log orelse return;

            if (lines.items.items.len == 0) {
                return;
            }

            const call = try std.fmt.allocPrint(ctx.arena, "event:{s}", .{name});

            SDK.raise_failed(ctx, log.lines(ctx, call, lines.kept()));
        }

        /// One queued hook's run (`on:<event>` in `job_queue`), by the jobs' worker: its own
        /// words for why it failed, empty when it ran.
        pub fn run_hook(
            ctx: *Ctx,
            plugin: []const u8,
            job: []const u8,
            input: []const u8,
        ) []const u8 {
            std.debug.assert(plugin.len > 0);
            std.debug.assert(hook_runs.is_hook(job));

            const target = hook_runs.target_of(job) orelse return hook_runs.gone;
            const emitted: Emitted = .{
                .operation_id = ctx.allocate_operation_id(),
                .name = target.event,
                .subject = input,
            };
            const event: Event = .{
                .emitted = emitted,
            };

            inline for (registry.middleware, 0..) |Middleware, index| {
                const listens = comptime Middleware.stage == .on and !intrinsic(Middleware);
                const owner = comptime owner_at(index);

                if (listens and std.mem.eql(u8, owner, plugin) and sdk.hears(Middleware, event)) {
                    if (ordinal_of(index, event) == target.ordinal) {
                        return run_compiled(ctx, Middleware, owner, job, event) catch
                            "OutOfMemory";
                    }
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return hook_runs.gone;
            const hook: sdk.sandboxed_plugins.OnHook = .{
                .plugin = plugin,
                .ordinal = target.ordinal,
            };

            return run_installed(ctx, sandboxed, hook, job, emitted);
        }

        fn run_compiled(
            ctx: *Ctx,
            comptime Middleware: type,
            comptime plugin: []const u8,
            job: []const u8,
            event: Event,
        ) error{OutOfMemory}![]const u8 {
            comptime std.debug.assert(Middleware.stage == .on);
            std.debug.assert(job.len > 0);

            const authoring = ctx.job;

            // The run is the author of what it changes (`job:<plugin>.on:<event>`).
            ctx.job = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ plugin, job });
            defer ctx.job = authoring;

            ctx.failure = null;

            return SDK.run_listener(ctx, Middleware, event);
        }

        fn run_installed(
            ctx: *Ctx,
            sandboxed: *const sdk.sandboxed_plugins.SandboxedPlugins,
            hook: sdk.sandboxed_plugins.OnHook,
            job: []const u8,
            emitted: Emitted,
        ) []const u8 {
            std.debug.assert(hook.plugin.len > 0);
            std.debug.assert(job.len > 0);

            const authoring = ctx.job;

            ctx.job = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ hook.plugin, job }) catch
                return "OutOfMemory";
            defer ctx.job = authoring;

            ctx.failure = null;

            sandboxed.on(ctx, hook, emitted.name, emitted.subject) catch |err| {
                const said = if (ctx.failure) |failure| failure.message else "";

                std.log.warn("plugin {s}: hook on {s}: {t}", .{ hook.plugin, emitted.name, err });

                if (err == error.NotFound) {
                    return hook_runs.gone;
                }

                return if (said.len > 0) said else @errorName(err);
            };

            return "";
        }

        /// The plugin a compiled-in hook belongs to; `core` for core's own.
        fn owner_at(comptime index: u32) []const u8 {
            comptime {
                const owners = registry.middleware_owners;

                std.debug.assert(index < registry.middleware.len);

                if (owners.len == 0 or owners[index].len == 0) {
                    return "core";
                }

                return owners[index];
            }
        }

        /// Which of its plugin's hooks on the event the one at `index` is: how many of the
        /// same plugin's come before it.
        fn ordinal_of(comptime index: u32, event: Event) u32 {
            comptime std.debug.assert(index < registry.middleware.len);
            std.debug.assert(event == .emitted);

            var ordinal: u32 = 0;

            inline for (registry.middleware[0..index], 0..) |Earlier, earlier_index| {
                const listens = comptime Earlier.stage == .on and !intrinsic(Earlier);
                const same = comptime std.mem.eql(u8, owner_at(earlier_index), owner_at(index));

                if (listens and same and sdk.hears(Earlier, event)) {
                    ordinal += 1;
                }
            }

            return ordinal;
        }
    };
}
