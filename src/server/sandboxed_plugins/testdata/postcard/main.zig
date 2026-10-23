//! Writes a postcard.
//!
//! A plugin only ever installed, never compiled in: what the smoke adds and enables in the
//! binary that has every other test plugin built in, so the change is heard there.
//! A plugin with no permissions, only ever installed. It adds a status to greeter's
//! salutations, which a salutation leaves by `deliver` when postcard goes, and is a
//! messaging provider for email that sends nothing: its id for a message says who it was to.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "postcard",
    .version = "0.1.0",
};

const operations = [_]type{ Write, Channels, Send };

pub const WriteIn = struct {
    /// Where it is from
    from: []const u8 = "here",
};

pub const WriteOut = struct {
    /// The postcard
    text: []const u8,
};

/// Write a postcard from somewhere
///
/// Example:
///   in: {}
///   out: { "text": "greetings from here" }
pub const Write = publr.operation.define(WriteIn, WriteOut, .{
    .name = "write",
    .kind = .read,
    .run = write,
});

fn write(ctx: *publr.Ctx, in: WriteIn) publr.Error!WriteOut {
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

pub const ChannelsIn = struct {};

pub const ChannelsOut = struct {
    /// The channels it covers
    channels: []const []const u8,
};

/// The channels postcard covers
///
/// Example:
///   in: {}
///   out: { "channels": ["email"] }
pub const Channels = publr.operation.define(ChannelsIn, ChannelsOut, .{
    .name = "channels",
    .kind = .read,
    .run = channels,
});

fn channels(_: *publr.Ctx, _: ChannelsIn) publr.Error!ChannelsOut {
    return .{
        .channels = &.{"email"},
    };
}

pub const Message = struct {
    /// `email`, `sms`, `push`
    channel: []const u8,
    /// The address on that channel
    to: []const u8,
    /// The subject
    subject: []const u8 = "",
    /// The message as plain text
    text: []const u8,
    /// The message as HTML
    html: []const u8 = "",
    /// Where a notification leads
    url: []const u8 = "",
    /// Files it carries
    attachments: []const struct {
        name: []const u8,
        url: []const u8,
    } = &.{},
};

pub const SendOut = struct {
    /// Who it was to
    id: []const u8,
};

/// Send a message, as a postcard
///
/// Sends nothing: its id for a message says who it was to.
///
/// Example:
///   in: { "channel": "email", "to": "ada@example.com", "text": "Hello" }
///   out: { "id": "postcard to ada@example.com" }
pub const Send = publr.operation.define(Message, SendOut, .{
    .name = "send",
    .kind = .write,
    .run = send,
});

fn send(ctx: *publr.Ctx, in: Message) publr.Error!SendOut {
    const id = std.fmt.allocPrint(ctx.arena(), "postcard to {s}", .{in.to}) catch {
        return error.OutOfMemory;
    };

    return .{
        .id = id,
    };
}

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
