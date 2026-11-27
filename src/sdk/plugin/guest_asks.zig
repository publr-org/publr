//! What an installed plugin's ctx asks the host beside calling operations, as a compiled-in
//! one asks: whether a call would be let in (`may`), what the last refusal says to people
//! (`failure_message`), the plugin alone with no person behind it (`as_plugin`), and a
//! message known only as the code runs, in a person's words (`locale.say`).
const std = @import("std");
const wire = @import("wire.zig");
const guest = @import("guest.zig");
const Ctx = @import("../../publr/ctx.zig").Ctx;
const Said = @import("../../publr/ctx/said.zig").Said;

const SandboxApi = guest.SandboxApi;

extern "env" fn publr_may(name_ptr: [*]const u8, name_len: u32, alone: u32) u32;
extern "env" fn publr_failure_message(result: *wire.Result) u32;

/// The same plugin, its calls made as itself alone: no person behind them, its grants
/// deciding unnarrowed.
pub fn as_plugin(api: *SandboxApi) wire.Error!*Ctx {
    std.debug.assert(api.name.len > 0);

    const made = api.arena_allocator.create(SandboxApi) catch return error.OutOfMemory;

    made.* = api.*;
    made.on_behalf_of = null;
    made.alone = true;
    // What it read for the person is not what it reads alone.
    made.memo = null;
    made.facts.signed_in = false;
    made.facts.roles = &.{};
    made.last_failure = "";
    made.last_message = "";

    return made.ctx();
}

/// Whether the host would let a call of `Operation` in, as this ctx calls. Asking needs no
/// grant: what the plugin holds none for answers false.
pub fn may(api: *const SandboxApi, comptime Operation: type) bool {
    const own = comptime @hasDecl(Operation, "publr_operation_definition");

    std.debug.assert(api.name.len > 0);

    var buffer: [256]u8 = undefined;
    const name = if (own)
        std.fmt.bufPrint(&buffer, "{s}.{s}", .{ api.name, Operation.verb }) catch return false
    else
        Operation.name;

    return publr_may(name.ptr, @intCast(name.len), @intFromBool(api.alone)) == 1;
}

/// What the refusal the last call met says to people, as the host has it; empty when it
/// says nothing or cannot be read.
pub fn message_of_refusal(api: *const SandboxApi) []const u8 {
    std.debug.assert(api.name.len > 0);

    var result: wire.Result = .{
        .ptr = 0,
        .len = 0,
    };

    if (publr_failure_message(&result) != wire.ok or result.len == 0) {
        return "";
    }

    const told = guest.take(result);
    defer guest_free(told);

    return api.arena_allocator.dupe(u8, told) catch "";
}

fn guest_free(bytes: []u8) void {
    if (bytes.len > 0) {
        @import("guest_memory.zig").heap.free(bytes);
    }
}

/// The last refusal's words: the host's for a call refused, the plugin's own after `fail`.
pub fn failure_message(api: *const SandboxApi) []const u8 {
    std.debug.assert(api.name.len > 0);

    return api.last_message;
}

/// `text`, marked where it was written (`publr.t`), in the call's language, each `{name}`
/// filled from `values`.
pub fn said_values(
    api: *const SandboxApi,
    code: []const u8,
    text: []const u8,
    values: []const Said,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(text.len > 0);
    std.debug.assert(values.len <= 64);
    _ = code;

    var out = api.translate(text);

    for (values) |value| {
        const hole = try std.fmt.allocPrint(api.arena_allocator, "{{{s}}}", .{value.name});

        out = try std.mem.replaceOwned(u8, api.arena_allocator, out, hole, value.value);
    }

    return out;
}
