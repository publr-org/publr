//! Messages: Publr sends nothing on its own. A send is a typed event, `ctx.emit(
//! publr.messaging.Email, .{ .to, .subject, .text })` (and `Sms`, `Push`), and core's
//! `messaging` contract is what providers implement: `channels` (which they cover) and
//! `send`, with `attachments` optional. From the queue, once the write committed, core hands
//! each message to the first enabled provider, in the administrator's order, that covers its
//! channel and its stream; that run may call out (`http.fetch`). With no provider nobody
//! hears it: nothing happens and nothing fails.
//!
//! A message is transactional (a receipt, a password link) or marketing (a newsletter, a
//! cart reminder): a provider may take only one stream (`channels` answers `streams`), so
//! bulk mail goes through a bulk provider and receipts through another. A marketing message
//! says where to stop them (`unsubscribe`): core writes `List-Unsubscribe` and
//! `List-Unsubscribe-Post` (one click, RFC 8058). A preheader opens the HTML hidden. Files
//! a message carries are the site's own media, by id: core hands the provider their bytes.
//! A copy of the site (an environment, a branch) sends to staff accounts alone, never to a
//! customer or a visitor. What a provider answered is kept with the sender's `reference`,
//! so a bounce or a complaint it reports later (`messaging.feedback`) names the send.
const contract_module = @import("contract.zig");
const event = @import("plugin/hook_define.zig").event;

/// A file a message carries: one of the site's media by id (`media`), whose bytes core
/// hands the provider in `content` (base64) with its `content_type`; or an address the
/// provider fetches (`url`).
pub const Attachment = struct {
    name: []const u8,
    url: []const u8 = "",
    media: []const u8 = "",
    content_type: []const u8 = "",
    content: []const u8 = "",
};

/// Which kind of mail a message is: what the recipient asked for or expects (a receipt, a
/// password link), or what they may stop (a newsletter, a reminder).
pub const Stream = enum { transactional, marketing };

/// A header core writes on a message (`List-Unsubscribe`).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
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
    stream: Stream = .transactional,
    /// Who it is from (`Shop <shop@example.com>`); empty: the provider's own
    from: []const u8 = "",
    /// Where answers go; empty: back to `from`
    reply_to: []const u8 = "",
    /// Headers core writes: `List-Unsubscribe` and `List-Unsubscribe-Post` for one with an
    /// `unsubscribe` address
    headers: []const Header = &.{},
    /// The sender's own reference for the send (an order's id), kept with what the provider
    /// answers and named again when it reports a bounce or a complaint
    reference: []const u8 = "",
    /// The plugin that emitted it (`orders`), as core saw it emit; empty for Publr's own
    sender: []const u8 = "",
};

/// `channels`: the channels the provider covers.
pub const Channels = struct {
    pub const In = struct {};
    pub const Out = struct {
        channels: []const []const u8,
        /// The streams it takes (`transactional`, `marketing`); empty: every one.
        streams: []const []const u8 = &.{},
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
        /// `transactional` (a receipt, a password link) or `marketing` (a newsletter, a
        /// reminder), which needs `unsubscribe`
        stream: Stream = .transactional,
        /// Who it is from (`Shop <shop@example.com>`); empty: the provider's own
        from: []const u8 = "",
        /// Where answers go; empty: back to the sender
        reply_to: []const u8 = "",
        /// The line a mail app shows after the subject, opening the HTML hidden
        preheader: []const u8 = "",
        /// Where the recipient stops mail like this (a signed link): written as
        /// `List-Unsubscribe`, one click
        unsubscribe: []const u8 = "",
        /// The sender's reference for the send, named again in a bounce or a complaint
        reference: []const u8 = "",
        /// The plugin that emits it: core writes it as the plugin emits, over any given
        sender: []const u8 = "",
    },
});

/// A message the recipient's server refused for good (`permanent`) or for now: heard by
/// whoever keeps who may be mailed.
pub const Bounced = event(.{
    .name = "messaging.bounced",
    .payload = Feedback,
});

/// A recipient marked a message as spam.
pub const Complained = event(.{
    .name = "messaging.complained",
    .payload = Feedback,
});

/// What a provider reported of a message it sent.
pub const Feedback = struct {
    /// The address it was sent to
    to: []const u8,
    /// The provider that sent it
    provider: []const u8,
    /// The provider's id for the message
    message: []const u8,
    /// The sender's reference for the send; empty when it gave none
    reference: []const u8 = "",
    /// Whether the address will never take mail (a bounce); a complaint is
    permanent: bool = true,
    /// The provider's words for why
    reason: []const u8 = "",
};

/// A text message to send: heard by the messaging provider that covers `sms`.
pub const Sms = event(.{
    .name = "messaging.sms",
    .payload = struct {
        /// The recipient's phone number, international form
        to: []const u8,
        /// The message
        text: []const u8,
        /// The plugin that emits it: core writes it as the plugin emits, over any given
        sender: []const u8 = "",
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
        /// The plugin that emits it: core writes it as the plugin emits, over any given
        sender: []const u8 = "",
    },
});
