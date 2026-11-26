//! Request hooks as the server runs them: each plugin's `publr.hook.request`, on the system's
//! context as the plugin, over what `publr/page_request.zig` says a hook reads and answers.
const std = @import("std");
const public = @import("../publr/page_request.zig");
const context = @import("context.zig");
const operation = @import("operation.zig");

pub const PageRequest = public.PageRequest;
pub const Answered = public.Answered;

pub const hooks_max: u32 = 16;

/// One plugin's hook, as the server runs it: on the system's context, as the plugin.
pub const Hook = struct {
    plugin: []const u8,
    run: *const fn (ctx: *context.Ctx, request: *PageRequest) operation.Error!Answered,
};

/// Every hook in turn until one redirects or refuses. A hook that fails is logged and
/// skipped: a page never fails on a plugin's hook.
pub fn run_all(hooks: []const Hook, ctx: *context.Ctx, request: *PageRequest) void {
    std.debug.assert(hooks.len <= hooks_max);
    std.debug.assert(request.ending == .next);

    for (hooks) |hook| {
        const saved = ctx.plugin;

        ctx.plugin = hook.plugin;
        defer ctx.plugin = saved;

        const answered = hook.run(ctx, request) catch |err| {
            std.log.warn("a request hook of {s} failed: {t}", .{ hook.plugin, err });

            continue;
        };

        if (answered.said == .ended) {
            return;
        }
    }
}
