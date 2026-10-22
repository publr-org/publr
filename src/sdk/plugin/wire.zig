//! What crosses the sandbox's boundary, shared by the host and the guest: both are built from
//! this file, so a status means the same on either side. Everything else is JSON.
const std = @import("std");
const operation = @import("../operation.zig");

pub const Error = operation.Error;

/// Every call answers 0 or the code of one error of the SDK's set.
pub const ok: u32 = 0;

/// A result the host writes into the guest's memory: where its output is and how long.
pub const Result = extern struct {
    ptr: u32,
    len: u32,
};

pub const result_bytes: u32 = @sizeOf(Result);

/// Every error of the SDK's set, in the order that numbers them on the wire. The order of an
/// error set's `@typeInfo` differs between two compilations, so it is written out here, once,
/// and a new error the set gains fails to compile until it is listed.
const names = [_][]const u8{
    "Denied",     "Invalid",     "NotFound",       "Conflict",           "Throttled",
    "Failed",     "Unavailable", "BadCredentials", "InvalidationFailed", "Sqlite",
    "Constraint", "Busy",        "ReadOnly",       "OutOfMemory",        "Interrupted",
    "TooBig",     "NotYet",
};

comptime {
    for (@typeInfo(Error).error_set.?) |item| {
        var listed = false;

        for (names) |name| {
            listed = listed or std.mem.eql(u8, name, item.name);
        }

        if (!listed) {
            @compileError("the sandbox's wire does not number error." ++ item.name);
        }
    }
}

pub fn code_of(err: Error) u32 {
    inline for (names, 0..) |name, index| {
        if (err == @field(Error, name)) {
            return index + 1;
        }
    }

    unreachable;
}

/// The error a code stands for; a code no build knows is `Invalid`, never a crash.
pub fn error_of(code: u32) Error {
    std.debug.assert(code != ok);

    inline for (names, 0..) |name, index| {
        if (code == index + 1) {
            return @field(Error, name);
        }
    }

    return error.Invalid;
}

/// Who is calling, as the host's `ctx.caller()` sees it, so the guest's answers the same.
pub const Caller = struct {
    from: @import("caller_view.zig").Kind = .plugin,
    /// The calling plugin's name when `from` is `.plugin`.
    plugin: []const u8 = "",
    /// The other site that sent the request, when one did.
    referer: []const u8 = "",
    signed_in: bool = false,
    roles: []const []const u8 = &.{},
    granted: bool = false,
};

/// What the guest reads around its entry's own input: when it runs and for whom, whether a
/// queued job runs its last attempt, and the operation's answer an `after` hook reads. `Out`
/// is `struct {}` for every entry but an `after` hook.
pub fn Envelope(comptime In: type, comptime Out: type) type {
    return struct {
        now_ms: i64,
        on_behalf_of: ?[]const u8 = null,
        visitor: []const u8 = "",
        caller: Caller = .{},
        last: bool = false,
        in: In,
        out: ?Out = null,
    };
}

test "every error round-trips through its code; unknown codes are Invalid" {
    const all = @typeInfo(Error).error_set.?;

    inline for (all) |item| {
        const err = @field(Error, item.name);

        try std.testing.expectEqual(err, error_of(code_of(err)));
    }

    try std.testing.expectEqual(@as(u32, 1), code_of(error.Denied));
    try std.testing.expectEqual(@as(u32, 2), code_of(error.Invalid));
    try std.testing.expectEqual(error.Invalid, error_of(10_000));
}
