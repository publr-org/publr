//! What core does to a message on its way to a provider: on a copy of the site, whether its
//! recipient is staff; the bytes of the site's media it carries; what the provider answered,
//! kept with the sender's reference for the feedback that may follow.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const messaging = @import("../messaging.zig");

/// The most a message's files take together.
pub const files_bytes_max: u32 = 10 << 20;
/// How long what a provider answered is kept, for the feedback it reports later.
pub const sent_keep_ms: i64 = 90 * 24 * 60 * 60 * 1000;

/// Where what providers answered is kept: core's own internal records, one per message,
/// under `<provider>:<its id>`.
pub const sent_scope: store.internal_records.Scope = .{
    .plugin = store.job_queue.core,
    .app = "",
    .kind = "message_sent",
};

/// A message as kept once sent.
pub const Sent = struct {
    to: []const u8,
    reference: []const u8 = "",
    stream: []const u8 = "transactional",
    at_ms: i64 = 0,
};

/// Whether `to` on `channel` is a staff account's address: what a copy of the site mails.
pub fn staff_address(ctx: *sdk.Ctx, channel: []const u8, to: []const u8) sdk.Error!bool {
    std.debug.assert(channel.len > 0);
    std.debug.assert(to.len <= 64 << 10);

    if (!std.mem.eql(u8, channel, "email")) {
        return false;
    }

    const email = store.users.normalize_email(ctx.arena, to) catch return false;
    const found = try store.users.find_by_email(ctx.db, ctx.arena, email) orelse return false;
    var as_them = ctx.*;

    as_them.caller = .{
        .user = .{
            .id = found.user.id,
            .roles = found.user.roles,
        },
    };

    return @import("../../server/registry.zig").SDK.reaches_admin(&as_them);
}

/// The message with the bytes of each of the site's media it names, base64, beside its type.
pub fn with_files(ctx: *sdk.Ctx, message: messaging.Message) sdk.Error!messaging.Message {
    std.debug.assert(message.channel.len > 0);
    std.debug.assert(message.attachments.len <= 64);

    var named = false;

    for (message.attachments) |attachment| {
        named = named or attachment.media.len > 0;
    }

    if (!named) {
        return message;
    }

    const files = ctx.files orelse return error.Unavailable;
    const attachments = try ctx.arena.dupe(messaging.Attachment, message.attachments);
    var total: u64 = 0;

    for (attachments) |*attachment| {
        if (attachment.media.len == 0) {
            continue;
        }

        const row = try store.media.get(ctx.db, ctx.arena, attachment.media) orelse {
            return error.NotFound;
        };

        total += @intCast(@max(row.size, 0));

        if (total > files_bytes_max) {
            return error.Invalid;
        }

        const bytes = files.read(ctx.arena, .files, row.storage_key, files_bytes_max) catch {
            return error.NotFound;
        };
        const encoder = std.base64.standard.Encoder;
        const encoded = try ctx.arena.alloc(u8, encoder.calcSize(bytes.len));

        attachment.content = encoder.encode(encoded, bytes);
        attachment.content_type = row.mime_type;
    }

    var out = message;

    out.attachments = attachments;

    return out;
}

/// Keeps what `provider` answered for `message` (its id), with the sender's reference.
pub fn keep_sent(
    ctx: *sdk.Ctx,
    provider: []const u8,
    id: []const u8,
    message: messaging.Message,
) sdk.Error!void {
    std.debug.assert(provider.len > 0);
    std.debug.assert(message.to.len > 0);

    if (id.len == 0) {
        return;
    }

    const key = try std.mem.concat(ctx.arena, u8, &.{ provider, ":", id });
    const document = std.json.Stringify.valueAlloc(ctx.arena, Sent{
        .to = message.to,
        .reference = message.reference,
        .stream = @tagName(message.stream),
        .at_ms = ctx.now_ms,
    }, .{}) catch return error.OutOfMemory;

    try store.internal_records.delete_before(ctx.db, sent_scope, ctx.now_ms - sent_keep_ms);

    if (try store.internal_records.get(ctx.db, ctx.arena, sent_scope, key) != null) {
        return;
    }

    try store.internal_records.insert_as(ctx.db, sent_scope, key, document, ctx.now_ms);
}

/// What was kept of the message `id` that `provider` sent; null when nothing was.
pub fn sent_of(ctx: *sdk.Ctx, provider: []const u8, id: []const u8) sdk.Error!?Sent {
    std.debug.assert(provider.len > 0);
    std.debug.assert(id.len > 0);

    const key = try std.mem.concat(ctx.arena, u8, &.{ provider, ":", id });
    const row = try store.internal_records.get(ctx.db, ctx.arena, sent_scope, key) orelse {
        return null;
    };

    return std.json.parseFromSliceLeaky(Sent, ctx.arena, row.document, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}
