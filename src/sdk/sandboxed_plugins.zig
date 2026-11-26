//! What the SDK asks of the installed plugins installed in a project: the operations they
//! bring and the hooks they hold. The SDK knows nothing of the sandbox behind it; the server
//! hands a `Plugins` to every context it makes, and a context without one has none.
const std = @import("std");
const Extended = @import("extended.zig").Extended;
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");
const hooks = @import("hooks.zig");

pub const Error = operation.Error;
const Added = @import("../model/flow.zig").Added;
const Kind = @import("../model/kinds.zig").Kind;

/// How deep calls may nest through plugins: a plugin's operation calling another's.
pub const depth_max: u32 = 8;

pub const Stage = enum { before, after, event, modify };

/// What an installed plugin brings that core runs by name past its jobs: a location rule's
/// `values` and `matches`, a field kind's `validate`, `text` and `editor`, a dimension's
/// `options`.
pub const Part = enum {
    rule_values,
    rule_matches,
    kind_validate,
    kind_text,
    kind_editor,
    dimension_options,
};

pub const Manifest = @import("../model/sandboxed_plugin.zig").Manifest;
const sandboxed_plugin = @import("../model/sandboxed_plugin.zig");
pub const Job = sandboxed_plugin.Job;

/// An operation an installed plugin brings, as the SDK authorizes and runs it.
/// A value on its way to or from an installed plugin's code.
pub const Passed = union(enum) {
    /// JSON text: from the outer edge (REST, the CLI), from storage, or from core's own code.
    json: []const u8,
    /// As a plugin handed it over, kept by the host in one piece
    /// (`server/sandboxed_plugins/held.zig`): it reaches another plugin with no JSON in between.
    laid: []const u8,

    pub fn bytes(passed: Passed) []const u8 {
        return switch (passed) {
            .json, .laid => |held| held,
        };
    }

    /// The same value where its bytes were moved to.
    pub fn moved(passed: Passed, to: []const u8) Passed {
        std.debug.assert(to.len == passed.bytes().len);

        return switch (passed) {
            .json => .{
                .json = to,
            },
            .laid => .{
                .laid = to,
            },
        };
    }
};

/// How one item of a batch a hook ran over ended: what the hook handed back, or the error
/// it ended with and the words it refused with.
pub const Outcome = struct {
    passed: Passed = .{
        .json = "{}",
    },
    failed: ?Error = null,
    message: []const u8 = "",
};

/// What a value a plugin handed over is, when it is written as JSON: what it sent an
/// operation (inside its values a field holding nothing is left out), or what it answered.
pub const Form = enum { request, answer };

pub const Operation = struct {
    name: []const u8,
    kind: operation.Kind,
    description: []const u8 = "",
    open: bool = false,
    /// Made with `publr.operation.define`: whether callers without credentials may call it;
    /// null for one declared part by part.
    untrusted_callers: ?bool = null,
    answer: ?@import("../model/caller_answer.zig").Answer = null,
    /// Its own rate limit, calls a minute per caller; 0 for none.
    limit: u32 = 0,
    /// It destroys what cannot be had back (`.destructive`).
    destructive: bool = false,
    /// Its input's fields, for an adapter that reads flags or a form into JSON.
    fields: []const @import("../model/sandboxed_plugin.zig").Field = &.{},
    /// Its `--help`, as the build rendered it.
    help: []const u8 = "",
    /// The shape it takes: which of its fields are references to read before it runs.
    input: []const @import("../model/contract.zig").Node = &.{},
    /// Input fields never written to the logs.
    secret: []const []const u8 = &.{},
    /// What every caller is told when it is on its way out; empty when it is not.
    deprecated: []const u8 = "",
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
    /// The plugin's source the module carries, JSON (`publr.source`); empty for none.
    source: []const u8 = "",
    /// Why the sandbox will not load the module, such as an import it does not give; empty
    /// when it loads.
    refused: []const u8 = "",
};

/// A site component a plugin brings (`components/<Name>.publr`): apps import it as
/// `plugin:<plugin>/<name>`.
pub const Component = struct {
    plugin: []const u8,
    name: []const u8,
    text: []const u8,
};

/// A plugin's interactive components (`interactive/*.ptsx`) as a place with no compiler draws
/// them: the components a page may place (JSON, `[{ name, props, takes_children }]`), their
/// render as one JavaScript program, the browser's stores and the classes the sheet needs.
pub const Interactive = struct {
    plugin: []const u8,
    components: []const u8,
    render: []const u8,
    browser: []const u8,
    classes: []const u8,
};

/// What core tells of a request as a top-level call or an HTTP request ends.
pub const Counted = struct {
    /// What ran: an operation's name, a request's path. The first one told names the request.
    label: []const u8 = "",
    /// The call scratch at its fullest, in bytes.
    scratch_bytes: u64 = 0,
    /// The request's arena as it stood, in bytes.
    arena_bytes: u64 = 0,
    /// The most compiled-in plugins' work held at once (`plugin_memory.zig`), in bytes.
    plugin_bytes: u64 = 0,
    /// Pieces of compiled-in plugins' work begun: operations, hooks, modifiers, scopes.
    plugin_work: u32 = 0,
    /// How much compiled-in plugins' work may hold at once, in bytes.
    plugin_bytes_max: u64 = 0,
    /// The largest a compiled-in plugin's SDK collection held, and which.
    largest_name: []const u8 = "",
    largest_bytes: u64 = 0,
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
            input: Passed,
        ) Error!Passed,
        /// A value a plugin handed over (`Passed.laid`) as JSON text, in `arena`.
        json_of: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            piece: []const u8,
            form: Form,
        ) Error![]const u8,
        /// The text of field `name` of a value a plugin handed over; null when it has none.
        text_field: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            piece: []const u8,
            name: []const u8,
        ) ?[]const u8,
        /// The build's added statuses with the ones plugins are granted; null when none are.
        statuses: *const fn (context: *anyopaque) ?[]const Added,
        /// The build's field kinds with the loaded plugins'; null when they bring none.
        kinds: *const fn (context: *anyopaque) ?[]const Kind,
        /// The browser half of `plugin`'s views (its `publr.stores`); null when it has none.
        stores: *const fn (context: *anyopaque, plugin: []const u8) ?[]const u8,
        /// Every loaded plugin's site components, in load order.
        components: *const fn (context: *anyopaque) []const Component,
        /// Every loaded plugin's interactive components, in load order.
        interactive: *const fn (context: *anyopaque) []const Interactive,
        /// Whether `plugin`'s remote `name` is off: its plugin is not there, or it does not
        /// fit what that plugin is now.
        remote_off: *const fn (context: *anyopaque, plugin: []const u8, name: []const u8) bool,
        /// Whether the loaded plugin `plugin` was granted the permission `key`.
        holds: *const fn (context: *anyopaque, plugin: []const u8, key: []const u8) bool,
        hooked: *const fn (context: *anyopaque, hook_stage: Stage, name: []const u8) bool,
        before: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            input: Passed,
        ) Error!Passed,
        /// `extended` takes the fields each hook adds to a list read's rows.
        after: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            input: Passed,
            output: Passed,
            extended: ?Extended,
        ) Error!void,
        event: *const fn (context: *anyopaque, ctx: *Ctx, event: hooks.Event) void,
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
        /// Every installed modifier whose name takes `target` (`variant.title`) in turn over
        /// the values `input` holds laid out (`server/sandboxed_plugins/applied.zig`), each
        /// handed what the one before left; the values afterwards, held the same way.
        modify: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            target: []const u8,
            input: []const u8,
        ) Error![]const u8,
        /// A computed field worked out: `owner`'s own modifier of exactly `name`
        /// (`computed.<record>.<field>`) over the values `input` holds laid out.
        compute: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            owner: []const u8,
            name: []const u8,
            input: []const u8,
        ) Error![]const u8,
        /// The installed `on` hooks that hear the event `name`, in the order they run.
        on_hooks: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            name: []const u8,
        ) Error![]const OnHook,
        /// What installed `on` hook `hook` on event `name` waits in the queue with: of
        /// `payload`, the fields its own type names, as JSON in `arena`.
        on_input: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            hook: OnHook,
            name: []const u8,
            payload: Passed,
        ) Error![]const u8,
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
        /// `before`, and `after`, over many inputs at once: each plugin's hook is entered
        /// once for all of them, and `outcomes` takes how each input ended.
        before_many: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            inputs: []const Passed,
            outcomes: []Outcome,
        ) Error!void,
        after_many: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            inputs: []const Passed,
            outputs: []const Passed,
            outcomes: []Outcome,
        ) Error!void,
        /// A request begins, and ends: between the two each plugin is instantiated at most
        /// once, and no instance is left when the last open one ends.
        request_begin: *const fn (context: *anyopaque) void,
        request_end: *const fn (context: *anyopaque) void,
        /// What core's own memory stood at in the open request, and what ran.
        counted: *const fn (context: *anyopaque, told: Counted) void,
    };

    /// Every installed `before` hook on `name` over `inputs`, each plugin's hook entered
    /// once for all of them: `outcomes` takes each input as the hooks left it, or how it
    /// was refused.
    pub fn before_many(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        name: []const u8,
        inputs: []const Passed,
        outcomes: []Outcome,
    ) Error!void {
        std.debug.assert(name.len > 0);
        std.debug.assert(inputs.len == outcomes.len);

        return sandboxed.vtable.before_many(sandboxed.context, ctx, name, inputs, outcomes);
    }

    /// Every installed `after` hook on `name` over `inputs` and what the write made of each.
    pub fn after_many(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        name: []const u8,
        inputs: []const Passed,
        outputs: []const Passed,
        outcomes: []Outcome,
    ) Error!void {
        std.debug.assert(name.len > 0);
        std.debug.assert(inputs.len == outputs.len and inputs.len == outcomes.len);

        return sandboxed.vtable.after_many(
            sandboxed.context,
            ctx,
            name,
            inputs,
            outputs,
            outcomes,
        );
    }

    /// A request begins on the installed plugins: an HTTP request, a top-level call, a
    /// queued run. Every `request_begin` is followed by its `request_end`; they nest.
    pub fn request_begin(sandboxed: *const SandboxedPlugins) void {
        sandboxed.vtable.request_begin(sandboxed.context);
    }

    /// The request `request_begin` opened ends: with the last one open, every plugin's
    /// instance goes, and what it held in memory with it.
    pub fn request_end(sandboxed: *const SandboxedPlugins) void {
        sandboxed.vtable.request_end(sandboxed.context);
    }

    /// Core tells what ran in the open request and where its own memory stood: kept with
    /// what the plugins cost, for the operator's counters. Nothing a plugin reads.
    pub fn counted(sandboxed: *const SandboxedPlugins, told: Counted) void {
        sandboxed.vtable.counted(sandboxed.context, told);
    }

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
        input: Passed,
    ) Error!Passed {
        std.debug.assert(found.name.len > 0);
        std.debug.assert(ctx.parent != null);

        return sandboxed.vtable.run(sandboxed.context, ctx, found, input);
    }

    /// `passed` as JSON text: as it is when it is JSON already, else written in `arena`.
    pub fn json_of(
        sandboxed: *const SandboxedPlugins,
        arena: std.mem.Allocator,
        passed: Passed,
        form: Form,
    ) Error![]const u8 {
        std.debug.assert(passed.bytes().len > 0);

        return switch (passed) {
            .json => |text| text,
            .laid => |piece| sandboxed.vtable.json_of(sandboxed.context, arena, piece, form),
        };
    }

    /// The text of field `name` of a value a plugin handed over; null when it has none, or
    /// when the value is JSON text.
    pub fn text_field(
        sandboxed: *const SandboxedPlugins,
        arena: std.mem.Allocator,
        passed: Passed,
        name: []const u8,
    ) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return switch (passed) {
            .json => null,
            .laid => |piece| sandboxed.vtable.text_field(sandboxed.context, arena, piece, name),
        };
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

    /// Whether the loaded plugin `plugin` was granted the permission `key`.
    pub fn holds(sandboxed: *const SandboxedPlugins, plugin: []const u8, key: []const u8) bool {
        std.debug.assert(plugin.len > 0);
        std.debug.assert(key.len > 0);

        return sandboxed.vtable.holds(sandboxed.context, plugin, key);
    }

    pub fn kinds(sandboxed: *const SandboxedPlugins) ?[]const Kind {
        const known = sandboxed.vtable.kinds(sandboxed.context) orelse return null;

        std.debug.assert(known.len > 0);

        return known;
    }

    /// The browser code `plugin`'s views run in its frame; null when it brings none.
    pub fn stores(sandboxed: *const SandboxedPlugins, plugin: []const u8) ?[]const u8 {
        std.debug.assert(plugin.len > 0);

        const code = sandboxed.vtable.stores(sandboxed.context, plugin) orelse return null;

        std.debug.assert(code.len > 0);

        return code;
    }

    /// Every loaded plugin's site components (`components/<Name>.publr`).
    pub fn components(sandboxed: *const SandboxedPlugins) []const Component {
        const found = sandboxed.vtable.components(sandboxed.context);

        std.debug.assert(found.len <= 1 << 16);

        return found;
    }

    /// Every loaded plugin's interactive components (`interactive/*.ptsx`).
    pub fn interactive(sandboxed: *const SandboxedPlugins) []const Interactive {
        const found = sandboxed.vtable.interactive(sandboxed.context);

        std.debug.assert(found.len <= 1 << 16);

        return found;
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
        input: Passed,
    ) Error!Passed {
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

    pub fn compute(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        owner: []const u8,
        name: []const u8,
        input: []const u8,
    ) Error![]const u8 {
        std.debug.assert(owner.len > 0);
        std.debug.assert(input.len > 0);

        return sandboxed.vtable.compute(sandboxed.context, ctx, owner, name, input);
    }

    pub fn after(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        name: []const u8,
        input: Passed,
        output: Passed,
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

    /// The JSON `hook` waits in the queue with for event `name`: what its type names of
    /// `payload`, so an event larger than a queued run may be still reaches a hook that
    /// reads a few of its fields.
    pub fn on_input(
        sandboxed: *const SandboxedPlugins,
        arena: std.mem.Allocator,
        hook: OnHook,
        name: []const u8,
        payload: Passed,
    ) Error![]const u8 {
        std.debug.assert(hook.plugin.len > 0);
        std.debug.assert(payload.bytes().len > 0);

        return sandboxed.vtable.on_input(sandboxed.context, arena, hook, name, payload);
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

    pub fn event(sandboxed: *const SandboxedPlugins, ctx: *Ctx, happened: hooks.Event) void {
        std.debug.assert(ctx.next_operation_id > 1);
        std.debug.assert(ctx.now_ms >= 0);

        sandboxed.vtable.event(sandboxed.context, ctx, happened);
    }
};
