//! The conversation as the model is given it: each ask with the pictures that came with
//! it, read as the person who asked (`media read`), at a size the model reads well.

const std = @import("std");
const ai = @import("../../lib/ai.zig");
const turn = @import("../../operations/ai/turn.zig");
const Channel = @import("channel.zig").Channel;

/// A picture's width as the model is sent it; a larger one is scaled down by the server,
/// a smaller one is sent as it is.
pub const side_max: u32 = 1568;
/// Sizes a picture is asked for before it is given up on: `side_max`, then halves.
const sizes_tried: u32 = 4;
const gone = "(a picture that is no longer kept)";

pub const Asked = struct {
    prompt: []const u8,
    pictures: []const []const u8,
    history: []const turn.Said,
};

/// The messages a turn starts with, ending with the ask it answers.
pub fn messages_of(
    arena: std.mem.Allocator,
    channel: *Channel,
    asked: Asked,
) ![]const ai.Message {
    std.debug.assert(asked.prompt.len > 0);
    std.debug.assert(channel.token.len > 0);

    const messages = try arena.alloc(ai.Message, asked.history.len + 1);

    for (asked.history, messages[0..asked.history.len]) |said, *message| {
        const role: ai.Role = if (std.mem.eql(u8, said.role, "user")) .user else .assistant;

        const parts = try parts_of(arena, channel, said.text, said.pictures);

        message.* = .{
            .role = role,
            .parts = parts,
        };
    }

    messages[asked.history.len] = .{
        .role = .user,
        .parts = try parts_of(arena, channel, asked.prompt, asked.pictures),
    };

    return messages;
}

fn parts_of(
    arena: std.mem.Allocator,
    channel: *Channel,
    text: []const u8,
    keys: []const []const u8,
) ![]const ai.Part {
    std.debug.assert(text.len > 0);
    std.debug.assert(keys.len <= 64);

    const parts = try arena.alloc(ai.Part, keys.len + 1);

    parts[0] = ai.Part.of_text(text);

    for (keys, parts[1..]) |key, *part| {
        const picture = fetch(arena, channel, key) catch |err| {
            std.log.warn("picture {s}: {t}", .{ key, err });
            part.* = ai.Part.of_text(gone);
            continue;
        };

        part.* = ai.Part.of_image(picture);
    }

    return parts;
}

/// A chat picture as the person may read it (`media read`, through the turn's device):
/// WebP where the server makes it, at `side_max`, then half that and less while it is
/// still more than a model message holds. A screenshot at twice the screen's density is
/// often over at full size.
fn fetch(arena: std.mem.Allocator, channel: *Channel, key: []const u8) !ai.Image {
    std.debug.assert(key.len > 0);
    std.debug.assert(side_max >> (sizes_tried - 1) > 0);

    var side = side_max;
    var tried: u32 = 0;

    while (tried < sizes_tried) : (tried += 1) {
        const read = try fetch_at(arena, channel, key, side);

        if (!readable(read.mime_type)) {
            return error.NotAPicture;
        }

        if (read.data.len <= ai.text_bytes_max) {
            return .{
                .media_type = read.mime_type,
                .data = read.data,
            };
        }

        side /= 2;
    }

    return error.PictureTooLarge;
}

const Read = struct {
    mime_type: []const u8,
    data: []const u8,
};

/// The picture with its width at most `side`, base64.
fn fetch_at(arena: std.mem.Allocator, channel: *Channel, key: []const u8, side: u32) !Read {
    std.debug.assert(key.len > 0);
    std.debug.assert(side > 0 and side <= side_max);

    const width = try std.fmt.allocPrint(arena, "{d}", .{side});
    const answer = try channel.command(&.{
        "media", "read", "--key", key, "--width", width, "--format", "webp",
    });

    if (answer.code != 0) {
        return error.PictureMissing;
    }

    return std.json.parseFromSliceLeaky(Read, arena, answer.out, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// The kinds of picture a model reads.
pub fn readable(mime_type: []const u8) bool {
    std.debug.assert(mime_type.len <= 255);

    const kinds = [_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" };

    for (kinds) |kind| {
        if (std.mem.eql(u8, kind, mime_type)) {
            return true;
        }
    }

    return false;
}

test "a picture is one a model reads: PNG, JPEG, GIF, WebP" {
    try std.testing.expect(readable("image/png"));
    try std.testing.expect(readable("image/webp"));
    try std.testing.expect(!readable("image/svg+xml"));
    try std.testing.expect(!readable("application/pdf"));
}

/// What a turn's model saw, kept beside the agent's log for the next turn: the exact
/// messages (tool outputs with their ids, errors, field names), not a summary of them, so a
/// follow-up carries on knowing what it found, and its first request starts as the last
/// one did, read from the provider's cache. `asks` is how many asks it covers.
const Kept = struct {
    asks: u32,
    messages: []const ai.Message,
};

/// A kept history larger than this is not kept: the next turn rebuilds it from the steps.
const kept_bytes_max: u32 = 8 << 20;

/// How many asks a turn's `history` holds before its own.
pub fn asks_before(said: []const turn.Said) u32 {
    std.debug.assert(said.len <= std.math.maxInt(u32));

    var asks: u32 = 0;

    for (said) |one| {
        asks += @intFromBool(std.mem.eql(u8, one.role, "user"));
    }

    return asks;
}

/// The last turn's messages and then this turn's ask, when the kept file covers exactly
/// the asks before it; null otherwise (none kept, an older turn, a restart mid-turn).
pub fn continued(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    asks: u32,
    ask: ai.Message,
) ?[]const ai.Message {
    std.debug.assert(path.len > 0);
    std.debug.assert(ask.role == .user);

    const limit: std.Io.Limit = .limited(kept_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch return null;
    const kept = std.json.parseFromSliceLeaky(Kept, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;

    if (kept.asks != asks or kept.messages.len == 0) {
        return null;
    }

    var messages: std.ArrayList(ai.Message) = .empty;

    messages.appendSlice(arena, kept.messages) catch return null;

    const last = &messages.items[messages.items.len - 1];

    // A turn that ended on tool results (a pause) ends with the person's side: the ask
    // joins it, so turns still take their turns.
    if (last.role == .user) {
        last.parts = std.mem.concat(arena, ai.Part, &.{ last.parts, ask.parts }) catch return null;
    } else {
        messages.append(arena, ask) catch return null;
    }

    return messages.items;
}

/// Keeps a turn's messages for the next; a failure to is logged, never the turn's.
pub fn keep(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    asks: u32,
    messages: []const ai.Message,
) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(asks > 0);

    const text = std.json.Stringify.valueAlloc(arena, Kept{
        .asks = asks,
        .messages = messages,
    }, .{
        .emit_null_optional_fields = false,
    }) catch |err| {
        return std.log.warn("history: {t}", .{err});
    };

    if (text.len > kept_bytes_max) {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
            std.log.debug("history: {t}", .{err});
        };
        return;
    }

    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = text,
    }) catch |err| {
        std.log.warn("history: {t}", .{err});
    };
}
