//! The `sdk.plugins.Plugins` the host hands every context: finding a plugin's operation,
//! running it, running the hooks plugins hold, and reading a module to install.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
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
    .roles = &roles_of,
    .find = &find,
    .manifests = &manifests,
    .run = &run,
    .hooked = &hooked,
    .before = &before,
    .after = &after,
    .event = &event,
};

fn host_of(context: *anyopaque) *Host {
    return @ptrCast(@alignCast(context));
}

fn roles_of(context: *anyopaque) ?[]const model.role.Role {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    return host.roles;
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
        .fields = declared.fields,
        .help = declared.help,
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

fn hooked(context: *anyopaque, hook_stage: sdk.sandboxed_plugins.Stage, name: []const u8) bool {
    const host = host_of(context);

    std.debug.assert(name.len > 0);

    if (host.hooks.count() == 0) {
        return false;
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

fn event(context: *anyopaque, ctx: *sdk.Ctx, happened: sdk.Event) void {
    const host = host_of(context);

    std.debug.assert(ctx.now_ms >= 0);

    if (changed_plugins(happened) and ctx.db.transaction_depth == 0) {
        host.load_all(ctx.db) catch |err| std.log.err("plugins: reload failed: {t}", .{err});
        return;
    }

    if (host.hooks.count() == 0 or ctx.plugin_depth >= sdk.sandboxed_plugins.depth_max) {
        return;
    }

    const name = switch (happened) {
        .completed => |completed| completed.operation_name,
        .rejected, .failed => |failed| failed.operation_name,
        .notice => |notice| notice.name,
    };
    const targets = targets_of(host, .event, name);

    if (targets.len == 0) {
        return;
    }

    const input = event_json(ctx, happened, name) catch return;

    ctx.plugin_depth += 1;
    defer ctx.plugin_depth -= 1;

    for (targets) |target| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];
        var access = access_of(loaded, ctx) catch continue;

        _ = invoke_module.invoke(loaded, ctx, &access, target.entry, input) catch |err| {
            std.log.warn("plugin {s}: event hook on {s}: {t}", .{ loaded.name(), name, err });
        };
    }
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
        "plugin.list", "plugin.get", "plugin.upload", "plugin.add",
    };

    for (unchanged) |other| {
        if (std.mem.eql(u8, name, other)) {
            return false;
        }
    }

    return std.mem.startsWith(u8, name, "plugin.");
}

fn event_json(ctx: *sdk.Ctx, happened: sdk.Event, name: []const u8) sdk.Error![]const u8 {
    std.debug.assert(name.len > 0);

    const wire = @import("../../sdk/plugin/wire.zig");
    const shaped: wire.Event = switch (happened) {
        .completed => .{ .kind = .completed, .name = name },
        .rejected => |failed| .{ .kind = .rejected, .name = name, .err = @errorName(failed.err) },
        .failed => |failed| .{ .kind = .failed, .name = name, .err = @errorName(failed.err) },
        .notice => |notice| .{ .kind = .notice, .name = name, .subject = notice.subject },
    };

    return sdk.stringify(ctx.arena, shaped);
}

/// What the plugin may reach this call: its grants, its own types, and the types its
/// content access names (public ones read from the definitions now).
fn access_of(loaded: *Loaded, ctx: *sdk.Ctx) sdk.Error!sdk.plugin_access.Access {
    std.debug.assert(loaded.name().len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    var access: sdk.plugin_access.Access = .{
        .granted = loaded.granted,
        .depends_on = loaded.manifest.depends_on,
        .compatible_with = loaded.manifest.compatible_with,
        .own_types = loaded.own_types,
        .types = null,
    };

    switch (loaded.content_access.scope) {
        .all => {},
        .specific => {
            access.types = try std.mem.concat(ctx.arena, []const u8, &.{
                loaded.own_types,
                loaded.content_access.types,
            });
        },
        .public => access.types = try public_types(ctx, loaded.own_types),
    }

    return access;
}

fn public_types(ctx: *sdk.Ctx, own: []const []const u8) sdk.Error![]const []const u8 {
    std.debug.assert(own.len <= 64);

    const briefs = try store.content_types.list_briefs(ctx.db, ctx.arena);
    var types: std.ArrayList([]const u8) = .empty;

    try types.appendSlice(ctx.arena, own);

    for (briefs) |brief| {
        if (brief.public) {
            try types.append(ctx.arena, brief.handle);
        }
    }

    return types.items;
}
