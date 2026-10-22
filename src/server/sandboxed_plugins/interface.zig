//! The `sdk.plugins.Plugins` the host hands every context: finding a plugin's operation,
//! running it, running the hooks plugins hold, and reading a module to install.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const files_module = @import("files.zig");
const invoke_module = @import("invoke.zig");
const Loaded = @import("loaded.zig").Loaded;
const sandboxed_plugins = @import("../sandboxed_plugins.zig");

const Host = sandboxed_plugins.Host;
const Target = sandboxed_plugins.Target;
const hash_len = files_module.hash_len;
const sandboxed_plugins_max = sandboxed_plugins.sandboxed_plugins_max;

pub const vtable: sdk.sandboxed_plugins.SandboxedPlugins.VTable = .{
    .receive = &receive,
    .consume = &consume,
    .stage = &stage,
    .statuses = &statuses_of,
    .remote_off = &remote_off,
    .find = &find,
    .manifests = &manifests,
    .run = &run,
    .hooked = &hooked,
    .before = &before,
    .after = &after,
    .event = &event,
    .on_hooks = &on_hooks,
    .on = &on,
    .modify = &modify,
    .call_as = &call_as,
    .job = &job,
};

fn host_of(context: *anyopaque) *Host {
    return @ptrCast(@alignCast(context));
}

fn statuses_of(context: *anyopaque) ?[]const model.flow.Added {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    return host.statuses;
}

fn remote_off(context: *anyopaque, plugin: []const u8, name: []const u8) bool {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    return host.remote_off(plugin, name);
}

fn receive(
    context: *anyopaque,
    file: []const u8,
    offset: u64,
    bytes: []const u8,
    last: bool,
) sdk.Error!u64 {
    const host = host_of(context);

    std.debug.assert(file.len > 0);

    const module = std.mem.endsWith(u8, file, ".wasm");

    if (!module or !files_module.valid_upload(file)) {
        return error.Invalid;
    }

    return host.files.receive(file, offset, bytes, last) catch |err| switch (err) {
        error.OutOfOrder => error.Conflict,
        error.FileNotFound => error.Conflict,
        else => error.Unavailable,
    };
}

fn consume(context: *anyopaque, file: []const u8) void {
    const host = host_of(context);

    std.debug.assert(file.len > 0);

    if (files_module.valid_upload(file)) {
        host.files.remove_upload(file);
    }
}

fn stage(
    context: *anyopaque,
    arena: std.mem.Allocator,
    file: []const u8,
    anywhere: bool,
) sdk.Error!sdk.sandboxed_plugins.Staged {
    const host = host_of(context);

    std.debug.assert(file.len > 0);

    if (!anywhere and !files_module.valid_upload(file)) {
        return error.Invalid;
    }

    const path = if (anywhere) file else std.fmt.allocPrint(arena, "{s}/{s}", .{
        files_module.uploads_dir,
        file,
    }) catch return error.OutOfMemory;
    const bytes = host.files.read_any(host.gpa, path, anywhere) catch return error.NotFound;
    defer host.gpa.free(bytes);

    const section_name = @import("../../sdk/plugin/manifest.zig").section_name;
    const manifest = (wasm.section.find(bytes, section_name) catch {
        return error.Invalid;
    }) orelse return error.Invalid;

    try check_loads(host, bytes);

    var hash: [hash_len]u8 = undefined;

    host.files.store(bytes, &hash) catch return error.Unavailable;

    return .{
        .hash = arena.dupe(u8, &hash) catch return error.OutOfMemory,
        .manifest = arena.dupe(u8, manifest) catch return error.OutOfMemory,
    };
}

/// Whether the sandbox loads the module: valid, and importing only what the host gives.
fn check_loads(host: *Host, bytes: []const u8) sdk.Error!void {
    std.debug.assert(bytes.len > 0);

    const copy = host.gpa.dupe(u8, bytes) catch return error.OutOfMemory;
    defer host.gpa.free(copy);

    var problem: wasm.Problem = .{};
    var module = wasm.Module.load(&host.runtime, copy, &problem) catch {
        std.log.warn("plugins: the module does not load: {s}", .{problem.text()});
        return error.Invalid;
    };

    module.unload();
}

fn manifests(context: *anyopaque) []const sdk.sandboxed_plugins.Manifest {
    const host = host_of(context);

    std.debug.assert(host.manifests.len <= host.loaded.items.len);

    return host.manifests;
}

fn find(context: *anyopaque, name: []const u8) ?sdk.sandboxed_plugins.Operation {
    const host = host_of(context);
    const target = host.operations.get(name) orelse return null;
    const loaded = &host.loaded.items[target.sandboxed_plugin];
    const declared = loaded.manifest.operations[target.entry];

    std.debug.assert(std.mem.eql(u8, declared.name, name));

    return .{
        .name = declared.name,
        .kind = if (declared.kind == .read) .read else .write,
        .description = declared.description,
        .open = declared.open,
        .public = declared.public,
        .untrusted_callers = declared.untrusted_callers,
        .limit = declared.limit,
        .answer = declared.answer,
        .fields = declared.fields,
        .help = declared.help,
        .input = declared.input,
        .secret = declared.secret,
        .deprecated = declared.deprecated,
        .sandboxed_plugin = target.sandboxed_plugin,
        .entry = target.entry,
    };
}

fn run(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    found: sdk.sandboxed_plugins.Operation,
    input: []const u8,
) sdk.Error![]const u8 {
    const host = host_of(context);
    const loaded = &host.loaded.items[found.sandboxed_plugin];

    std.debug.assert(found.name.len > 0);

    var access = try access_of(loaded, ctx);

    return invoke_module.invoke(loaded, ctx, &access, found.entry, input);
}

fn call_as(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    plugin: []const u8,
    name: []const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    const host = host_of(context);
    const loaded = host.find_loaded(plugin) orelse return error.NotFound;

    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.caller != .plugin);

    var access = try access_of(loaded, ctx);
    const saved = ctx.caller;

    ctx.caller = .{
        .plugin = .{
            .name = loaded.name(),
            .capabilities = &.{},
            .on_behalf_of = saved.user_id(),
            .access = &access,
            .roles = saved.roles(),
        },
    };
    defer ctx.caller = saved;

    return @import("../registry.zig").SDK.call_json(ctx, name, input);
}

/// Runs installed plugin `plugin`'s job `name` as the plugin; `last` lets its `.on_failure`
/// hear a failure that ends it.
fn job(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    plugin: []const u8,
    name: []const u8,
    input: []const u8,
    last: bool,
) sdk.Error!void {
    const host = host_of(context);
    const loaded = host.find_loaded(plugin) orelse return error.NotFound;
    const manifest = loaded.manifest;

    std.debug.assert(name.len > 0);
    std.debug.assert(input.len > 0);

    var found: ?usize = null;

    for (manifest.jobs, 0..) |declared, index| {
        if (std.mem.eql(u8, declared.name, name)) {
            found = index;
        }
    }

    const position = found orelse return error.NotFound;
    const entry = manifest.operations.len + manifest.hooks.len + position;
    const both = std.fmt.allocPrint(ctx.arena, "{{\"last\":{},\"in\":{s}}}", .{
        last,
        input,
    }) catch return error.OutOfMemory;
    var access = try access_of(loaded, ctx);

    _ = try invoke_module.invoke_spread(loaded, ctx, &access, @intCast(entry), both);
}

fn hooked(context: *anyopaque, hook_stage: sdk.sandboxed_plugins.Stage, name: []const u8) bool {
    const host = host_of(context);

    std.debug.assert(name.len > 0);

    if (host.hooks.count() == 0) {
        return false;
    }

    if (hook_stage == .modify) {
        var buffer: [64]Target = undefined;

        return modifiers_of(host, name, &buffer).len > 0;
    }

    var key_buffer: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{t}:{s}", .{ hook_stage, name }) catch return false;

    return host.hooks.contains(key);
}

fn targets_of(
    host: *Host,
    hook_stage: sdk.sandboxed_plugins.Stage,
    name: []const u8,
) []const Target {
    var key_buffer: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{t}:{s}", .{ hook_stage, name }) catch return &.{};

    return host.hooks.get(key) orelse &.{};
}

fn before(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    const host = host_of(context);
    var current = input;

    for (targets_of(host, .before, name)) |target| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];
        var access = try access_of(loaded, ctx);

        current = try invoke_module.invoke(loaded, ctx, &access, target.entry, current);
    }

    return current;
}

/// The installed modifiers whose name takes `name` (`*.title` takes `variant.title`), in the
/// order the plugins were loaded, then declared.
fn modifiers_of(host: *Host, name: []const u8, buffer: []Target) []const Target {
    std.debug.assert(name.len > 0);
    std.debug.assert(buffer.len > 0);

    const prefix = "modify:";
    var found: u32 = 0;
    var entries = host.hooks.iterator();

    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;

        if (!std.mem.startsWith(u8, key, prefix)) {
            continue;
        }

        if (!sdk.mods.matches(key[prefix.len..], name)) {
            continue;
        }

        for (entry.value_ptr.*) |target| {
            if (found < buffer.len) {
                buffer[found] = target;
                found += 1;
            }
        }
    }

    const listed = buffer[0..found];

    std.mem.sort(Target, listed, {}, struct {
        fn before(_: void, left: Target, right: Target) bool {
            if (left.sandboxed_plugin != right.sandboxed_plugin) {
                return left.sandboxed_plugin < right.sandboxed_plugin;
            }

            return left.entry < right.entry;
        }
    }.before);

    return listed;
}

fn modify(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    const host = host_of(context);
    var current = input;
    var buffer: [64]Target = undefined;

    std.debug.assert(name.len > 0);

    for (modifiers_of(host, name, &buffer)) |found| {
        const loaded = &host.loaded.items[found.sandboxed_plugin];
        var access = try access_of(loaded, ctx);

        current = try invoke_module.invoke(loaded, ctx, &access, found.entry, current);
    }

    return current;
}

fn after(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    input: []const u8,
    output: []const u8,
) sdk.Error!void {
    const host = host_of(context);
    const format = "{{\"in\":{s},\"out\":{s}}}";
    const both = std.fmt.allocPrint(ctx.arena, format, .{ input, output }) catch {
        return error.OutOfMemory;
    };

    for (targets_of(host, .after, name)) |target| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];
        var access = try access_of(loaded, ctx);

        _ = try invoke_after(loaded, ctx, &access, target.entry, both);
    }
}

/// An `after` hook reads `in` and `out` beside the envelope's own fields.
fn invoke_after(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    both: []const u8,
) sdk.Error![]const u8 {
    std.debug.assert(both.len > 2);
    std.debug.assert(loaded.name().len > 0);

    return invoke_module.invoke_spread(loaded, ctx, access, entry, both);
}

/// An operation's end reloads the plugins when an administrator changed them. A queued
/// event reaches the `on` hooks one by one, through `on_hooks` and `on`.
fn event(context: *anyopaque, ctx: *sdk.Ctx, happened: sdk.Event) void {
    const host = host_of(context);

    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(happened != .emitted);

    if (changed_plugins(happened) and ctx.db.transaction_depth == 0) {
        host.load_all(ctx.db) catch |err| std.log.err("plugins: reload failed: {t}", .{err});
    }
}

const OnHook = sdk.sandboxed_plugins.OnHook;

fn on_hooks(
    context: *anyopaque,
    arena: std.mem.Allocator,
    name: []const u8,
) sdk.Error![]const OnHook {
    const host = host_of(context);

    std.debug.assert(name.len > 0);

    if (host.hooks.count() == 0) {
        return &.{};
    }

    const targets = targets_of(host, .event, name);
    const found = arena.alloc(OnHook, targets.len) catch return error.OutOfMemory;

    for (targets, found, 0..) |target, *hook, index| {
        hook.* = .{
            .plugin = host.loaded.items[target.sandboxed_plugin].name(),
            .ordinal = ordinal_of(targets[0..index], target),
        };
    }

    std.debug.assert(found.len == targets.len);

    return found;
}

/// Which of its plugin's hooks on the event `target` is: how many came before it.
fn ordinal_of(earlier: []const Target, target: Target) u32 {
    std.debug.assert(target.sandboxed_plugin < sandboxed_plugins_max);

    var ordinal: u32 = 0;

    for (earlier) |before_it| {
        if (before_it.sandboxed_plugin == target.sandboxed_plugin) {
            ordinal += 1;
        }
    }

    return ordinal;
}

fn on(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    hook: OnHook,
    name: []const u8,
    subject: []const u8,
) sdk.Error!void {
    const host = host_of(context);

    std.debug.assert(hook.plugin.len > 0);
    std.debug.assert(name.len > 0);

    if (ctx.plugin_depth >= sdk.sandboxed_plugins.depth_max) {
        return error.Unavailable;
    }

    const targets = targets_of(host, .event, name);

    for (targets, 0..) |target, index| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];
        const same = std.mem.eql(u8, loaded.name(), hook.plugin) and
            ordinal_of(targets[0..index], target) == hook.ordinal;

        if (same) {
            const input = try payload_json(ctx, subject);
            var access = try access_of(loaded, ctx);

            ctx.plugin_depth += 1;
            defer ctx.plugin_depth -= 1;

            _ = try invoke_module.invoke(loaded, ctx, &access, target.entry, input);

            return;
        }
    }

    return error.NotFound;
}

/// Whether an administrator just changed the plugins: they are loaded again once it commits.
fn changed_plugins(happened: sdk.Event) bool {
    const completed = switch (happened) {
        .completed => |completed| completed,
        else => return false,
    };
    const name = completed.operation_name;

    std.debug.assert(name.len > 0);

    // Listing, reading and adding change nothing that runs: an added module is not active,
    // and a next version waits until it is applied.
    const unchanged = [_][]const u8{
        "plugin.list", "plugin.get", "plugin.upload", "plugin.add", "plugin.find",
    };

    for (unchanged) |other| {
        if (std.mem.eql(u8, name, other)) {
            return false;
        }
    }

    // A restore may bring a plugin back from the trash; setting a provider up starts one.
    return std.mem.startsWith(u8, name, "plugin.") or std.mem.eql(u8, name, "trash.restore") or
        std.mem.eql(u8, name, "ai.set_up");
}

/// An event's payload as a hook's input: JSON as emitted; one of core's events not yet
/// typed carries a text, handed on as a JSON string.
fn payload_json(ctx: *sdk.Ctx, subject: []const u8) sdk.Error![]const u8 {
    if (subject.len > 0 and (subject[0] == '{' or subject[0] == '[')) {
        return subject;
    }

    return sdk.stringify(ctx.arena, subject);
}

/// What the plugin may reach this call: its grants with their flags, and its own types.
fn access_of(loaded: *Loaded, ctx: *sdk.Ctx) sdk.Error!sdk.plugin_access.Access {
    std.debug.assert(loaded.name().len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    return .{
        .granted = loaded.granted,
        .held = loaded.held,
        .depends_on = loaded.manifest.depends_on,
        .compatible_with = loaded.manifest.compatible_with,
        .own_types = loaded.own_types,
        .secrets = loaded.manifest.secrets,
        .remotes = loaded.manifest.remotes,
    };
}
