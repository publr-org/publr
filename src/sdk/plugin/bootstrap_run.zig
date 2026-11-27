//! A built-in plugin's `bootstrap`, run as the plugin's own code, as its jobs run: its
//! internal records are its to read and write, its calls are held to its grants, and
//! `publr.Host.as_system(ctx)`, `ctx.as_plugin()` and `ctx.as_person()` answer it. The caller
//! stays Publr itself, the database opening with nobody behind it.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const HostApi = @import("context.zig").HostApi;

pub fn run(ctx: *sdk.Ctx, comptime plugin: []const u8, comptime bootstrap: anytype) sdk.Error!void {
    comptime std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.caller == .system);

    const running = ctx.plugin;
    const was_code = ctx.plugin_code;

    ctx.plugin = plugin;
    ctx.plugin_code = true;
    defer ctx.plugin = running;
    defer ctx.plugin_code = was_code;

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
            const inner = @import("context.zig").host_of(ctx).inner;

            std.debug.assert(inner.db.transaction_depth == 0);

            try std.testing.expectEqualStrings("hello", inner.plugin);
            try std.testing.expect(inner.plugin_code);
            try std.testing.expect(inner.caller == .system);

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
