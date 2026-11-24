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
const std = @import("std");
const sdk = @import("../sdk.zig");
const contract_module = @import("contract.zig");
const event = @import("plugin/hook_define.zig").event;
const delivery = @import("messaging/delivery.zig");

pub const channel_len_max: u32 = 32;

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

            const message = try finished(ctx.arena, message_of(channel, payload), payload);

            // Marketing mail always says where to stop it.
            if (message.stream == .marketing and message.headers.len == 0) {
                return error.Invalid;
            }

            _ = try deliver(ctx, message);
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
        .stream = if (@hasField(Payload, "stream")) payload.stream else .transactional,
        .from = if (@hasField(Payload, "from")) payload.from else "",
        .reply_to = if (@hasField(Payload, "reply_to")) payload.reply_to else "",
        .reference = if (@hasField(Payload, "reference")) payload.reference else "",
        .sender = if (@hasField(Payload, "sender")) payload.sender else "",
    };
}

/// An emitted message (`messaging.email`, `sms`, `push`, its payload as JSON) with `sender`
/// written as the plugin emitting it, over any it gave, so a provider knows whose it is;
/// any other event as it is.
pub fn signed(
    arena: std.mem.Allocator,
    name: []const u8,
    payload: []const u8,
    plugin: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(payload.len > 0);

    const message = std.mem.eql(u8, name, Email.full_name) or
        std.mem.eql(u8, name, Sms.full_name) or std.mem.eql(u8, name, Push.full_name);

    if (!message or plugin.len == 0) {
        return payload;
    }

    var parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch {
        return payload;
    };

    if (parsed != .object) {
        return payload;
    }

    try parsed.object.put(arena, "sender", .{
        .string = plugin,
    });

    return std.json.Stringify.valueAlloc(arena, parsed, .{});
}

test "an emitted message names the plugin that emitted it, over any it gave" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const given = "{\"to\":\"ada@example.com\",\"subject\":\"Hi\",\"text\":\"Hi\"," ++
        "\"sender\":\"someone\"}";
    const made = try signed(arena, Email.full_name, given, "orders");
    const read = try std.json.parseFromSliceLeaky(Email.Payload, arena, made, .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expectEqualStrings("orders", read.sender);
    try std.testing.expectEqualStrings("orders", message_of("email", read).sender);
    try std.testing.expectEqualStrings(given, try signed(arena, "orders.paid", given, "orders"));
}

/// The message as it leaves: its preheader opening the HTML, hidden; the one-click
/// unsubscribe headers for its `unsubscribe` address.
fn finished(arena: std.mem.Allocator, message: Message, payload: anytype) error{
    OutOfMemory,
}!Message {
    const Payload = @TypeOf(payload);

    std.debug.assert(message.channel.len > 0);

    var out = message;

    if (comptime @hasField(Payload, "preheader")) {
        if (payload.preheader.len > 0 and message.html.len > 0) {
            out.html = try with_preheader(arena, message.html, payload.preheader);
        }
    }

    if (comptime @hasField(Payload, "unsubscribe")) {
        if (payload.unsubscribe.len > 0) {
            const headers = try arena.alloc(Header, 2);

            headers[0] = .{
                .name = "List-Unsubscribe",
                .value = try std.mem.concat(arena, u8, &.{ "<", payload.unsubscribe, ">" }),
            };
            headers[1] = .{
                .name = "List-Unsubscribe-Post",
                .value = "List-Unsubscribe=One-Click",
            };
            out.headers = headers;
        }
    }

    return out;
}

/// `html` with the preheader first in its body (after `<body ...>`), or first of all when
/// it has no body: never before `<!DOCTYPE html>`, which a mail app then ignores.
fn with_preheader(
    arena: std.mem.Allocator,
    html: []const u8,
    preheader: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(html.len > 0);
    std.debug.assert(preheader.len > 0);

    const hidden = try std.mem.concat(arena, u8, &.{
        "<div style=\"display:none;max-height:0;overflow:hidden;opacity:0\">",
        try escaped(arena, preheader),
        "</div>",
    });
    const lower = try std.ascii.allocLowerString(arena, html);
    const body = std.mem.indexOf(u8, lower, "<body") orelse {
        return std.mem.concat(arena, u8, &.{ hidden, html });
    };
    const opened = std.mem.indexOfScalarPos(u8, html, body, '>') orelse {
        return std.mem.concat(arena, u8, &.{ hidden, html });
    };

    return std.mem.concat(arena, u8, &.{ html[0 .. opened + 1], hidden, html[opened + 1 ..] });
}

test "a preheader goes first in the body, after the doctype and head" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = "<!DOCTYPE html><html><head></head><BODY class=\"x\"><p>Hi</p></body></html>";
    const made = try with_preheader(arena, page, "Your order");

    try std.testing.expect(std.mem.startsWith(u8, made, "<!DOCTYPE html><html><head></head>" ++
        "<BODY class=\"x\"><div style="));
    try std.testing.expect(std.mem.indexOf(u8, made, "Your order</div><p>Hi</p>") != null);

    const bare = try with_preheader(arena, "<p>Hi</p>", "Soon");

    try std.testing.expect(std.mem.startsWith(u8, bare, "<div style="));
}

fn escaped(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(text.len <= 64 << 10);

    var out: std.ArrayList(u8) = .empty;

    for (text) |char| {
        switch (char) {
            '<' => try out.appendSlice(arena, "&lt;"),
            '>' => try out.appendSlice(arena, "&gt;"),
            '&' => try out.appendSlice(arena, "&amp;"),
            '"' => try out.appendSlice(arena, "&quot;"),
            else => try out.append(arena, char),
        }
    }

    return out.items;
}

/// Hands `message` to the first enabled provider that covers its channel (and its
/// attachments, when it has any): that provider's id for it, or null when no provider
/// covers it and nothing was sent.
pub fn deliver(ctx: *sdk.Ctx, given: Message) sdk.Error!?[]const u8 {
    std.debug.assert(given.channel.len > 0 and given.channel.len <= channel_len_max);

    // A copy of the site mails its staff alone.
    if (ctx.on_copy and !try delivery.staff_address(ctx, given.channel, given.to)) {
        std.log.info("messaging: a copy of the site keeps back a message to a customer", .{});
        return null;
    }

    const message = try delivery.with_files(ctx, given);
    const files = message.attachments.len > 0;
    const can: []const []const u8 = if (files) &.{"attachments"} else &.{};
    const found = try contract_module.providers(ctx, contract, .{});

    for (found) |provider| {
        if (!provider.registered.has_all(can)) {
            continue;
        }

        const covered = try provider.call(ctx, .channels, .{});
        const takes_stream = covered.streams.len == 0 or
            listed(covered.streams, @tagName(message.stream));

        if (!listed(covered.channels, message.channel) or !takes_stream) {
            continue;
        }

        const sent = if (files)
            try provider.optional(.attachments).?.call(ctx, message)
        else
            try provider.call(ctx, .send, message);

        try delivery.keep_sent(ctx, provider.registered.name, sent.id, message);

        return sent.id;
    }

    return null;
}

/// Whether an emitted email (`messaging.email`, its payload as JSON) carries any of the
/// site's media: its emitter must be able to read media (`media.read`).
pub fn carries_media(arena: std.mem.Allocator, name: []const u8, payload: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(payload.len > 0);

    if (!std.mem.eql(u8, name, Email.full_name)) {
        return false;
    }

    const Carried = struct {
        attachments: []const struct {
            media: []const u8 = "",
        } = &.{},
    };
    const carried = std.json.parseFromSliceLeaky(Carried, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return true;

    for (carried.attachments) |attachment| {
        if (attachment.media.len > 0) {
            return true;
        }
    }

    return false;
}

/// Whether every file an emitted email carries is one `plugin` made (`media.make`, a file of
/// one of its own media types): its own files attach without `media.read`.
pub fn carries_own_files_only(ctx: *sdk.Ctx, plugin: []const u8, payload: []const u8) bool {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(payload.len > 0);

    const store = @import("../store.zig");
    const Carried = struct {
        attachments: []const struct {
            media: []const u8 = "",
        } = &.{},
    };
    const carried = std.json.parseFromSliceLeaky(Carried, ctx.arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return false;

    for (carried.attachments) |attachment| {
        if (attachment.media.len == 0) {
            continue;
        }

        const found = store.records.get(ctx.db, ctx.arena, attachment.media) catch return false;
        const record = found orelse return false;
        const type_found = store.content_types.get_by_id(ctx.db, ctx.arena, record.type_id) catch
            return false;
        const type_row = type_found orelse return false;
        const own = type_row.def.kind == .media and std.mem.eql(u8, type_row.def.owner, plugin);

        if (!own) {
            return false;
        }
    }

    return true;
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
