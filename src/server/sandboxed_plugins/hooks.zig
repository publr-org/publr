//! The installed plugins' `before` and `after` hooks on one call: which hooks hear it, each
//! run in turn as its plugin, a failure said under the plugin's name; and what follows an
//! operation's end when an administrator changed the plugins.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const files_module = @import("files.zig");
const invoke_module = @import("invoke.zig");
const Loaded = @import("loaded.zig").Loaded;
const contracts = @import("../../sdk/contract.zig");
const sandboxed_plugins = @import("../sandboxed_plugins.zig");
const modifying = @import("modifying.zig");
const hooks_many = @import("hooks_many.zig");
const Host = sandboxed_plugins.Host;
const Target = sandboxed_plugins.Target;
const hash_len = files_module.hash_len;
const sandboxed_plugins_max = sandboxed_plugins.sandboxed_plugins_max;
const Passed = sdk.sandboxed_plugins.Passed;
const interface = @import("interface.zig");
const queued = @import("queued.zig");

const host_of = interface.host_of;
const access_of = interface.access_of;
const working_run = queued.working_run;

pub fn hooked(context: *anyopaque, hook_stage: sdk.sandboxed_plugins.Stage, name: []const u8) bool {
    const host = host_of(context);

    std.debug.assert(name.len > 0);

    if (host.hooks.count() == 0) {
        return false;
    }

    if (hook_stage == .modify) {
        return modifying.any(host, name);
    }

    var key_buffer: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{t}:{s}", .{ hook_stage, name }) catch return false;

    return host.hooks.contains(key);
}

pub fn targets_of(
    host: *Host,
    hook_stage: sdk.sandboxed_plugins.Stage,
    name: []const u8,
) []const Target {
    var key_buffer: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{t}:{s}", .{ hook_stage, name }) catch return &.{};

    return host.hooks.get(key) orelse &.{};
}

/// Whether hook `target` hears a call of `name` with `input`. A hook about a record kind or
/// a content type (`Hook.about`: a record's `.validate`, a hook that names a type) hears
/// only a call whose input names that one: its plugin is never started for another's write.
/// An internal kind is its plugin's own: the write must be of that plugin's records.
pub fn hears(
    loaded: *const Loaded,
    ctx: *sdk.Ctx,
    target: Target,
    name: []const u8,
    input: Passed,
) bool {
    const manifest = &loaded.manifest;

    std.debug.assert(target.entry >= manifest.operations.len);
    std.debug.assert(target.entry - manifest.operations.len < manifest.hooks.len);

    const about = manifest.hooks[target.entry - manifest.operations.len].about;

    if (about.len == 0) {
        return true;
    }

    if (std.mem.startsWith(u8, name, "internal.")) {
        const kind = text_of(ctx, input, "kind") orelse return false;
        const owner = text_of(ctx, input, "plugin") orelse ctx.plugin;

        return std.mem.eql(u8, kind, about) and std.mem.eql(u8, owner, loaded.name());
    }

    // A call that names no type (a save by id, a list of every type) may be about it.
    const named = text_of(ctx, input, "type") orelse return true;

    return std.mem.eql(u8, named, about);
}

/// The text field `name` at the top of a call's input, read where it lies.
fn text_of(ctx: *sdk.Ctx, input: Passed, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    return switch (input) {
        .json => |text| model.json_fields.text_of(text, name),
        .laid => |piece| @import("held.zig").text_field(ctx.arena, piece, name),
    };
}

pub fn before(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    input: Passed,
) sdk.Error!Passed {
    const host = host_of(context);
    var current = input;

    std.debug.assert(name.len > 0);

    // Each hook hands the input on as it left it: the next takes it with no JSON between.
    for (targets_of(host, .before, name)) |target| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];

        if (!hears(loaded, ctx, target, name, current)) {
            continue;
        }

        var access = try access_of(loaded, ctx);

        current = working_run(loaded, ctx, &access, target.entry, .{
            .in = current,
        }, true) catch |err| return hook_failed(loaded, ctx, name, err);
    }

    return current;
}

/// An installed hook failed: said on the call's lines under its plugin's name, so the
/// Activity or Error log and the plugin's Log show it whether or not it stops the call.
fn hook_failed(loaded: *const Loaded, ctx: *sdk.Ctx, name: []const u8, err: sdk.Error) sdk.Error {
    std.debug.assert(name.len > 0);

    var buffer: [200]u8 = undefined;
    const said = if (ctx.failure) |failure| failure.message else "";
    const text = std.fmt.bufPrint(&buffer, "Its hook on {s} failed: {s}", .{
        name[0..@min(name.len, 96)],
        if (said.len > 0) said[0..@min(said.len, 64)] else @errorName(err),
    }) catch "Its hook failed";

    if (ctx.lines) |lines| {
        lines.add(.{
            .plugin = loaded.name(),
            .level = .warn,
            .text = text,
        });
    }

    return err;
}

pub fn after(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    input: Passed,
    output: Passed,
    extended: ?sdk.Extended,
) sdk.Error!void {
    const host = host_of(context);
    const both: invoke_module.Parts = .{
        .in = input,
        .out = output,
    };

    std.debug.assert(name.len > 0);

    for (targets_of(host, .after, name)) |target| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];

        // A hook extending a list's rows adds what others read: the plugin's own reads skip it.
        if (extended != null and std.mem.eql(u8, ctx.plugin, loaded.name())) {
            continue;
        }

        if (!hears(loaded, ctx, target, name, input)) {
            continue;
        }

        var access = try access_of(loaded, ctx);
        const adds = extended != null;
        const handed = working_run(loaded, ctx, &access, target.entry, both, adds) catch |err| {
            return hook_failed(loaded, ctx, name, err);
        };
        const rows = extended orelse continue;
        const answered = try invoke_module.json_of(ctx.arena, handed, .answer);

        // What the hook added to the rows, kept only under its own plugin's name.
        const plugin = loaded.name();
        const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, answered, .{}) catch {
            return error.Invalid;
        };

        const open = rows.open orelse continue;
        const running = open.plugin;

        open.plugin = &plugin;
        defer open.plugin = running;

        try rows.merge(value);
    }
}

/// An operation's end reloads the plugins when an administrator changed them. A queued
/// event reaches the `on` hooks one by one, through `on_hooks` and `on`.
pub fn event(context: *anyopaque, ctx: *sdk.Ctx, happened: sdk.Event) void {
    const host = host_of(context);

    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(happened != .emitted);

    if (changed_plugins(happened) and ctx.db.transaction_depth == 0) {
        host.load_all(ctx.db) catch |err| std.log.err("plugins: reload failed: {t}", .{err});
        answer_at_install(ctx);
    }
}

/// Providers installed or updated are asked what their contracts ask at install, once the
/// plugins are loaded again: their answers are kept as their defaults.
fn answer_at_install(ctx: *sdk.Ctx) void {
    std.debug.assert(ctx.db.transaction_depth == 0);

    var asking = ctx.*;

    asking.caller = .system;
    asking.plugin = "";

    const registry = @import("../registry.zig");
    const Answer = @import("../../operations/provider/answers.zig").Answer;

    _ = registry.SDK.dispatch(&asking, Answer, .{}) catch |err| {
        std.log.err("providers: not asked at install: {t}", .{err});
    };

    std.debug.assert(asking.db.transaction_depth == 0);
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
        "plugin.list", "plugin.get",      "plugin.upload",     "plugin.add",
        "plugin.find", "plugin.labels",   "plugin.data",       "plugin.left_behind",
        "plugin.log",  "plugin.scaffold", "plugin.interfaces", "plugin.surface",
        "plugin.fits",
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
