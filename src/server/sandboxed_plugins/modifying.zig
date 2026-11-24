//! Installed modifiers run over the values of one apply, held laid out (`applied.zig`):
//! every modifier whose name takes the name applied, in turn, each handed what the one
//! before answered. A modifier takes the values in its own type, laid out for it by name,
//! and answers them the same way; its answer is laid over the values where they lie
//! (`merged.zig`). No text is written or read. The chain works in the request's working
//! memory for nested calls, each modifier's share given back before the next runs: it takes
//! one batch's memory, never one per modifier.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const invoke_module = @import("invoke.zig");
const interface = @import("interface.zig");
const sandboxed_plugins = @import("../sandboxed_plugins.zig");
const applied = @import("applied.zig");
const Loaded = @import("loaded.zig").Loaded;

const Host = sandboxed_plugins.Host;
const Target = sandboxed_plugins.Target;

/// Whether any installed modifier takes `name`.
pub fn any(host: *Host, name: []const u8) bool {
    var buffer: [64]Target = undefined;

    std.debug.assert(name.len > 0);

    return modifiers_of(host, name, null, &buffer).len > 0;
}

/// The installed modifiers whose name takes `name` (`*.title` takes `variant.title`), in the
/// order the plugins were loaded, then declared. With an `owner`, only that plugin's
/// modifier of exactly `name`: a computed field's own function.
fn modifiers_of(
    host: *Host,
    name: []const u8,
    owner: ?[]const u8,
    buffer: []Target,
) []const Target {
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

        const pattern = key[prefix.len..];
        const taken = if (owner == null)
            sdk.mods.matches(pattern, name)
        else
            std.mem.eql(u8, pattern, name);

        if (!taken) {
            continue;
        }

        for (entry.value_ptr.*) |target| {
            if (!owned_by(host, target, owner)) {
                continue;
            }

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

/// Whether the modifier `target` is `owner`'s, or any plugin's when none is named.
fn owned_by(host: *Host, target: Target, owner: ?[]const u8) bool {
    std.debug.assert(target.sandboxed_plugin < host.loaded.items.len);

    const wanted = owner orelse return true;

    std.debug.assert(wanted.len > 0);

    const loaded = &host.loaded.items[target.sandboxed_plugin];

    return std.mem.eql(u8, loaded.manifest.name, wanted);
}

pub fn modify(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(input.len > 0);

    return applied_by(interface.host_of(context), ctx, name, null, input);
}

/// A computed field worked out: `owner`'s own modifier of `name` (`computed.<record>.<field>`)
/// alone, whatever another plugin declares under it.
pub fn compute(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    owner: []const u8,
    name: []const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    std.debug.assert(owner.len > 0);
    std.debug.assert(name.len > 0);

    return applied_by(interface.host_of(context), ctx, name, owner, input);
}

fn applied_by(
    host: *Host,
    ctx: *sdk.Ctx,
    name: []const u8,
    owner: ?[]const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(input.len > 0);

    // Already in working memory (a plugin's `ctx.mod`), or a process that set none aside:
    // the chain runs where the call is.
    const working = ctx.calls_set_aside orelse return chain(host, ctx, name, owner, input);

    if (working.holds(ctx.arena)) {
        return chain(host, ctx, name, owner, input);
    }

    // Core's own apply (a page's titles, the site's currencies): the chain works in the
    // working memory, and only the last answer is kept in the call's own.
    var held = sdk.call_json.Working.begin(ctx) catch {
        return chain(host, ctx, name, owner, input);
    };
    const answered = chain(host, ctx, name, owner, input);

    held.end();

    // A modifier's refusal keeps its words past the working memory given back.
    const last = answered catch |err| {
        try held.give_back_failed();

        return err;
    };

    defer held.give_back();

    return if (last.ptr == input.ptr) input else ctx.arena.dupe(u8, last);
}

/// Every modifier of `name` over the values `input` holds in turn, in `ctx.arena`.
fn chain(
    host: *Host,
    ctx: *sdk.Ctx,
    name: []const u8,
    owner: ?[]const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    var current = input;
    var buffer: [64]Target = undefined;

    std.debug.assert(name.len > 0);

    // Each modifier's working memory is given back before the next runs: only the values
    // as it left them are kept, laid where the first one began.
    const begun = sdk.call_json.host_call_begun(ctx);

    for (modifiers_of(host, name, owner, &buffer)) |found| {
        const loaded = &host.loaded.items[found.sandboxed_plugin];
        var access = try interface.access_of(loaded, ctx);
        const before_modifier = sdk.call_json.host_call_begun(ctx);
        const next = try stepped(loaded, ctx, &access, found.entry, current);

        if (begun == null) {
            current = next;
            continue;
        }

        const working = ctx.calls_set_aside.?;

        // An answer that could not be laid over leaves the values as they were, where they lie.
        if (next.ptr == current.ptr) {
            working.rewind(before_modifier.?);
        } else {
            current = working.keep_at(begun.?, next);
        }
    }

    return current;
}

/// The values `current` holds as one modifier leaves them. It takes them all at once; when
/// they are not all of its type they go to it one by one, and those that are not stay.
fn stepped(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    current: []const u8,
) sdk.Error![]const u8 {
    std.debug.assert(current.len > 0);

    const whole = invoke_module.invoke_passed(loaded, ctx, access, entry, .{
        .in = .{
            .laid = current,
        },
    }) catch |err| switch (err) {
        error.Invalid => return one_by_one(loaded, ctx, access, entry, current),
        else => return err,
    };
    const answered = switch (whole) {
        .json => return current,
        .laid => |piece| piece,
    };
    var standing: applied.Opened = undefined;
    var answer: applied.Opened = undefined;

    try standing.init(ctx.arena, current);

    // An answer that is not as many values leaves them all as they were.
    answer.init(ctx.arena, answered) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else current;
    };

    if (answer.items.count != standing.items.count) {
        return current;
    }

    const overs = ctx.arena.alloc(?applied.Over, standing.items.count) catch {
        return error.OutOfMemory;
    };

    for (overs, 0..) |*over, index| {
        over.* = .{
            .answer = &answer,
            .index = @intCast(index),
        };
    }

    return applied.laid_over(ctx.arena, &standing, overs);
}

/// Each of `current`'s values handed to the modifier alone: one it cannot take as its type,
/// or fails on, stays as it was.
fn one_by_one(
    loaded: *Loaded,
    ctx: *sdk.Ctx,
    access: *const sdk.plugin_access.Access,
    entry: u32,
    current: []const u8,
) sdk.Error![]const u8 {
    const memory = ctx.arena;
    var standing: applied.Opened = undefined;

    try standing.init(memory, current);

    const count = standing.items.count;

    std.debug.assert(count <= sdk.mods.items_max);

    if (count < 2) {
        return current;
    }

    const answers = memory.alloc(applied.Opened, count) catch return error.OutOfMemory;
    const overs = memory.alloc(?applied.Over, count) catch return error.OutOfMemory;

    for (answers, overs, 0..) |*answer, *over, index| {
        const alone = try applied.one(memory, &standing, @intCast(index));

        over.* = null;

        const answered = invoke_module.invoke_passed(loaded, ctx, access, entry, .{
            .in = .{
                .laid = alone,
            },
        }) catch |err| {
            if (err == error.Invalid) {
                continue;
            }

            return err;
        };

        if (answered != .laid) {
            continue;
        }

        answer.init(memory, answered.laid) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            continue;
        };

        if (answer.items.count == 1) {
            over.* = .{
                .answer = answer,
                .index = 0,
            };
        }
    }

    return applied.laid_over(memory, &standing, overs);
}

test {
    _ = applied;
}
