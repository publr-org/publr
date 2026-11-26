//! Core's delivery of the messages plugins send (`publr/messaging.zig`): from the queue, once
//! the write committed, each message goes to the first enabled provider of the `messaging`
//! contract, in the administrator's order, that covers its channel and its stream.
const std = @import("std");
const sdk = @import("../sdk.zig");
const contract_module = @import("contract.zig");
const public = @import("../publr/messaging.zig");
const delivery = @import("messaging/delivery.zig");

pub const Attachment = public.Attachment;
pub const Stream = public.Stream;
pub const Header = public.Header;
pub const Message = public.Message;
pub const Channels = public.Channels;
pub const Send = public.Send;
pub const contract = public.contract;
pub const Email = public.Email;
pub const Bounced = public.Bounced;
pub const Complained = public.Complained;
pub const Feedback = public.Feedback;
pub const Sms = public.Sms;
pub const Push = public.Push;

pub const channel_len_max: u32 = 32;

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
