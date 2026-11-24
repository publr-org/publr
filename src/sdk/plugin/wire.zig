//! What crosses the sandbox's boundary, shared by the host and the guest: both are built from
//! this file, so a status means the same on either side. Values cross in the plugin's own
//! structs (`shape_wire.zig`).
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
    for (@typeInfo(Error).error_set.error_names.?) |item_name| {
        var listed = false;

        for (names) |name| {
            listed = listed or std.mem.eql(u8, name, item_name);
        }

        if (!listed) {
            @compileError("the sandbox's wire does not number error." ++ item_name);
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

/// One message asked of the host's catalogues (`publr_translate`): where its texts are in
/// the guest's memory, and the number its plural is chosen by, when it has one.
pub const Message = extern struct {
    context: u32,
    context_len: u32,
    id: u32,
    id_len: u32,
    plural: u32,
    plural_len: u32,
    counted: u32,
    count: f64,

    pub fn of(context: []const u8, id: []const u8, plural: []const u8, count: ?f64) Message {
        std.debug.assert(id.len > 0);

        return .{
            .context = @truncate(@intFromPtr(context.ptr)),
            .context_len = @intCast(context.len),
            .id = @truncate(@intFromPtr(id.ptr)),
            .id_len = @intCast(id.len),
            .plural = @truncate(@intFromPtr(plural.ptr)),
            .plural_len = @intCast(plural.len),
            .counted = @intFromBool(count != null),
            .count = count orelse 0,
        };
    }
};

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

/// The answer an entry is handed when it reads none: every entry but an `after` hook.
pub const None = struct {};

/// What the guest reads around its entry's own input: when it runs and for whom, whether a
/// queued job runs its last attempt, and the operation's answer an `after` hook reads. `Out`
/// is `None` for every entry but an `after` hook.
pub fn Envelope(comptime In: type, comptime Out: type) type {
    return struct {
        now_ms: i64,
        on_behalf_of: ?[]const u8 = null,
        visitor: []const u8 = "",
        caller: Caller = .{},
        /// The language the call speaks (`pl`); empty when none is known.
        language: []const u8 = "",
        last: bool = false,
        in: In,
        out: ?Out = null,
    };
}

test "every error round-trips through its code; unknown codes are Invalid" {
    const all = @typeInfo(Error).error_set.error_names.?;

    inline for (all) |item_name| {
        const err = @field(Error, item_name);

        try std.testing.expectEqual(err, error_of(code_of(err)));
    }

    try std.testing.expectEqual(@as(u32, 1), code_of(error.Denied));
    try std.testing.expectEqual(@as(u32, 2), code_of(error.Invalid));
    try std.testing.expectEqual(error.Invalid, error_of(10_000));
}
