//! Who a compiled-in plugin's code runs as. Its bootstrap, its jobs and its queued hooks run
//! as the plugin alone (`ctx.as_plugin()`): its grants, no account, no roles, as an installed
//! plugin's do. Its code reached by another plugin's runs as itself for the same person, and
//! reached by Publr in queued work (a provider core's job calls) as itself alone. A person's
//! request stays theirs, the plugin's grants holding its code (`plugin_code`).
const std = @import("std");
const Caller = @import("caller.zig").Caller;
const Access = @import("plugin_access.zig").Access;

/// The grants of a compiled-in plugin that asked for none: its own types only.
pub const no_access: Access = .{
    .own_types = &.{},
};

/// The plugin calling as itself, with no person behind it.
pub fn alone(name: []const u8, access: ?*const Access) Caller {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= 64);

    return .{
        .plugin = .{
            .name = name,
            .access = access orelse &no_access,
        },
    };
}

/// What reaching `owner`'s code makes of `caller`: the owner in place of another plugin, for
/// the same person and roles; the owner alone in place of Publr in queued work; else the
/// caller as it is.
pub fn entering(caller: Caller, owner: []const u8, access: ?*const Access, queued: bool) Caller {
    std.debug.assert(owner.len <= 64);

    if (owner.len == 0) {
        return caller;
    }

    return switch (caller) {
        .plugin => |plugin| if (std.mem.eql(u8, plugin.name, owner)) caller else .{
            .plugin = .{
                .name = owner,
                .on_behalf_of = plugin.on_behalf_of,
                .access = access orelse &no_access,
                .roles = plugin.roles,
                .for_person = plugin.for_person,
            },
        },
        .system => if (queued) alone(owner, access) else caller,
        .anonymous, .user, .token => caller,
    };
}

test "a plugin's code runs as itself: another plugin's caller and Publr's queued work become it" {
    const granted: Access = .{
        .own_types = &.{},
    };
    const person: Caller = .{
        .plugin = .{
            .name = "payments",
            .on_behalf_of = "u_1",
            .roles = &.{"editor"},
            .for_person = true,
        },
    };
    const reached = entering(person, "orders", &granted, false);

    try std.testing.expectEqualStrings("orders", reached.plugin.name);
    try std.testing.expectEqualStrings("u_1", reached.plugin.on_behalf_of.?);
    try std.testing.expect(reached.plugin.for_person);
    try std.testing.expect(reached.plugin.access.? == &granted);

    const own = entering(person, "payments", null, true);

    try std.testing.expectEqualStrings("payments", own.plugin.name);

    const queued = entering(.system, "orders", null, true);

    try std.testing.expect(queued.plugin.access.? == &no_access);
    try std.testing.expect(queued.plugin.on_behalf_of == null);
    try std.testing.expect(entering(.system, "orders", null, false) == .system);
    try std.testing.expect(entering(.system, "", null, true) == .system);
    try std.testing.expect(entering(.anonymous, "orders", null, true) == .anonymous);
}

/// What each kind of a plugin's work between requests tries below: a call outside its grants
/// (`role.list`, in `permission.never`) is refused; the same through
/// `publr.Host.as_system` passes.
const Outside = struct {
    const PluginCtx = @import("plugin/context.zig").PluginCtx;
    const QueueCtx = @import("plugin/queue.zig").QueueCtx;
    const Error = @import("../publr/operation.zig").Error;
    const List = @import("../publr/operations/role.zig").List;
    const powers = @import("../publr/extend/powers.zig");

    fn refused_then_as_system(ctx: *PluginCtx) Error!void {
        std.debug.assert(!ctx.caller().system);

        if (ctx.call(List, .{})) |_| {
            return error.Invalid;
        } else |err| {
            if (err != error.Denied) {
                return err;
            }
        }

        const system = try powers.as_system(ctx);

        std.debug.assert(system.caller().system);

        _ = try system.call(List, .{});
    }

    fn bootstrap(ctx: *PluginCtx) Error!void {
        return refused_then_as_system(ctx);
    }

    const In = struct {
        word: []const u8,
    };

    fn job(ctx: *QueueCtx, in: In) Error!void {
        std.debug.assert(in.word.len > 0);

        return refused_then_as_system(ctx.base);
    }

    const Heard = struct {
        pub const stage: @import("hooks.zig").Stage = .on;
        pub const event = "hello.record";
        pub const Payload = @import("../sdk.zig").testing.Record.Out;

        pub fn run(ctx: *PluginCtx, out: Payload) Error!void {
            std.debug.assert(out.rows == 1);

            return refused_then_as_system(ctx);
        }
    };
};

test "a plugin's bootstrap is held to its grants; through Host.as_system it is not" {
    const sdk = @import("../sdk.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    try @import("plugin/bootstrap_run.zig").run(&system, "probe", Outside.bootstrap);
    try std.testing.expect(system.caller == .system);
}

test "a plugin's job and queued hook are held to its grants; through Host.as_system not" {
    const sdk = @import("../sdk.zig");
    const job_queue = @import("../store/job_queue.zig");
    const Job = @import("../publr/plugin/job_define.zig").define(Outside.In, .{
        .name = "outside",
        .run = Outside.job,
    });
    const ProbeSDK = sdk.SDK(.{
        .operations = &.{sdk.testing.Record},
        .hooks = &.{Outside.Heard},
        .hook_owners = &.{"probe"},
        .jobs = &.{Job},
        .job_owners = &.{"probe"},
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    try job_queue.push(ctx.db, .{
        .plugin = "probe",
        .name = "outside",
        .input = "{\"word\":\"hi\"}",
        .due_at_ms = ctx.now_ms,
        .now_ms = ctx.now_ms,
    });
    _ = try ProbeSDK.dispatch(&ctx, sdk.testing.Record, .{
        .note = "kept",
    });

    try std.testing.expectEqual(2, try ProbeSDK.jobs.drain(&ctx, 8));
    try std.testing.expectEqual(0, (try job_queue.list(ctx.db, ctx.arena, 8)).len);
    try std.testing.expect(ctx.caller == .system);
}
