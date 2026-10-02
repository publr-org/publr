const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");

pub const Caller = sdk.Caller;
pub const Error = sdk.Error;

/// What a plugin's operations and hooks take: `SandboxApi` when the plugin is loaded into
/// the sandbox (every call proxied to the host), `HostApi` when it is built in (direct calls,
/// full access). The same source compiles either way.
pub const PluginCtx = switch (guest.mode) {
    .sandboxed => guest.SandboxApi,
    .native => HostApi,
};

pub const Mode = guest.Mode;

const guest = @import("guest.zig");

/// A native plugin's way into Publr: direct calls through the SDK, full access.
pub const HostApi = struct {
    inner: *sdk.Ctx,

    pub fn caller(self: *const PluginCtx) Caller {
        std.debug.assert(self.inner.now_ms >= 0);
        std.debug.assert(self.inner.next_operation_id > 0);

        return self.inner.caller;
    }

    pub fn now_ms(self: *const PluginCtx) i64 {
        std.debug.assert(self.inner.now_ms >= 0);
        std.debug.assert(self.inner.next_operation_id > 0);

        return self.inner.now_ms;
    }

    pub fn arena(self: *const PluginCtx) std.mem.Allocator {
        std.debug.assert(self.inner.now_ms >= 0);
        std.debug.assert(self.inner.next_operation_id > 0);

        return self.inner.arena;
    }

    pub fn call(self: *PluginCtx, comptime Operation: type, in: Operation.In) Error!Operation.Out {
        std.debug.assert(self.inner.parent != null);
        std.debug.assert(Operation.name.len > 0);

        return registry.SDK.call(self.inner, Operation, in);
    }

    pub fn notice(self: *PluginCtx, name: []const u8, subject: []const u8) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.inner.parent != null);

        self.inner.notice(name, subject);
    }

    /// A line in the log, attributed to the plugin.
    pub fn log(self: *PluginCtx, line: []const u8) void {
        std.debug.assert(line.len > 0);
        std.debug.assert(self.inner.now_ms >= 0);

        std.log.info("plugin: {s}", .{line});
    }
};

pub fn takes_plugin_ctx(comptime function: anytype) bool {
    comptime {
        const info = @typeInfo(@TypeOf(function));

        std.debug.assert(info == .@"fn");
        std.debug.assert(info.@"fn".params.len >= 1);

        return info.@"fn".params[0].type == *PluginCtx;
    }
}
