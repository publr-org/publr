//! What the SDK asks of the installed plugins installed in a project: the operations they
//! bring and the hooks they hold. The SDK knows nothing of the sandbox behind it; the server
//! hands a `Plugins` to every context it makes, and a context without one has none.
const std = @import("std");
const Extended = @import("extended.zig").Extended;
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");
const middleware = @import("middleware.zig");

pub const Error = operation.Error;
const Role = @import("../model/role.zig").Role;
const Added = @import("../model/flow.zig").Added;
const Kind = @import("../model/kinds.zig").Kind;

/// How deep calls may nest through plugins: a plugin's operation calling another's.
pub const depth_max: u32 = 8;

pub const Stage = enum { before, after, event, modify };

/// What an installed plugin brings that core runs by name past its jobs: a location rule's
/// `values` and `matches`, a field kind's `validate` and `text`.
pub const Part = enum { rule_values, rule_matches, kind_validate, kind_text };

pub const Manifest = @import("../model/sandboxed_plugin.zig").Manifest;
const sandboxed_plugin = @import("../model/sandboxed_plugin.zig");
pub const Job = sandboxed_plugin.Job;

/// An operation an installed plugin brings, as the SDK authorizes and runs it.
pub const Operation = struct {
    name: []const u8,
    kind: operation.Kind,
    description: []const u8 = "",
    open: bool = false,
    /// Any site may call it through an app (`public = true`).
    public: bool = false,
    /// Made with `publr.operation.define`: whether callers without credentials may call it;
    /// null for one declared part by part.
    untrusted_callers: ?bool = null,
    answer: ?@import("../model/caller_answer.zig").Answer = null,
    /// Its own rate limit, calls a minute per caller; 0 for none.
    limit: u32 = 0,
    /// Its input's fields, for an adapter that reads flags or a form into JSON.
    fields: []const @import("../model/sandboxed_plugin.zig").Field = &.{},
    /// Its `--help`, as the build rendered it.
    help: []const u8 = "",
    /// The shape it takes: which of its fields are references to read before it runs.
    input: []const @import("../model/contract.zig").Node = &.{},
    /// Input fields never written to the logs.
    secret: []const []const u8 = &.{},
    /// Which plugin, and which of its entries, runs it: the host's own numbering.
    sandboxed_plugin: u32,
    entry: u32,
};

/// An installed `on` hook hearing an event: its plugin, and which of that plugin's hooks on
/// the event it is (0 for its first).
pub const OnHook = struct {
    plugin: []const u8,
    ordinal: u32,
};

/// A module read and checked, its file stored: what installing and updating work from.
pub const Staged = struct {
    hash: []const u8,
    /// The manifest as the module carries it, JSON.
    manifest: []const u8,
};

pub const SandboxedPlugins = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        receive: *const fn (
            context: *anyopaque,
            file: []const u8,
            offset: u64,
            bytes: []const u8,
            last: bool,
        ) Error!u64,
        consume: *const fn (context: *anyopaque, file: []const u8) void,
        stage: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            file: []const u8,
            anywhere: bool,
        ) Error!Staged,
        find: *const fn (context: *anyopaque, name: []const u8) ?Operation,
        /// Every loaded plugin's manifest: its namespaces and operations, for help.
        manifests: *const fn (context: *anyopaque) []const Manifest,
        run: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            found: Operation,
            input: []const u8,
        ) Error![]const u8,
        /// The build's added statuses with the ones plugins are granted; null when none are.
        statuses: *const fn (context: *anyopaque) ?[]const Added,
        /// The build's field kinds with the loaded plugins'; null when they bring none.
        kinds: *const fn (context: *anyopaque) ?[]const Kind,
        /// Whether `plugin`'s remote `name` is off: its plugin is not there, or it does not
        /// fit what that plugin is now.
        remote_off: *const fn (context: *anyopaque, plugin: []const u8, name: []const u8) bool,
        hooked: *const fn (context: *anyopaque, hook_stage: Stage, name: []const u8) bool,
        before: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            input: []const u8,
        ) Error![]const u8,
        /// `extended` takes the fields each hook adds to a list read's rows.
        after: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            input: []const u8,
            output: []const u8,
            extended: ?Extended,
        ) Error!void,
        event: *const fn (context: *anyopaque, ctx: *Ctx, event: middleware.Event) void,
        /// Runs operation `name` as the installed plugin `plugin`, on behalf of whoever calls:
        /// each check gets the narrower of the plugin's grants and their roles. What a plugin's
        /// frame asks of the admin beyond its own operations (a GROQ read).
        call_as: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            plugin: []const u8,
            name: []const u8,
            input: []const u8,
        ) Error![]const u8,
        /// Every installed modifier whose name takes `target` (`variant.title`) in turn, each
        /// handed the batch the one before it answered; the last answer, as JSON.
        modify: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            target: []const u8,
            input: []const u8,
        ) Error![]const u8,
        /// The installed `on` hooks that hear the event `name`, in the order they run.
        on_hooks: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            name: []const u8,
        ) Error![]const OnHook,
        /// Runs one installed `on` hook on a queued event, its payload as `subject`.
        on: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            hook: OnHook,
            name: []const u8,
            subject: []const u8,
        ) Error!void,
        /// Runs `part` of what an installed plugin brings, by its name under the plugin
        /// (`sampler.has_motto`), as the plugin: its answer, JSON.
        extra: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            part: Part,
            name: []const u8,
            input: []const u8,
        ) Error![]const u8,
        /// Runs an installed plugin's queued job; `last`: its final attempt.
        job: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            plugin: []const u8,
            name: []const u8,
            input: []const u8,
            last: bool,
        ) Error!void,
    };

    /// Writes one piece of an upload into the uploads folder; answers how much it holds.
    pub fn receive(
        sandboxed: *const SandboxedPlugins,
        file: []const u8,
        offset: u64,
        bytes: []const u8,
        last: bool,
    ) Error!u64 {
        std.debug.assert(file.len > 0);
        std.debug.assert(bytes.len > 0 or last);

        return sandboxed.vtable.receive(sandboxed.context, file, offset, bytes, last);
    }

    /// Removes an upload once it is installed: `file` in the uploads folder, if it is there.
    pub fn consume(sandboxed: *const SandboxedPlugins, file: []const u8) void {
        std.debug.assert(file.len > 0);
        std.debug.assert(file.len <= std.fs.max_path_bytes);

        sandboxed.vtable.consume(sandboxed.context, file);
    }

    /// Reads `file` (a name in the uploads folder, or any path when `anywhere`), checks it is
    /// a module the sandbox loads and carries a manifest, and stores it by its hash.
    pub fn stage(
        sandboxed: *const SandboxedPlugins,
        arena: std.mem.Allocator,
        file: []const u8,
        anywhere: bool,
    ) Error!Staged {
        std.debug.assert(file.len > 0);
        std.debug.assert(file.len <= std.fs.max_path_bytes);

        return sandboxed.vtable.stage(sandboxed.context, arena, file, anywhere);
    }

    pub fn manifests(sandboxed: *const SandboxedPlugins) []const Manifest {
        const found = sandboxed.vtable.manifests(sandboxed.context);

        std.debug.assert(found.len <= 1 << 16);

        return found;
    }

    pub fn find(sandboxed: *const SandboxedPlugins, name: []const u8) ?Operation {
        std.debug.assert(name.len > 0);
        std.debug.assert(name.len <= operation.name_len_max);

        return sandboxed.vtable.find(sandboxed.context, name);
    }

    pub fn run(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        found: Operation,
        input: []const u8,
    ) Error![]const u8 {
        std.debug.assert(found.name.len > 0);
        std.debug.assert(ctx.parent != null);

        return sandboxed.vtable.run(sandboxed.context, ctx, found, input);
    }

    pub fn remote_off(
        sandboxed: *const SandboxedPlugins,
        plugin: []const u8,
        name: []const u8,
    ) bool {
        std.debug.assert(plugin.len > 0);
        std.debug.assert(name.len > 0);

        return sandboxed.vtable.remote_off(sandboxed.context, plugin, name);
    }

    pub fn kinds(sandboxed: *const SandboxedPlugins) ?[]const Kind {
        const known = sandboxed.vtable.kinds(sandboxed.context) orelse return null;

        std.debug.assert(known.len > 0);

        return known;
    }

    pub fn statuses(sandboxed: *const SandboxedPlugins) ?[]const Added {
        const found = sandboxed.vtable.statuses(sandboxed.context);

        std.debug.assert(found == null or found.?.len > 0);

        return found;
    }

    pub fn hooked(sandboxed: *const SandboxedPlugins, hook_stage: Stage, name: []const u8) bool {
        std.debug.assert(name.len > 0);
        std.debug.assert(name.len <= operation.name_len_max);

        return sandboxed.vtable.hooked(sandboxed.context, hook_stage, name);
    }

    pub fn before(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        name: []const u8,
        input: []const u8,
    ) Error![]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.parent != null);

        return sandboxed.vtable.before(sandboxed.context, ctx, name, input);
    }

    /// `name` run as the installed plugin `plugin` for whoever calls; not found when no
    /// installed plugin has that name.
    pub fn call_as(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        plugin: []const u8,
        name: []const u8,
        input: []const u8,
    ) Error![]const u8 {
        std.debug.assert(plugin.len > 0);
        std.debug.assert(name.len > 0);

        return sandboxed.vtable.call_as(sandboxed.context, ctx, plugin, name, input);
    }

    pub fn modify(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        target: []const u8,
        input: []const u8,
    ) Error![]const u8 {
        std.debug.assert(target.len > 0);
        std.debug.assert(input.len > 0);

        return sandboxed.vtable.modify(sandboxed.context, ctx, target, input);
    }

    pub fn after(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        name: []const u8,
        input: []const u8,
        output: []const u8,
        extended: ?Extended,
    ) Error!void {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.parent != null);

        return sandboxed.vtable.after(sandboxed.context, ctx, name, input, output, extended);
    }

    pub fn job(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        plugin: []const u8,
        name: []const u8,
        input: []const u8,
        last: bool,
    ) Error!void {
        std.debug.assert(plugin.len > 0);
        std.debug.assert(name.len > 0);

        return sandboxed.vtable.job(sandboxed.context, ctx, plugin, name, input, last);
    }

    pub fn extra(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        part: Part,
        name: []const u8,
        input: []const u8,
    ) Error![]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(input.len > 0);

        if (ctx.plugin_depth >= depth_max) {
            return error.Unavailable;
        }

        ctx.plugin_depth += 1;
        defer ctx.plugin_depth -= 1;

        return sandboxed.vtable.extra(sandboxed.context, ctx, part, name, input);
    }

    /// The job `plugin` declares as `name`; null when no installed plugin does.
    pub fn job_of(
        sandboxed: *const SandboxedPlugins,
        plugin: []const u8,
        name: []const u8,
    ) ?sandboxed_plugin.Job {
        std.debug.assert(plugin.len > 0);
        std.debug.assert(name.len > 0);

        for (sandboxed.manifests()) |manifest| {
            if (!std.mem.eql(u8, manifest.name, plugin)) {
                continue;
            }

            for (manifest.jobs) |declared| {
                if (std.mem.eql(u8, declared.name, name)) {
                    return declared;
                }
            }
        }

        return null;
    }

    pub fn on_hooks(
        sandboxed: *const SandboxedPlugins,
        arena: std.mem.Allocator,
        name: []const u8,
    ) Error![]const OnHook {
        std.debug.assert(name.len > 0);
        std.debug.assert(depth_max > 0);

        return sandboxed.vtable.on_hooks(sandboxed.context, arena, name);
    }

    pub fn on(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        hook: OnHook,
        name: []const u8,
        subject: []const u8,
    ) Error!void {
        std.debug.assert(hook.plugin.len > 0);
        std.debug.assert(name.len > 0);

        return sandboxed.vtable.on(sandboxed.context, ctx, hook, name, subject);
    }

    pub fn event(sandboxed: *const SandboxedPlugins, ctx: *Ctx, happened: middleware.Event) void {
        std.debug.assert(ctx.next_operation_id > 1);
        std.debug.assert(ctx.now_ms >= 0);

        sandboxed.vtable.event(sandboxed.context, ctx, happened);
    }
};
