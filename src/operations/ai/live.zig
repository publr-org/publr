//! A conversation as it happens: the model's words while it writes them (`ai.progress`
//! from its provider, `ai.draft` from the agent), and the pages watching told of each
//! change.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const conversation = @import("../ai.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const ai = model.ai;

pub const operations = [_]type{ Progress, Draft, Doing };

/// Tells the pages watching conversation `id` that it changed; they ask for what is new.
pub fn changed(ctx: *const Ctx, id: []const u8) void {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    const live = ctx.live orelse return;

    live.changed(live.context, id);
}

/// `ai.progress`, which provider plugins call: declared beside the rest of what they use.
pub const Progress = @import("../../sdk/ai.zig").Progress;

pub const Draft = struct {
    pub const name = "ai.draft";
    pub const description = "Keep the words a running conversation's model has written so far";
    pub const details =
        \\What a page watching shows before the words are a step; the step or the end of the
        \\turn clears them. The local operator only (the agent, beside the server).
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
        words: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .id = conversation.example_id,
        .words = "I'll start with",
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .words = "Everything written so far in this reply; cut to 16 KiB",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ai.detail_len_max > 0);

        if (ctx.caller != .system) {
            return error.Denied;
        }

        const row = try conversation.own(ctx, in.id);
        const state = ai.State.parse(row.state) orelse return error.Invalid;

        if (state.over()) {
            return error.Conflict;
        }

        const words = ai.clipped(in.words, ai.detail_len_max);

        try store.ai_conversations.set_draft(ctx.db, row.id, words);
        changed(ctx, row.id);

        return .{};
    }
};

pub const Doing = struct {
    pub const name = "ai.activity";
    pub const description = "Say what a running conversation's agent is doing between steps";
    pub const details =
        \\One line, as the person reads it while they wait: "Thinking" while the model writes
        \\its reply, "Running publr media import" while a call runs. The page watching shows
        \\it with how long it has taken; the end of the turn clears it. The local operator
        \\only (the agent, beside the server).
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
        doing: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .id = conversation.example_id,
        .doing = "Thinking",
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .doing = "What it does now, in one line; cut to 120 bytes",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ai.activity_len_max > 0);

        if (ctx.caller != .system) {
            return error.Denied;
        }

        const doing = ai.clipped(std.mem.trim(u8, in.doing, " \t\r\n"), ai.activity_len_max);

        if (in.id.len == 0 or in.id.len > 128 or doing.len == 0) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);
        const state = ai.State.parse(row.state) orelse return error.Invalid;

        if (state.over()) {
            return error.Conflict;
        }

        try store.ai_activity.set(ctx.db, row.id, doing, ctx.now_ms);
        changed(ctx, row.id);

        return .{};
    }
};
