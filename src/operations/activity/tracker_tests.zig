//! `publr.errors.Failed` heard by a compiled-in tracker: an error line and a crash raise it
//! once each, kept outside the write; a refusal raises nothing.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const plugin_module = @import("../../sdk/plugin.zig");
const plugin_define = @import("../../sdk/plugin/define.zig");
const hook_define = @import("../../sdk/plugin/hook_define.zig");
const error_events = @import("../../sdk/error_events.zig");
const activity = @import("../activity.zig");
const store = @import("../../store.zig");

const PluginCtx = @import("../../sdk/plugin/context.zig").PluginCtx;
const QueueCtx = @import("../../sdk/plugin/queue.zig").Queue(PluginCtx);

/// Breaks on purpose, and records every error it hears of, as an error tracker would.
const Tracker = struct {
    pub const plugin = plugin_define.define(.{
        .name = "tracker",
        .version = "0.1.0",
    }, .{
        .operations = .{Break},
        .hooks = .{hook_define.on(error_events.Failed, track)},
    });

    pub const BreakIn = struct {
        how: []const u8,
    };
    pub const BreakOut = struct {
        how: []const u8,
    };
    pub const Break = @import("../../sdk/plugin/operation_define.zig").define(BreakIn, BreakOut, .{
        .name = "break",
        .kind = .write,
        .run = break_as_asked,
    });

    fn break_as_asked(ctx: *PluginCtx, in: BreakIn) sdk.Error!BreakOut {
        std.debug.assert(in.how.len > 0);

        if (std.mem.eql(u8, in.how, "refuse")) {
            return ctx.inner.fail(.{
                .name = "Nope",
                .status = 409,
                .message = "Not today",
            });
        }

        if (std.mem.eql(u8, in.how, "crash")) {
            return error.Unavailable;
        }

        ctx.log(.err, "The disk is full", .{});

        return .{
            .how = in.how,
        };
    }

    fn track(ctx: *QueueCtx, failed: error_events.Failed.Payload) sdk.Error!void {
        std.debug.assert(ctx.base.inner.db.transaction_depth == 0);
        std.debug.assert(failed.entry > 0);

        ctx.log(.info, "Tracked {s} {s}: {s} by {s}", .{
            failed.what,
            failed.error_name,
            failed.message,
            failed.caller,
        });
    }
};

test "errors raise publr.errors.Failed for a compiled-in tracker; refusals raise nothing" {
    const Bundle = plugin_module.Merged(.{plugin_define.Bind(Tracker, plugin_define.Words(.{
        .{ "main", "Test plugin: tracks errors" },
        .{
            "operation:break",
            "Break in the way asked\n\nExample:\n  in: { \"how\": \"line\" }\n" ++
                "  out: { \"how\": \"line\" }",
        },
        .{ @typeName(Tracker.BreakIn) ++ ".how", "`line`, `refuse` or `crash`" },
        .{ @typeName(Tracker.BreakOut) ++ ".how", "How it broke" },
    }))});
    const TestSDK = sdk.SDK(.{
        .operations = Bundle.merged_operations,
        .hooks = Bundle.merged_hooks,
        .operation_owners = Bundle.merged_operation_owners,
        .hook_owners = Bundle.merged_hook_owners,
        .log = activity.log,
    });

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    _ = try TestSDK.dispatch(&ctx, Tracker.Break, .{
        .how = "line",
    });
    try std.testing.expectError(error.Failed, TestSDK.dispatch(&ctx, Tracker.Break, .{
        .how = "refuse",
    }));
    try std.testing.expectError(error.Unavailable, TestSDK.dispatch(&ctx, Tracker.Break, .{
        .how = "crash",
    }));

    // Three Error log entries; two are errors, kept though the crash's write rolled back.
    try std.testing.expectEqual(@as(u32, 3), try sdk.testing.count(&ctx, "errors"));
    try std.testing.expectEqual(@as(u32, 2), try sdk.testing.count(&ctx, "job_queue"));

    var worker = harness.ctx(.system);
    try std.testing.expectEqual(@as(u32, 2), try TestSDK.jobs.drain(&worker, 8));

    const rows = try store.plugin_log.of_plugin(ctx.db, ctx.arena, "tracker", null, 8);
    var tracked: std.ArrayList([]const u8) = .empty;

    // Newest first; the error line itself is the tracker's too.
    for (rows) |row| {
        if (std.mem.startsWith(u8, row.line, "Tracked ")) {
            try tracked.append(ctx.arena, row.line);
        }
    }

    try std.testing.expectEqual(2, tracked.items.len);
    try std.testing.expectEqualStrings(
        "Tracked tracker.break Unavailable:  by system",
        tracked.items[0],
    );
    try std.testing.expectEqualStrings(
        "Tracked tracker.break Logged: The disk is full by system",
        tracked.items[1],
    );
}
