//! Says goodbye.
//!
//! The smallest installed plugin: one operation, nothing asked for. What parity installs.
//! A plugin with one operation and no permissions.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "farewell",
    .version = "0.1.0",
};

const operations = [_]type{ Say, Last };

pub const SayIn = struct {
    /// Who to say goodbye to
    who: []const u8 = "world",
};

pub const SayOut = struct {
    /// The goodbye
    text: []const u8,
};

/// Say goodbye to someone
///
/// Example:
///   in: {}
///   out: { "text": "goodbye, world" }
pub const Say = publr.operation.define(SayIn, SayOut, .{
    .name = "say",
    .kind = .read,
    .run = say,
});

fn say(ctx: *publr.Ctx, in: SayIn) publr.Error!SayOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.who.len == 0 or in.who.len > 64) {
        return error.Invalid;
    }

    const text = std.fmt.allocPrint(ctx.arena(), "goodbye, {s}", .{in.who}) catch {
        return error.OutOfMemory;
    };

    return .{
        .text = text,
    };
}

pub const LastIn = struct {};

pub const LastOut = struct {
    /// Who is said goodbye to, in order
    order: []const u8,
};

/// Say goodbye to the last one first
///
/// Anyone who may say goodbye may call it; it never fails. Guards the build of plugins: an
/// insert at the front of a list moves the rest up with an overlapping copy, which Zig's wasm
/// backend gets wrong without `bulk_memory`.
///
/// Example:
///   in: {}
///   out: { "order": "carol, alice, bob" }
pub const Last = publr.operation.define(LastIn, LastOut, .{
    .name = "last",
    .kind = .read,
    .run = last,
});

fn last(ctx: *publr.Ctx, _: LastIn) publr.Error!LastOut {
    std.debug.assert(ctx.now().ms >= 0);

    var names: std.ArrayList([]const u8) = .empty;

    names.appendSlice(ctx.arena(), &.{ "alice", "bob" }) catch return error.OutOfMemory;
    names.insert(ctx.arena(), 0, "carol") catch return error.OutOfMemory;

    const order = std.mem.join(ctx.arena(), ", ", names.items) catch return error.OutOfMemory;

    return .{
        .order = order,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = operations,
});
