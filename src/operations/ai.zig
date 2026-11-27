const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const turn = @import("ai/turn.zig");
const providers = @import("ai/providers.zig");
const setup = @import("ai/setup.zig");
const pictures = @import("ai/pictures.zig");
const browser = @import("ai/browser.zig");
const speech = @import("ai/speech.zig");
pub const live = @import("ai/live.zig");
const public = @import("../publr/operations/ai.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const ai = model.ai;
const conversations = store.ai_conversations;
const steps = store.ai_steps;

pub const namespace = public.namespace;

/// The media types of the pictures pasted into a conversation and of what a person says to
/// be written down, made or brought up to date whenever a database opens.
pub fn bootstrap(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.db.transaction_depth == 0);

    try @import("../sdk/plugin/types.zig").apply(ctx, &.{
        .{
            .owner = model.content_type.core_owner,
            .def = ai.picture_type_def,
        },
        .{
            .owner = model.content_type.core_owner,
            .def = ai.recording_type_def,
        },
    });
}

pub const operations = [_]type{ Ask, Reply, Get, List, Stop } ++ turn.operations ++
    providers.operations ++ setup.operations ++ live.operations ++ browser.operations ++
    speech.operations;

pub const Conversation = public.Conversation;
pub const Step = public.Step;
pub const example_id = public.example_id;
pub const example_prompt = public.example_prompt;
pub const example_conversation = public.example_conversation;

pub const Ask = struct {
    pub const shape = public.Ask;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ai.prompt_len_max > 0);

        const person = try person_of(ctx);
        const words = std.mem.trim(u8, in.prompt, " \t\r\n");

        if (words.len == 0 or words.len > ai.prompt_len_max or !ai.page_valid(in.page)) {
            return error.Invalid;
        }

        const prompt = if (in.page.len == 0)
            words
        else
            try std.mem.concat(ctx.arena, u8, &.{ words, ai.asked_on_mark, in.page });

        if (prompt.len > ai.prompt_len_max) {
            return error.Invalid;
        }

        const scope = model.device.Scope.parse(in.scope) orelse return error.Invalid;
        const agents = ctx.agents orelse return ctx.fail(no_server);
        const answerer = try providers.answerer(ctx) orelse return ctx.fail(no_provider);
        const id = try conversations.insert(ctx.db, ctx.io, ctx.arena, .{
            .user_id = person,
            .prompt = prompt,
            .provider = answerer.provider,
            .model = answerer.model,
            .scope = @tagName(scope),
        }, ctx.now_ms);

        try pictures.keep(ctx, id, 0, in.pictures);

        if (agents.start(agents.context, id)) |problem| {
            return ctx.fail(.{
                .name = "NotStarted",
                .status = 503,
                .message = problem,
            });
        }

        live.changed(ctx, id);

        return conversation_of(try own(ctx, id));
    }
};

pub const Reply = struct {
    pub const shape = public.Reply;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        _ = try person_of(ctx);

        const prompt = std.mem.trim(u8, in.prompt, " \t\r\n");

        const sized = prompt.len > 0 and prompt.len <= ai.prompt_len_max;

        if (in.id.len == 0 or in.id.len > 128 or !sized) {
            return error.Invalid;
        }

        const row = try own(ctx, in.id);
        const state = ai.State.parse(row.state) orelse return error.Invalid;

        if (!state.over()) {
            return error.Conflict;
        }

        const agents = ctx.agents orelse return ctx.fail(no_server);
        const asked: steps.New = .{
            .kind = .asked,
            .summary = ai.summary_of(prompt),
            .detail = prompt,
        };

        const position = try steps.append(ctx.db, row.id, asked, ctx.now_ms) orelse {
            return error.Invalid;
        };

        try pictures.keep(ctx, row.id, position, in.pictures);
        try conversations.resume_turn(ctx.db, row.id, ctx.now_ms);

        if (agents.start(agents.context, row.id)) |problem| {
            return ctx.fail(.{
                .name = "NotStarted",
                .status = 503,
                .message = problem,
            });
        }

        live.changed(ctx, row.id);

        return conversation_of(try own(ctx, row.id));
    }
};

pub const steps_page = public.steps_page;

pub const Pointed = public.Pointed;

fn pointed_of(found: ?steps.Step) Pointed {
    const step = found orelse return .{};

    std.debug.assert(step.href.len > 0);

    return .{
        .position = @intCast(step.position),
        .summary = step.summary,
        .href = step.href,
    };
}

const removals_prefix = "/admin/removals/";

pub const Get = struct {
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len == 0 or in.id.len > 128) {
            return error.Invalid;
        }

        if (in.limit == 0 or in.limit > ai.steps_max) {
            return error.Invalid;
        }

        const row = try own(ctx, in.id);
        const rows = try steps.page(ctx.db, ctx.arena, row.id, .{
            .after = in.after,
            .before = in.before,
            .limit = in.limit,
            .oldest_first = in.after > 0,
        });
        const attached = try store.ai_pictures.list(ctx.db, ctx.arena, row.id);
        const doing = try store.ai_activity.get(ctx.db, ctx.arena, row.id);
        const out = ctx.arena.alloc(Step, rows.len) catch return error.OutOfMemory;

        var kept: u32 = 0;

        for (rows) |step| {
            if (step.position <= in.after) {
                continue;
            }

            const shown = &out[kept];

            kept += 1;
            shown.* = .{
                .position = @intCast(step.position),
                .kind = step.kind,
                .summary = step.summary,
                .detail = step.detail,
                .failed = step.failed != 0,
                .href = step.href,
                .blocks = if (std.mem.eql(u8, step.kind, "ran"))
                    &.{}
                else
                    model.ai_markdown.read(ctx.arena, step.detail) catch return error.OutOfMemory,
                .pictures = if (std.mem.eql(u8, step.kind, "asked"))
                    try pictures.keys_of(ctx.arena, attached, @intCast(step.position))
                else
                    &.{},
                .at = step.at,
            };
        }

        return .{
            .conversation = conversation_of(row),
            .steps = out[0..kept],
            .earlier = if (kept == 0) 0 else out[0].position - 1,
            .last_page = if (in.after > 0)
                .{}
            else
                pointed_of(try steps.latest_at(ctx.db, ctx.arena, row.id, "")),
            .removal = if (in.after > 0)
                .{}
            else
                pointed_of(try steps.latest_at(ctx.db, ctx.arena, row.id, removals_prefix)),
            .prompt_pictures = try pictures.keys_of(ctx.arena, attached, 0),
            .draft = try conversations.draft_of(ctx.db, ctx.arena, row.id),
            .browser_call = try browser.pending_of(ctx, row.id),
            .activity = if (doing) |found| found.doing else "",
            .activity_ms = if (doing) |found| @max(ctx.now_ms - found.since, 0) else 0,
        };
    }
};

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const field_docs = shape.field_docs;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.limit == 0 or in.limit > ai.listed_max) {
            return error.Invalid;
        }

        const person = ctx.caller.user_id() orelse return error.Denied;
        const rows = try conversations.list_by_user(ctx.db, ctx.arena, person, in.offset, in.limit);
        const out = ctx.arena.alloc(Conversation, rows.len) catch return error.OutOfMemory;

        for (rows, out) |row, *shown| {
            shown.* = conversation_of(row);
        }

        return .{
            .conversations = out,
            .total = try conversations.count_by_user(ctx.db, person),
        };
    }
};

pub const Stop = struct {
    pub const shape = public.Stop;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len == 0 or in.id.len > 128) {
            return error.Invalid;
        }

        const row = try own(ctx, in.id);

        if (ai.State.parse(row.state) == .running) {
            _ = try conversations.set_state(ctx.db, row.id, .stopping, ctx.now_ms);
            live.changed(ctx, row.id);
        }

        return conversation_of(try own(ctx, row.id));
    }
};

const no_server: sdk.operation.Failure = .{
    .name = "NoServer",
    .status = 503,
    .message = "Conversations run beside a server: start it with `publr serve`",
};

const no_provider: sdk.operation.Failure = .{
    .name = "NoProvider",
    .status = 409,
    .message = "No model provider is connected: connect one under Settings > AI",
};

/// Whether a conversation could be answered now: a provider chosen, or a script.
pub fn connected(ctx: *Ctx) bool {
    return providers.any(ctx);
}

/// The account of a person signed in: never a device or anything else.
pub fn person_of(ctx: *const Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    return switch (ctx.caller) {
        .user => |user| user.id,
        .anonymous, .token, .system, .plugin => error.Denied,
    };
}

/// The conversation, when it is the caller's: the local operator reaches any.
pub fn own(ctx: *Ctx, id: []const u8) Error!conversations.Conversation {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    const row = try conversations.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

    if (ctx.caller == .system) {
        return row;
    }

    const caller = ctx.caller.user_id() orelse return error.NotFound;

    if (!std.mem.eql(u8, caller, row.user_id)) {
        return error.NotFound;
    }

    return row;
}

pub fn conversation_of(row: conversations.Conversation) Conversation {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.input_tokens >= 0 and row.output_tokens >= 0);

    return .{
        .id = row.id,
        .prompt = row.prompt,
        .provider = row.provider,
        .model = row.model,
        .scope = row.scope,
        .state = row.state,
        .answer = row.answer,
        .input_tokens = @intCast(row.input_tokens),
        .output_tokens = @intCast(row.output_tokens),
        .cached_tokens = @intCast(@max(row.cached_tokens, 0)),
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}
