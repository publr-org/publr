//! A built-in plugin's `bootstrap`, run as its jobs run: as the plugin alone (the caller
//! `ctx.as_plugin()` makes), held to its grants with no account and no roles, judged so by
//! every check. Its internal records are its own to read and write; a step that needs Publr's
//! own standing says so with `publr.Host.as_system(ctx)`. The database opens with Publr
//! behind it, put back once the plugin's code ends.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const HostApi = @import("context.zig").HostApi;

pub fn run(ctx: *sdk.Ctx, comptime plugin: []const u8, comptime bootstrap: anytype) sdk.Error!void {
    comptime std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.caller == .system);

    const running = ctx.plugin;
    const was_code = ctx.plugin_code;

    ctx.plugin = plugin;
    ctx.plugin_code = true;
    ctx.caller = sdk.plugin_caller.alone(plugin, registry.SDK.compiled_access(plugin));
    defer ctx.plugin = running;
    defer ctx.plugin_code = was_code;
    defer ctx.caller = .system;

    var host: HostApi = .{
        .inner = ctx,
    };

    try bootstrap(host.ctx());
}

test "a plugin's bootstrap runs as the plugin, and the database's context is put back" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    const Seen = struct {
        fn bootstrap(ctx: *@import("context.zig").PluginCtx) sdk.Error!void {
            std.debug.assert(ctx.now().ms >= 0);

            // What the test expects, failed as the bootstrap's own error.
            seen(ctx) catch return error.Invalid;
        }

        fn seen(ctx: *@import("context.zig").PluginCtx) !void {
            const inner = @import("context.zig").host_of(ctx).inner;

            std.debug.assert(inner.db.transaction_depth == 0);

            try std.testing.expectEqualStrings("hello", inner.plugin);
            try std.testing.expect(inner.plugin_code);
            try std.testing.expectEqualStrings("hello", inner.caller.plugin.name);
            try std.testing.expect(!ctx.caller().system);

            const powers = @import("../../publr/extend/powers.zig");

            try std.testing.expect((try powers.as_system(ctx)).caller().system);
            try std.testing.expect(!(try ctx.as_plugin()).caller().system);

            const person = try ctx.as_person("u_1");

            try std.testing.expectEqualStrings("u_1", person.caller().user_id().?);
        }
    };

    try run(&system, "hello", Seen.bootstrap);
    try std.testing.expectEqualStrings("", system.plugin);
    try std.testing.expect(!system.plugin_code);
    try std.testing.expect(system.caller == .system);
}
