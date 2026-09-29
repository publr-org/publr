//! The smallest installed plugin: one operation, nothing asked for. What parity installs.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;

pub const manifest: publr.plugin.Manifest = .{
    .name = "farewell",
    .version = "0.1.0",
    .summary = "Says goodbye",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "farewell",
    .summary = "Goodbyes",
    .details = "A plugin with one operation and no permissions.",
}};

pub const operations = [_]type{ Say, Last };

pub const Say = struct {
    pub const name = "farewell.say";
    pub const description = "Say goodbye to someone";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { who: []const u8 = "world" };
    pub const Out = struct { text: []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .text = "goodbye, world" };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        if (in.who.len == 0 or in.who.len > 64) {
            return error.Invalid;
        }

        const text = std.fmt.allocPrint(ctx.arena(), "goodbye, {s}", .{in.who}) catch {
            return error.OutOfMemory;
        };

        return .{ .text = text };
    }
};

/// Guards the build of plugins: an insert at the front of a list moves the rest up with an
/// overlapping copy, which Zig's wasm backend gets wrong without `bulk_memory`.
pub const Last = struct {
    pub const name = "farewell.last";
    pub const description = "Say goodbye to the last one first";
    pub const details = "Anyone who may say goodbye may call it; it never fails.";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { order: []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .order = "carol, alice, bob" };

    pub fn run(ctx: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        var names: std.ArrayList([]const u8) = .empty;

        names.appendSlice(ctx.arena(), &.{ "alice", "bob" }) catch return error.OutOfMemory;
        names.insert(ctx.arena(), 0, "carol") catch return error.OutOfMemory;

        const order = std.mem.join(ctx.arena(), ", ", names.items) catch return error.OutOfMemory;

        return .{ .order = order };
    }
};
