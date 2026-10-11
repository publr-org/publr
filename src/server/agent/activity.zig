//! What the agent does between steps, told to the conversation as it starts (`ai
//! activity`): the person sees "Thinking" while the model writes, and each call as it
//! runs, never a page that looks stalled.

const std = @import("std");
const ai = @import("../../lib/ai.zig");
const Channel = @import("channel.zig").Channel;
const browser = @import("browser.zig");
const model_ai = @import("../../model/ai.zig");

pub const Activity = struct {
    channel: *Channel,
    id: []const u8,

    /// Told before the model is asked for its next reply.
    pub fn thinking(activity: *Activity) void {
        std.debug.assert(activity.id.len > 0);

        activity.say("Thinking");
    }

    /// Told before a call runs.
    pub fn calling(activity: *Activity, arena: std.mem.Allocator, call: ai.Part) void {
        std.debug.assert(call.kind == .tool_call);

        const line = doing_of(arena, call) catch "Working";

        activity.say(line);
    }

    pub fn say(activity: *Activity, doing: []const u8) void {
        std.debug.assert(doing.len > 0);

        const args = [_][]const u8{
            "--as-admin",                                       "ai",        "activity",
            "--id",                                             activity.id, "--doing",
            model_ai.clipped(doing, model_ai.activity_len_max),
        };

        // A line the page misses is only a line: the turn goes on.
        _ = activity.channel.operate(struct {}, &args) catch |err| {
            std.log.warn("activity: {t}", .{err});
        };
    }
};

/// A call as it starts, in the present tense.
pub fn doing_of(arena: std.mem.Allocator, call: ai.Part) ![]const u8 {
    std.debug.assert(call.kind == .tool_call);

    const name = call.name orelse return "Working";
    const object = if (call.input) |input| switch (input) {
        .object => |object| object,
        else => null,
    } else null;
    const field = struct {
        fn text(found: ?std.json.ObjectMap, key: []const u8) []const u8 {
            const value = (found orelse return "").get(key) orelse return "";

            return if (value == .string) value.string else "";
        }
    }.text;

    if (std.mem.eql(u8, name, "run")) {
        const found = object orelse return "Running publr";
        const words = found.get("args") orelse return "Running publr";
        const list = if (words == .array) words.array.items else return "Running publr";
        var line: std.ArrayList(u8) = .empty;

        try line.appendSlice(arena, "Running publr");

        for (list[0..@min(list.len, 2)]) |word| {
            if (word != .string) {
                break;
            }

            try line.print(arena, " {s}", .{word.string});
        }

        return line.items;
    }

    if (std.mem.eql(u8, name, "browser")) {
        const action = browser.action_of(call.input) orelse "a page";

        return std.fmt.allocPrint(arena, "Using your browser: {s}", .{action});
    }

    if (std.mem.eql(u8, name, "show")) {
        return std.fmt.allocPrint(arena, "Opening {s}", .{field(object, "path")});
    }

    if (std.mem.eql(u8, name, "fetch")) {
        return std.fmt.allocPrint(arena, "Reading {s}", .{field(object, "url")});
    }

    return if (std.mem.eql(u8, name, "guide")) "Reading the guide" else "Working";
}

test "a call reads as what it is doing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"args\":[\"media\",\"import\",\"--url\",\"https://a.eu/x.jpg\"]}",
        .{},
    );
    const run: ai.Part = .{
        .kind = .tool_call,
        .name = "run",
        .input = input,
    };

    try std.testing.expectEqualStrings("Running publr media import", try doing_of(arena, run));

    const nameless: ai.Part = .{
        .kind = .tool_call,
    };

    try std.testing.expectEqualStrings("Working", try doing_of(arena, nameless));
}
