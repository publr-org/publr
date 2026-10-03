//! What the SDK asks of the installed plugins installed in a project: the operations they
//! bring and the hooks they hold. The SDK knows nothing of the sandbox behind it; the server
//! hands a `Plugins` to every context it makes, and a context without one has none.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");
const middleware = @import("middleware.zig");

pub const Error = operation.Error;
const Role = @import("../model/role.zig").Role;

/// How deep calls may nest through plugins: a plugin's operation calling another's.
pub const depth_max: u32 = 8;

pub const Stage = enum { before, after, event, display };

pub const Manifest = @import("../model/sandboxed_plugin.zig").Manifest;

/// An operation an installed plugin brings, as the SDK authorizes and runs it.
pub const Operation = struct {
    name: []const u8,
    kind: operation.Kind,
    description: []const u8 = "",
    open: bool = false,
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
        /// The build's roles with the ones plugins declare merged in; null when none do.
        roles: *const fn (context: *anyopaque) ?[]const Role,
        hooked: *const fn (context: *anyopaque, hook_stage: Stage, name: []const u8) bool,
        before: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            input: []const u8,
        ) Error![]const u8,
        after: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            name: []const u8,
            input: []const u8,
            output: []const u8,
        ) Error!void,
        event: *const fn (context: *anyopaque, ctx: *Ctx, event: middleware.Event) void,
        /// Every display hook on `target` (`record.title/variant`) in turn, each handed the
        /// batch the one before it answered; the last answer, as JSON.
        display: *const fn (
            context: *anyopaque,
            ctx: *Ctx,
            target: []const u8,
            input: []const u8,
        ) Error![]const u8,
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

    pub fn roles(sandboxed: *const SandboxedPlugins) ?[]const Role {
        const found = sandboxed.vtable.roles(sandboxed.context);

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

    pub fn display(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        target: []const u8,
        input: []const u8,
    ) Error![]const u8 {
        std.debug.assert(target.len > 0);
        std.debug.assert(input.len > 0);

        return sandboxed.vtable.display(sandboxed.context, ctx, target, input);
    }

    pub fn after(
        sandboxed: *const SandboxedPlugins,
        ctx: *Ctx,
        name: []const u8,
        input: []const u8,
        output: []const u8,
    ) Error!void {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.parent != null);

        return sandboxed.vtable.after(sandboxed.context, ctx, name, input, output);
    }

    pub fn event(sandboxed: *const SandboxedPlugins, ctx: *Ctx, happened: middleware.Event) void {
        std.debug.assert(ctx.next_operation_id > 1);
        std.debug.assert(ctx.now_ms >= 0);

        sandboxed.vtable.event(sandboxed.context, ctx, happened);
    }
};
