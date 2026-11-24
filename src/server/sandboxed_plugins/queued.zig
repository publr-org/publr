//! What core starts in a plugin outside an installed operation: a queued job, an `on` hook
//! heard from the queue, and any run that works in the request's working memory. A queued
//! run is a request of its own on the host: nothing an earlier run left is in its plugins.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const files_module = @import("files.zig");
const invoke_module = @import("invoke.zig");
const Loaded = @import("loaded.zig").Loaded;
const sandboxed_plugins = @import("../sandboxed_plugins.zig");
const modifying = @import("modifying.zig");
const hooks_many = @import("hooks_many.zig");
const Host = sandboxed_plugins.Host;
const Target = sandboxed_plugins.Target;
const hash_len = files_module.hash_len;
const sandboxed_plugins_max = sandboxed_plugins.sandboxed_plugins_max;
const Passed = sdk.sandboxed_plugins.Passed;
const interface = @import("interface.zig");

const host_of = interface.host_of;
const access_of = interface.access_of;
const targets_of = @import("hooks.zig").targets_of;

/// Runs installed plugin `plugin`'s job `name` as the plugin; `last` lets its `.on_failure`
/// hear a failure that ends it.
pub fn job(
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
    var access = try access_of(loaded, ctx);

    // A queued run is a request of its own: nothing an earlier run left is in its plugins,
    // and nothing of it is left for the next.
    host.drop_idle();
    run_begin(host, ctx);
    defer host.drop_idle();
    defer host.request_end();
    defer run_told(host, ctx, name);

    return queued_run(loaded, ctx, &access, @intCast(entry), .{
        .in = .{
            .json = input,
        },
        .last = last,
    });
}

/// A queued run (a job, an `on` hook) of entry `entry`, in the request's working memory:
/// each call the plugin makes into core gives its memory back as it answers, and the run's
/// own goes when it ends, so a run takes its largest step's memory, never every step's.
/// Its answer is not kept; a refusal's words are.
/// A queued run's request begins: when it is the outermost, core's working memory is
/// measured from here.
fn run_begin(host: *Host, ctx: *const sdk.Ctx) void {
    std.debug.assert(ctx.now_ms >= 0);

    if (host.requests == 0) {
        if (ctx.calls_set_aside) |working| {
            working.peak_reset();
        }
    }

    host.request_begin();

    std.debug.assert(host.requests > 0);
}

/// What a queued run was and where core's memory stood, told before its request ends.
fn run_told(host: *Host, ctx: *const sdk.Ctx, name: []const u8) void {
    std.debug.assert(name.len > 0);
    std.debug.assert(host.requests > 0);

    host.counted.tell(.{
        .label = name,
        .scratch_bytes = if (ctx.calls_set_aside) |working| working.peak_bytes() else 0,
        .arena_bytes = sdk.scratch.used_of(ctx.arena) orelse 0,
    });
}

fn queued_run(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    parts: invoke_module.Parts,
) sdk.Error!void {
    std.debug.assert(parts.in.bytes().len > 0);

    _ = try working_run(loaded, ctx, access, entry, parts, false);
}

/// One run of a plugin's entry that core starts outside an installed operation (a hook on
/// one of core's operations, a queued run), in the request's working memory when the
/// process set one aside and the call is not in it already: each call the plugin makes into
/// core gives its memory back as it answers, and the run's own goes when it ends. With
/// `kept` its answer is copied to the caller's memory first; a refusal's words always are.
pub fn working_run(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    parts: invoke_module.Parts,
    kept: bool,
) sdk.Error!Passed {
    std.debug.assert(parts.in.bytes().len > 0);

    const set_aside = ctx.calls_set_aside orelse {
        return invoke_module.invoke_passed(loaded, ctx, access, entry, parts);
    };

    // In the working memory already: whoever took it gives this run's share back.
    if (set_aside.holds(ctx.arena)) {
        return invoke_module.invoke_passed(loaded, ctx, access, entry, parts);
    }

    var working = try sdk.call_json.Working.begin(ctx);
    const ran = invoke_module.invoke_passed(loaded, ctx, access, entry, parts);

    working.end();

    const answer = ran catch |err| {
        try working.give_back_failed();

        return err;
    };

    defer working.give_back();

    if (!kept) {
        return .{
            .json = "{}",
        };
    }

    return answer.moved(ctx.arena.dupe(u8, answer.bytes()) catch return error.OutOfMemory);
}

const OnHook = sdk.sandboxed_plugins.OnHook;

pub fn on_hooks(
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

/// The hook `hook` names among the event's: its plugin and which of its entries it is.
fn hook_target(host: *Host, hook: OnHook, name: []const u8) ?Target {
    const targets = targets_of(host, .event, name);

    std.debug.assert(hook.plugin.len > 0);

    for (targets, 0..) |target, index| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];
        const same = std.mem.eql(u8, loaded.name(), hook.plugin) and
            ordinal_of(targets[0..index], target) == hook.ordinal;

        if (same) {
            return target;
        }
    }

    return null;
}

pub fn on_input(
    context: *anyopaque,
    arena: std.mem.Allocator,
    hook: OnHook,
    name: []const u8,
    payload: Passed,
) sdk.Error![]const u8 {
    const host = host_of(context);
    const target = hook_target(host, hook, name) orelse return error.NotFound;
    const loaded = &host.loaded.items[target.sandboxed_plugin];

    std.debug.assert(name.len > 0);

    return @import("projected.zig").json_for(loaded, target.entry, arena, payload);
}

pub fn on(
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

    const target = hook_target(host, hook, name) orelse return error.NotFound;
    const loaded = &host.loaded.items[target.sandboxed_plugin];
    const input = try payload_json(ctx, subject);
    var access = try access_of(loaded, ctx);

    ctx.plugin_depth += 1;
    defer ctx.plugin_depth -= 1;

    host.drop_idle();
    run_begin(host, ctx);
    defer host.drop_idle();
    defer host.request_end();
    defer run_told(host, ctx, name);

    return queued_run(loaded, ctx, &access, target.entry, .{
        .in = .{
            .json = input,
        },
    });
}

/// An event's payload as a hook's input: JSON as emitted; one of core's events not yet
/// typed carries a text, handed on as a JSON string.
fn payload_json(ctx: *sdk.Ctx, subject: []const u8) sdk.Error![]const u8 {
    if (subject.len > 0 and (subject[0] == '{' or subject[0] == '[')) {
        return subject;
    }

    return sdk.stringify(ctx.arena, subject);
}
