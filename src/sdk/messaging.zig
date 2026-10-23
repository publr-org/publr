//! Messages: Publr sends nothing on its own. A send is a typed event, `ctx.emit(
//! publr.messaging.Email, .{ .to, .subject, .text })` (and `Sms`, `Push`), and core's
//! `messaging` contract is what providers implement: `channels` (which they cover) and
//! `send`, with `attachments` optional. From the queue, once the write committed, core hands
//! each message to the first enabled provider, in the administrator's order, that covers its
//! channel; that run may call out (`http.fetch`). With no provider nobody hears it: nothing
//! happens and nothing fails.
const std = @import("std");
const sdk = @import("../sdk.zig");
const contract_module = @import("contract.zig");
const event = @import("plugin/hook_define.zig").event;

pub const channel_len_max: u32 = 32;

/// A file a message carries: its name and the address the provider fetches it from.
pub const Attachment = struct {
    name: []const u8,
    url: []const u8,
};

/// What a provider sends: one message on one channel.
pub const Message = struct {
    /// `email`, `sms`, `push`
    channel: []const u8,
    /// The address on that channel: an email, a phone number, a device's token
    to: []const u8,
    /// The subject or the notification's title; empty for an SMS
    subject: []const u8 = "",
    /// The message as plain text
    text: []const u8,
    /// The message as HTML, for an email; empty when it is text only
    html: []const u8 = "",
    /// Where a notification leads; empty when nowhere
    url: []const u8 = "",
    attachments: []const Attachment = &.{},
};

/// `channels`: the channels the provider covers.
pub const Channels = struct {
    pub const In = struct {};
    pub const Out = struct {
        channels: []const []const u8,
    };
};

/// `send`: one message, answered with the provider's id for it.
pub const Send = struct {
    pub const In = Message;
    pub const Out = struct {
        id: []const u8 = "",
    };
};

/// The messaging contract, core's: required `channels` and `send`, optional `attachments`
/// (the provider sends a message's files with it; one without is never handed a message
/// that has some).
pub const contract = contract_module.define(.{
    .name = "messaging",
    .operations = .{
        .channels = Channels,
        .send = Send,
    },
    .optional = .{
        .attachments = Send,
    },
});

/// An email to send: heard by the messaging provider that covers `email`.
pub const Email = event(.{
    .name = "messaging.email",
    .payload = struct {
        /// The recipient's email address
        to: []const u8,
        /// The subject line
        subject: []const u8,
        /// The message as plain text
        text: []const u8,
        /// The message as HTML; empty for text only
        html: []const u8 = "",
        /// Files sent with it
        attachments: []const Attachment = &.{},
    },
});

/// A text message to send: heard by the messaging provider that covers `sms`.
pub const Sms = event(.{
    .name = "messaging.sms",
    .payload = struct {
        /// The recipient's phone number, international form
        to: []const u8,
        /// The message
        text: []const u8,
    },
});

/// A push notification to send: heard by the messaging provider that covers `push`.
pub const Push = event(.{
    .name = "messaging.push",
    .payload = struct {
        /// The device's token at the push service
        to: []const u8,
        /// The notification's title
        title: []const u8,
        /// The notification's text
        text: []const u8,
        /// Where tapping it leads; empty when nowhere
        url: []const u8 = "",
    },
});

/// Core's `on` hooks on the message events: each message handed to its provider from the
/// queue.
pub const hooks = [_]type{
    Deliver(Email, "email"),
    Deliver(Sms, "sms"),
    Deliver(Push, "push"),
};

fn Deliver(comptime Event: type, comptime channel: []const u8) type {
    return struct {
        pub const stage: sdk.hooks.Stage = .on;
        pub const event = Event.full_name;
        pub const Payload = Event.Payload;

        pub fn run(ctx: *sdk.Ctx, payload: Payload) sdk.Error!void {
            std.debug.assert(ctx.now_ms >= 0);

            _ = try deliver(ctx, message_of(channel, payload));
        }
    };
}

fn message_of(comptime channel: []const u8, payload: anytype) Message {
    const Payload = @TypeOf(payload);

    comptime std.debug.assert(channel.len <= channel_len_max);

    return .{
        .channel = channel,
        .to = payload.to,
        .subject = if (@hasField(Payload, "subject"))
            payload.subject
        else if (@hasField(Payload, "title")) payload.title else "",
        .text = payload.text,
        .html = if (@hasField(Payload, "html")) payload.html else "",
        .url = if (@hasField(Payload, "url")) payload.url else "",
        .attachments = if (@hasField(Payload, "attachments")) payload.attachments else &.{},
    };
}

/// Hands `message` to the first enabled provider that covers its channel (and its
/// attachments, when it has any): that provider's id for it, or null when no provider
/// covers it and nothing was sent.
pub fn deliver(ctx: *sdk.Ctx, message: Message) sdk.Error!?[]const u8 {
    std.debug.assert(message.channel.len > 0 and message.channel.len <= channel_len_max);

    const files = message.attachments.len > 0;
    const can: []const []const u8 = if (files) &.{"attachments"} else &.{};
    const found = try contract_module.providers(ctx, contract, .{});

    for (found) |provider| {
        if (!provider.registered.has_all(can)) {
            continue;
        }

        const covered = try provider.call(ctx, .channels, .{});

        if (!listed(covered.channels, message.channel)) {
            continue;
        }

        const sent = if (files)
            try provider.optional(.attachments).?.call(ctx, message)
        else
            try provider.call(ctx, .send, message);

        return sent.id;
    }

    return null;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

test "a message carries what its event said, on its channel" {
    const email = message_of("email", Email.Payload{
        .to = "ada@example.com",
        .subject = "Your order",
        .text = "Thanks",
    });

    try std.testing.expectEqualStrings("email", email.channel);
    try std.testing.expectEqualStrings("Your order", email.subject);

    const push = message_of("push", Push.Payload{
        .to = "token",
        .title = "Shipped",
        .text = "On its way",
        .url = "/orders/1",
    });

    try std.testing.expectEqualStrings("Shipped", push.subject);
    try std.testing.expectEqualStrings("/orders/1", push.url);
}
