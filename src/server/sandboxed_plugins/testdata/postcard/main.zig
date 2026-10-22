//! Writes a postcard.
//!
//! A plugin only ever installed, never compiled in: what the smoke adds and enables in the
//! binary that has every other test plugin built in, so the change is heard there.
//! A plugin with no permissions, only ever installed. It adds a status to greeter's
//! salutations, which a salutation leaves by `deliver` when postcard goes, and is a
//! messaging provider for email that sends nothing: its id for a message says who it was to.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;

const manifest: publr.Manifest = .{
    .name = "postcard",
    .version = "0.1.0",
};

const operations = [_]type{ Write, Channels, Send };

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

pub const Channels = struct {
    pub const name = "postcard.channels";
    pub const description = "The channels postcard covers";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = publr.messaging.Channels.In;
    pub const Out = publr.messaging.Channels.Out;
    pub const example: In = .{};
    pub const example_out: Out = .{
        .channels = &.{"email"},
    };

    pub fn run(_: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        return example_out;
    }
};

pub const Send = struct {
    pub const name = "postcard.send";
    pub const description = "Send a message, as a postcard";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = publr.messaging.Message;
    pub const Out = publr.messaging.Send.Out;
    pub const example: In = .{
        .channel = "email",
        .to = "ada@example.com",
        .text = "Hello",
    };
    pub const example_out: Out = .{
        .id = "postcard to ada@example.com",
    };

    pub fn run(ctx: *PluginCtx, in: In, _: *const sdk.Grant) sdk.Error!Out {
        const id = std.fmt.allocPrint(ctx.arena(), "postcard to {s}", .{in.to}) catch {
            return error.OutOfMemory;
        };

        return .{
            .id = id,
        };
    }
};

pub const plugin = publr.plugin.define(manifest, .{
    .operations = operations,
    .register_providers = .{.{
        .contract = publr.messaging.contract,
        .name = "postcard",
        .operations = .{
            .channels = Channels,
            .send = Send,
        },
    }},
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
