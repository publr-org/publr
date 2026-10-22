//! Writes a postcard.
//!
//! A plugin only ever installed, never compiled in: what the smoke adds and enables in the
//! binary that has every other test plugin built in, so the change is heard there.
//! A plugin with one operation and no permissions, only ever installed. It adds a status
//! to greeter's salutations, which a salutation leaves by `deliver` when postcard goes.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;

const manifest: publr.Manifest = .{
    .name = "postcard",
    .version = "0.1.0",
};

const operations = [_]type{Write};

pub const Write = struct {
    pub const name = "postcard.write";
    pub const description = "Write a postcard from somewhere";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        from: []const u8 = "here",
    };
    pub const Out = struct {
        text: []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .text = "greetings from here",
    };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now().ms >= 0);

        if (in.from.len == 0 or in.from.len > 64) {
            return error.Invalid;
        }

        const text = std.fmt.allocPrint(ctx.arena(), "greetings from {s}", .{in.from}) catch {
            return error.OutOfMemory;
        };

        return .{
            .text = text,
        };
    }
};

pub const plugin = publr.plugin.define(manifest, .{
    .operations = operations,
    .register_statuses = .{.{
        .to = "greeter.salutation",
        .status = "posted",
        .label = "Posted",
        .transitions = .{
            .{
                .name = "post",
                .from = .{"draft"},
                .to = "posted",
                .label = "Post it",
            },
            .{
                .name = "deliver",
                .from = .{"posted"},
                .to = "published",
                .label = "Deliver",
            },
        },
    }},
});
