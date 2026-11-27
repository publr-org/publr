//! A conversation as it happens: the model's words while it writes them (`ai.progress`
//! from its provider, `ai.draft` from the agent), and the pages watching told of each
//! change.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const conversation = @import("../ai.zig");
const public = @import("../../publr/operations/ai/live.zig");

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

/// `ai.progress`, which provider plugins call.
pub const Progress = struct {
    pub const shape = public.Progress;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.words.len <= std.math.maxInt(u32));

        if (ctx.caller != .plugin) {
            return error.Denied;
        }

        const progress = ctx.progress orelse return .{};

        progress.said(progress.context, in.words);

        return .{};
    }
};

pub const Draft = struct {
    pub const shape = public.Draft;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const operator_only = shape.operator_only;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.Doing;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const operator_only = shape.operator_only;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
