//! `publr.ExchangeCtx`: what a sign-in provider's `exchange` runs with, the one step of a
//! sign-in that waits on another server. It can send requests to the provider plugin's own
//! `http.fetch` domains, through the same guard as `ctx.fetch` (secrets filled as they
//! leave, every hop logged), within what is left of the step's time, and log; nothing else:
//! no calls, no records, no session. Publr hands it over; what lies behind it is Publr's.
const std = @import("std");
const words = @import("plugin/words.zig");
const Exchange = @import("../sdk/plugin/exchange.zig").Exchange;
const Error = @import("../sdk/operation.zig").Error;
const http_operations = @import("operations/http.zig");

fn BehindOf(comptime Pointer: type) type {
    return if (@typeInfo(Pointer).pointer.attrs.@"const") *const Exchange else *Exchange;
}

fn behind(ctx: anytype) BehindOf(@TypeOf(ctx)) {
    return @ptrCast(@alignCast(ctx));
}

pub const ExchangeCtx = opaque {
    /// A request to the provider, as its plugin: only to its `http.fetch` domains,
    /// `{secret:NAME}` filled in as it leaves. `Unavailable` once the step's time is spent.
    pub fn fetch(
        ctx: *ExchangeCtx,
        request: http_operations.Fetch.In,
    ) Error!http_operations.Fetch.Out {
        return behind(ctx).fetch(request);
    }

    /// The step's time, one value for the whole step.
    pub fn now(ctx: *const ExchangeCtx) words.Time {
        return behind(ctx).now();
    }

    /// Memory freed when the request ends.
    pub fn arena(ctx: *const ExchangeCtx) std.mem.Allocator {
        return behind(ctx).arena();
    }

    /// Formatted text in memory freed when the request ends.
    pub fn print(
        ctx: *const ExchangeCtx,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        return behind(ctx).print(format, args);
    }

    /// A line on the provider plugin's log, under `sign_in:<provider>`.
    pub fn log(
        ctx: *ExchangeCtx,
        comptime level: words.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        behind(ctx).log(level, format, args);
    }
};
