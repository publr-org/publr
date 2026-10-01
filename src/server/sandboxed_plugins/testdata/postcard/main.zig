//! A plugin only ever installed, never compiled in: what the smoke adds and enables in the
//! binary that has every other test plugin built in, so the change is heard there.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;

pub const manifest: publr.plugin.Manifest = .{
    .name = "postcard",
    .version = "0.1.0",
    .summary = "Writes a postcard",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "postcard",
    .summary = "Postcards",
    .details = "A plugin with one operation and no permissions, only ever installed.",
}};

pub const operations = [_]type{Write};

pub const Write = struct {
    pub const name = "postcard.write";
    pub const description = "Write a postcard from somewhere";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { from: []const u8 = "here" };
    pub const Out = struct { text: []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .text = "greetings from here" };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        if (in.from.len == 0 or in.from.len > 64) {
            return error.Invalid;
        }

        const text = std.fmt.allocPrint(ctx.arena(), "greetings from {s}", .{in.from}) catch {
            return error.OutOfMemory;
        };

        return .{ .text = text };
    }
};
