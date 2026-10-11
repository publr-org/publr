//! The model's words as its provider streams them, kept on the conversation a few times a
//! second (`ai.draft`), so the person watching reads them as they are written.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const Channel = @import("channel.zig").Channel;

/// How often the words so far are kept, at most.
pub const interval_ms: i64 = 300;
const words_max: u32 = 16 << 10;

pub const Drafter = struct {
    channel: *Channel,
    io: std.Io,
    id: []const u8,
    words: std.ArrayList(u8) = .empty,
    kept_at_ms: i64 = 0,
    /// Told of each word streamed: a reply on its way is a turn alive.
    watchdog: ?*@import("watchdog.zig").Watchdog = null,

    pub fn progress(drafter: *Drafter) sdk.context.Progress {
        std.debug.assert(drafter.id.len > 0);

        return .{
            .context = drafter,
            .said = said,
        };
    }

    /// A reply is over: its words are a step now, and the next reply starts afresh.
    pub fn reset(drafter: *Drafter) void {
        std.debug.assert(drafter.words.items.len <= words_max);

        drafter.words.clearRetainingCapacity();
        drafter.kept_at_ms = 0;
    }

    fn said(context: *anyopaque, words: []const u8) void {
        const drafter: *Drafter = @ptrCast(@alignCast(context));

        std.debug.assert(drafter.words.items.len <= words_max);

        if (drafter.watchdog) |watchdog| {
            watchdog.alive();
        }

        const room = words_max - drafter.words.items.len;

        const taken = words[0..@min(words.len, room)];

        drafter.words.appendSlice(drafter.channel.arena, taken) catch |err| {
            std.log.warn("draft: {t}", .{err});
            return;
        };

        const now_ms = sdk.context.wall_clock_ms(drafter.io);

        if (now_ms - drafter.kept_at_ms < interval_ms) {
            return;
        }

        drafter.kept_at_ms = now_ms;

        const args = [_][]const u8{
            "--as-admin",        "ai",       "draft",
            "--id",              drafter.id, "--words",
            drafter.words.items,
        };

        _ = drafter.channel.operate(struct {}, &args) catch |err| {
            std.log.warn("draft: {t}", .{err});
        };
    }
};
