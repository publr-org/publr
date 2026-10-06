const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.2.0";

pub const lib = @import("lib.zig");
pub const db = lib.db;
pub const auth = lib.auth;
pub const http = lib.http;
pub const report = lib.report;
pub const sdk = @import("sdk.zig");
pub const model = @import("model.zig");
pub const store = @import("store.zig");
pub const cli = @import("adapters/cli.zig");
pub const server = @import("server.zig");
pub const registry = @import("server/registry.zig");
pub const plugin = @import("sdk/plugin.zig");
/// A plugin's records as typed values: `publr.records.of(Order, "order")`.
pub const records = @import("operations/record/typed.zig");
/// A plugin's internal records as typed values: `publr.internal.of(Movement, "movement")`.
pub const internal = @import("operations/internal/typed.zig");
pub const routes = @import("server/routes.zig");
pub const plugin_routes = @import("server/plugin_routes.zig");
pub const plugin_states = @import("server/plugin_states.zig");
pub const plugin_hooks = @import("server/plugin_hooks.zig");
pub const rest = @import("adapters/rest.zig");
pub const admin = @import("adapters/admin.zig");
pub const project = @import("server/project.zig");
pub const apps = @import("adapters/apps.zig");
/// What an app's `middleware.zig` is given, and what it answers with.
pub const Request = apps.middleware.Request;
pub const Response = apps.middleware.Response;
pub const template = @import("template.zig");
pub const operations = struct {
    pub const heartbeat = @import("operations/heartbeat.zig");
    pub const project = @import("operations/project.zig");
    pub const custom_fields = @import("operations/custom_fields.zig");
    pub const user = @import("operations/user.zig");
    pub const sign_in = @import("operations/sign_in.zig");
    pub const sign_on = @import("operations/sign_on.zig");
    pub const identity = @import("operations/identity.zig");
    pub const status = @import("operations/status.zig");
    pub const role = @import("operations/role.zig");
    pub const content_type = @import("operations/content_type.zig");
    pub const record = @import("operations/record.zig");
    pub const taxonomy = @import("operations/taxonomy.zig");
    pub const term = @import("operations/term.zig");
    pub const media = @import("operations/media.zig");
    pub const snapshot = @import("operations/snapshot.zig");
    pub const view = @import("operations/view.zig");
    pub const internal = @import("operations/internal.zig");
    pub const plugin = @import("operations/plugin.zig");
};
pub const serve = if (builtin.os.tag == .wasi) void else @import("server/serve.zig");
pub const build = if (builtin.os.tag == .wasi) void else @import("server/build.zig");
pub const toolchain = if (builtin.os.tag == .wasi) void else @import("server/toolchain.zig");
pub const plugin_build = if (builtin.os.tag == .wasi) void else @import("server/plugin_build.zig");
pub const operator = if (builtin.os.tag == .wasi) void else @import("server/operator.zig");
pub const agents = if (builtin.os.tag == .wasi) void else @import("server/agents.zig");
pub const apps_load = if (builtin.os.tag == .wasi) void else @import("server/apps_load.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(operations);
    std.testing.refAllDecls(http);
}

test "version is a semantic version with three components" {
    var parts: u32 = 0;
    var iterator = std.mem.splitScalar(u8, version, '.');

    while (iterator.next()) |part| : (parts += 1) {
        try std.testing.expect(part.len > 0);
        _ = try std.fmt.parseInt(u32, part, 10);
    }

    try std.testing.expectEqual(@as(u32, 3), parts);
}
