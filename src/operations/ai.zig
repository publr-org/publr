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

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const ai = model.ai;
const conversations = store.ai_conversations;
const steps = store.ai_steps;

pub const namespace: sdk.operation.Namespace = .{
    .name = "ai",
    .label = "AI conversations",
    .area = .system,
    .summary = "Conversations with a model: a person asks, an agent builds as their device",
    .details =
    \\A person asks for something in plain words (`ai ask`); an agent then works on the
    \\project in a process of its own beside the server, as a device of that person with the
    \\access they chose (`read`, `drafts` or `write`), running `publr` commands and reading
    \\the agents guide, until the model is done. Each step lands as it happens
    \\(`ai conversation`), and the device is revoked when the turn ends. Conversations are
    \\private: each belongs to the person who asked. The agent's own bookkeeping (`ai
    \\begin`, `ai step`, `ai finish`) is the local operator's alone.
    ,
};

/// The media type of the pictures pasted into a conversation, made or brought up to date
/// whenever a database opens.
pub fn bootstrap(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.db.transaction_depth == 0);

    try @import("../sdk/plugin/types.zig").apply(ctx, &.{.{
        .owner = model.content_type.core_owner,
        .def = ai.picture_type_def,
    }});
}

pub const operations = [_]type{ Ask, Reply, Get, List, Stop } ++ turn.operations ++
    providers.operations ++ setup.operations ++ live.operations ++ browser.operations ++
    speech.operations;

/// One conversation, as every operation answers it.
pub const Conversation = struct {
    id: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    scope: []const u8,
    state: []const u8,
    answer: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    /// Of `input_tokens`, what the provider read from its cache.
    cached_tokens: u64 = 0,
    created_at: i64,
    updated_at: i64,
};

pub const Step = struct {
    position: u32,
    kind: []const u8,
    summary: []const u8,
    detail: []const u8,
    failed: bool,
    /// The admin page that shows what it changed; empty for none.
    href: []const u8,
    /// The words of what was asked, said or answered, read from their Markdown; none for
    /// a command.
    blocks: []const model.ai_markdown.Block,
    /// An ask's pictures: keys of chat pictures.
    pictures: []const []const u8 = &.{},
    at: i64,
};

pub const example_id = "6a7b8c9d0e1f2a3b4c5d6e7f";
pub const example_prompt = "Add a recipes section with a page listing them";
pub const example_conversation: Conversation = .{
    .id = example_id,
    .prompt = example_prompt,
    .provider = "scripted",
    .model = "",
    .scope = "write",
    .state = "running",
    .answer = "",
    .input_tokens = 0,
    .output_tokens = 0,
    .created_at = 1789650000000,
    .updated_at = 1789650000000,
};

pub const Ask = struct {
    pub const name = "ai.ask";
    pub const description = "Ask a model to build something; an agent starts on it at once";
    pub const details =
        \\Starts a conversation and its turn: an agent works on the project beside the server,
        \\as a device of the caller with `scope` (`write`, the default: what the caller may do;
        \\`drafts`, writing but not publishing; or `read`),
        \\and the steps land in the conversation as they happen. Signed-in people only, on a
        \\server (`publr serve`) with a model provider connected. Answers at once, `running`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        prompt: []const u8,
        scope: []const u8 = "write",
        pictures: []const []const u8 = &.{},
        page: []const u8 = "",
    };
    pub const Out = Conversation;
    pub const example: In = .{
        .prompt = example_prompt,
    };
    pub const example_out: Out = example_conversation;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .prompt = "What to build, in plain words; up to 16 KiB",
        .scope = "What the agent may do: write (as you may), drafts (it writes, you " ++
            "publish) or read",
        .pictures = pictures_doc,
        .page = "The page it was asked on, which the words may mean by \"this\": an " ++
            "admin path (`/admin/content/post/<id>`) or a site's address; empty for none",
    };

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

const pictures_doc = "Pictures the model looks at with it, up to 8: keys of chat pictures " ++
    "(`media upload --type ai_picture`)";

pub const Reply = struct {
    pub const name = "ai.reply";
    pub const description = "Ask a follow-up in a conversation; the agent carries on";
    pub const details =
        \\Once its last turn is over: another turn starts, with what was asked and answered
        \\before, under the conversation's scope. The caller's own conversations only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
        prompt: []const u8,
        pictures: []const []const u8 = &.{},
    };
    pub const Out = Conversation;
    pub const example: In = .{
        .id = example_id,
        .prompt = "Make the prices in PLN",
    };
    pub const example_out: Out = example_conversation;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .prompt = "The follow-up, in plain words; up to 16 KiB",
        .pictures = pictures_doc,
    };

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

/// The steps a conversation's page shows at first, and loads at a time after.
pub const steps_page: u32 = 50;

/// A step a page points at, wherever it is in the conversation; position 0 for none.
pub const Pointed = struct {
    position: u32 = 0,
    summary: []const u8 = "",
    href: []const u8 = "",
};

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
    pub const name = "ai.conversation";
    pub const description = "Read a conversation: where its turn is, its steps a page at a time";
    pub const details =
        \\The caller's own conversations only. `state` is `running` until the turn ends as
        \\`finished`, `stopped` or `failed`; `answer` is then the model's last words. The
        \\steps come a page at a time: the newest `limit` of them (before `before`, when
        \\given), or the ones after `after`, oldest first. `earlier` says how many come
        \\before the first one answered.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
        after: u32 = 0,
        before: u32 = 0,
        limit: u32 = steps_page,
    };
    pub const Out = struct {
        conversation: Conversation,
        steps: []const Step,
        /// How many steps come before the first one answered.
        earlier: u32 = 0,
        /// The step with the page the agent last worked on, and the newest removal list,
        /// wherever they are; read only without `after`.
        last_page: Pointed = .{},
        removal: Pointed = .{},
        /// The keys of the pictures that came with the first ask.
        prompt_pictures: []const []const u8 = &.{},
        /// The words the model is writing, so far; empty between replies.
        draft: []const u8 = "",
        /// The call the agent waits on the person's browser for; number 0 for none.
        browser_call: browser.Pending = .{},
        /// What the agent does now, between steps; empty between turns.
        activity: []const u8 = "",
        /// How long it has been doing it.
        activity_ms: i64 = 0,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .conversation = example_conversation,
        .steps = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .after = "Only the steps after this position, oldest first: what a page following " ++
            "it has not seen",
        .before = "Only the steps before this position: the earlier ones a page shows next",
        .limit = "How many steps at most; 50 when omitted, up to 512",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .conversation = "The conversation",
        .steps = "Its steps in order: `said` (the model's words) or `ran` (a command)",
        .earlier = "How many steps come before the first one answered: 0 when it is the first",
        .last_page = "The step with the page the agent last worked on (position, summary, " ++
            "href); without `after` only",
        .removal = "The step with the newest removal list to review; without `after` only",
        .prompt_pictures = "The pictures that came with the first ask: keys of images in " ++
            "the media library",
        .draft = "The words the model is writing, so far, while it writes them",
        .browser_call = "The call the agent waits on the person's browser for (its " ++
            "`number` and `call`, a JSON object), handed to the Publr extension; number 0 " ++
            "for none",
        .activity = "What the agent does now, between steps (\"Thinking\"); empty between turns",
        .activity_ms = "How long it has been doing it, in milliseconds",
    };

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
    pub const name = "ai.conversations";
    pub const description = "List the caller's conversations, newest first";
    pub const details =
        \\Newest first, 50 a page, without their steps; `total` counts them all.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        conversations: []const Conversation,
        total: u32 = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .limit = "How many at most; 50 when omitted, up to 50",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .conversations = &.{example_conversation},
    };

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
    pub const name = "ai.stop";
    pub const description = "Ask a running conversation's agent to stop";
    pub const details =
        \\The agent stops before its next step: what it already did stays. The state is
        \\`stopping` until it does, then `stopped`. A turn already over is left as it is.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = Conversation;
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = example_conversation;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
    };

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
