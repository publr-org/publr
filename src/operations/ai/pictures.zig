//! The pictures a person attaches to an ask: chat pictures (`ai_picture`, a media type of
//! their own, apart from the library; the admin uploads each as it is attached), kept with
//! the ask for the model to look at. The agent reads them with `media.read` as the person.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const ai = model.ai;

/// Keeps `media_keys` with the ask at `asked`: each a chat picture.
pub fn keep(
    ctx: *Ctx,
    conversation_id: []const u8,
    asked: u32,
    media_keys: []const []const u8,
) Error!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(ai.pictures_max > 0);

    if (media_keys.len > ai.pictures_max) {
        return ctx.fail(too_many);
    }

    for (media_keys) |media_key| {
        const row = try store.media.by_key(ctx.db, ctx.arena, media_key) orelse {
            return ctx.fail(not_a_picture);
        };
        const handle = try store.media.type_of(ctx.db, ctx.arena, row.record) orelse "";

        if (!std.mem.eql(u8, handle, ai.picture_type_handle)) {
            return ctx.fail(not_a_picture);
        }
    }

    try store.ai_pictures.insert(ctx.db, conversation_id, asked, media_keys);
}

/// The keys of the pictures that came with the ask at `asked`, in order.
pub fn keys_of(
    arena: std.mem.Allocator,
    pictures: []const store.ai_pictures.Picture,
    asked: u32,
) Error![]const []const u8 {
    std.debug.assert(pictures.len <= ai.pictures_max * ai.steps_max);

    var keys: std.ArrayList([]const u8) = .empty;

    for (pictures) |picture| {
        if (picture.asked == asked) {
            keys.append(arena, picture.media_key) catch return error.OutOfMemory;
        }
    }

    std.debug.assert(keys.items.len <= ai.pictures_max);

    return keys.items;
}

const too_many: sdk.operation.Failure = .{
    .name = "TooManyPictures",
    .status = 422,
    .message = "Up to 8 pictures with one ask",
};

const not_a_picture: sdk.operation.Failure = .{
    .name = "NotAPicture",
    .status = 422,
    .message = "A picture is a chat picture (`media upload --type ai_picture`): its key",
};
