//! The agent's side of a turn, sent by `publr agent` over the operator channel: the device
//! it runs as, each step as it lands, and how it ended. The local operator's alone.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const conversation = @import("../ai.zig");
const pictures = @import("pictures.zig");
const live = @import("live.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const ai = model.ai;
const conversations = store.ai_conversations;
const steps = store.ai_steps;

pub const operations = [_]type{ Begin, Record, Finish };

const example_token = "56a0794f6b1c67062563204a." ++ "0" ** 64;

pub const Begin = struct {
    pub const name = "ai.begin";
    pub const description = "Start a conversation's turn: the device its agent runs as";
    pub const details =
        \\Makes the device the agent works as: the person's, named "Publr agent", with the
        \\conversation's scope, revoked by `ai finish`. Once per turn, while it runs. `prompt`
        \\is what the person asked last; `history` the turns before it, each ask and the
        \\answer to it with what was done. The local operator only: `publr agent` sends it.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        token: []const u8,
        prompt: []const u8,
        /// The keys of the pictures that came with `prompt`.
        pictures: []const []const u8 = &.{},
        history: []const Said,
        scope: []const u8,
        provider: []const u8,
        model: []const u8,
    };
    pub const example: In = .{
        .id = conversation.example_id,
    };
    pub const example_out: Out = .{
        .token = example_token,
        .prompt = conversation.example_prompt,
        .history = &.{},
        .scope = "drafts",
        .provider = "scripted",
        .model = "",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "The device's token, for `/api/cli`; shown once",
        .prompt = "What the person asked last",
        .pictures = "The pictures that came with it: keys of chat pictures",
        .history = "The turns before: `user` asks and `assistant` answers, in order",
        .scope = "The device's scope",
        .provider = "Who answers",
        .model = "The model, empty for the provider's default",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        try refuse_unless_operator(ctx);

        const row = try conversation.own(ctx, in.id);

        if (ai.State.parse(row.state) != .running or row.device_id.len > 0) {
            return error.Conflict;
        }

        const created = try store.devices.create(ctx.db, ctx.io, ctx.arena, .{
            .user_id = row.user_id,
            .name = ai.device_name,
            .scope = row.scope,
        }, ctx.now_ms);

        try conversations.set_device(ctx.db, row.id, created.device.id);
        ctx.notice("auth.device_approved", created.device.id);

        const said = try history_of(ctx, row);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .prompt = said[said.len - 1].text,
            .pictures = said[said.len - 1].pictures,
            .history = said[0 .. said.len - 1],
            .scope = row.scope,
            .provider = row.provider,
            .model = row.model,
        };
    }
};

const resumed_note = "(You were working on this when the server restarted. Already done, " ++
    "so carry on from there without doing it again:)";

/// One thing said in a conversation, as the model is reminded of it: an ask with the keys
/// of the pictures that came with it.
pub const Said = struct {
    role: []const u8,
    text: []const u8,
    pictures: []const []const u8 = &.{},
};

/// The conversation as turns: the first ask, each answer (with what was done before it),
/// each follow-up. The last is always an ask: the one this turn answers.
fn history_of(ctx: *Ctx, row: conversations.Conversation) Error![]const Said {
    std.debug.assert(row.prompt.len > 0);
    std.debug.assert(ai.steps_max > 0);

    const rows = try steps.list(ctx.db, ctx.arena, row.id);
    const attached = try store.ai_pictures.list(ctx.db, ctx.arena, row.id);
    var said: std.ArrayList(Said) = .empty;
    var done: std.ArrayList(u8) = .empty;
    const first: Said = .{
        .role = "user",
        .text = row.prompt,
        .pictures = try pictures.keys_of(ctx.arena, attached, 0),
    };

    said.append(ctx.arena, first) catch return error.OutOfMemory;

    for (rows) |step| {
        const step_kind = ai.StepKind.parse(step.kind) orelse continue;
        const text = switch (step_kind) {
            .ran => {
                const line = if (step.failed != 0) "(failed) " else "";

                done.print(ctx.arena, "- {s}{s}\n", .{ line, step.summary }) catch {
                    return error.OutOfMemory;
                };
                continue;
            },
            .said => continue,
            .asked => step.detail,
            .answered => std.fmt.allocPrint(ctx.arena, "Done:\n{s}\n{s}", .{
                done.items,
                step.detail,
            }) catch return error.OutOfMemory,
        };
        const role: []const u8 = if (step_kind == .asked) "user" else "assistant";
        const shown = if (step_kind == .asked)
            try pictures.keys_of(ctx.arena, attached, @intCast(step.position))
        else
            &.{};

        said.append(ctx.arena, .{
            .role = role,
            .text = text,
            .pictures = shown,
        }) catch {
            return error.OutOfMemory;
        };

        if (step_kind == .answered) {
            done = .empty;
        }
    }

    if (!std.mem.eql(u8, said.items[said.items.len - 1].role, "user")) {
        return error.Conflict;
    }

    // A turn the server's restart broke off: the ask carries what was already done of it.
    if (done.items.len > 0) {
        const last = &said.items[said.items.len - 1];

        last.text = std.fmt.allocPrint(ctx.arena, "{s}\n\n{s}\n{s}", .{
            last.text,
            resumed_note,
            done.items,
        }) catch return error.OutOfMemory;
    }

    return said.items;
}

pub const Record = struct {
    pub const name = "ai.step";
    pub const description = "Add a step to a running conversation";
    pub const details =
        \\`kind` is `said` (the model's words) or `ran` (a command and what it answered).
        \\Answers whether the agent should go on: false once the person asked it to stop, or
        \\the conversation holds 256 steps. The local operator only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
        kind: []const u8,
        summary: []const u8,
        detail: []const u8 = "",
        failed: bool = false,
        href: []const u8 = "",
    };
    pub const Out = struct {
        position: u32,
        go_on: bool,
    };
    pub const example: In = .{
        .id = conversation.example_id,
        .kind = "ran",
        .summary = "publr content_type list",
    };
    pub const example_out: Out = .{
        .position = 1,
        .go_on = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .kind = "said or ran",
        .summary = "One line: the command, or the first line said; cut to 300 bytes",
        .detail = "The whole of it; cut to 16 KiB",
        .failed = "Whether the command failed",
        .href = "The page that shows it: a path on this project, or an https address it read",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        try refuse_unless_operator(ctx);

        const step_kind = ai.StepKind.parse(in.kind) orelse return error.Invalid;
        const by_agent = step_kind == .said or step_kind == .ran;
        const local_href = in.href.len > 0 and in.href.len <= ai.href_len_max and
            in.href[0] == '/' and
            std.mem.indexOf(u8, in.href, "//") == null;
        // A page on the internet the agent read, shown as it is.
        const web_href = in.href.len <= ai.href_len_max and
            std.mem.startsWith(u8, in.href, "https://");
        const href_ok = in.href.len == 0 or local_href or web_href;

        if (!by_agent or !href_ok) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);
        const state = ai.State.parse(row.state) orelse return error.Invalid;

        if (state.over()) {
            return error.Conflict;
        }

        const position = try steps.append(ctx.db, row.id, .{
            .kind = step_kind,
            .summary = ai.clipped(in.summary, ai.summary_len_max),
            .detail = ai.clipped(in.detail, ai.detail_len_max),
            .failed = in.failed,
            .href = in.href,
        }, ctx.now_ms) orelse return .{
            .position = ai.steps_max,
            .go_on = false,
        };

        _ = try conversations.set_state(ctx.db, row.id, state, ctx.now_ms);
        try conversations.set_draft(ctx.db, row.id, "");
        live.changed(ctx, row.id);

        return .{
            .position = position,
            .go_on = state == .running and position < ai.steps_max,
        };
    }
};

pub const Finish = struct {
    pub const name = "ai.finish";
    pub const description = "End a conversation's turn and revoke its device";
    pub const details =
        \\`state` is `finished`, `stopped` or `failed`; `answer` the model's last words, or
        \\why the turn failed. A turn ends once: a conversation already over is a conflict.
        \\The local operator only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
        state: []const u8,
        answer: []const u8 = "",
        input_tokens: u64 = 0,
        output_tokens: u64 = 0,
        cached_tokens: u64 = 0,
    };
    pub const Out = conversation.Conversation;
    pub const example: In = .{
        .id = conversation.example_id,
        .state = "finished",
        .answer = "Added a recipes section.",
    };
    pub const example_out: Out = finished: {
        var ended = conversation.example_conversation;
        ended.state = "finished";
        ended.answer = "Added a recipes section.";
        break :finished ended;
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .state = "finished, stopped or failed",
        .answer = "The model's last words, or why it failed; cut to 64 KiB",
        .input_tokens = "What the turn read, as the provider counted; added to the " ++
            "conversation's total",
        .output_tokens = "What the turn wrote, as the provider counted; added to its total",
        .cached_tokens = "Of what it read, what the provider read from its cache; added " ++
            "to its total",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        try refuse_unless_operator(ctx);

        const state = ai.State.parse(in.state) orelse return error.Invalid;

        if (!state.over()) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);
        const current = ai.State.parse(row.state) orelse return error.Invalid;

        // A turn ends once: what ended it first stands.
        if (current.over()) {
            return error.Conflict;
        }

        if (row.device_id.len > 0) {
            _ = try store.devices.revoke(ctx.db, row.device_id, ctx.now_ms);
            ctx.notice("auth.device_revoked", row.device_id);
        }

        const answer = ai.clipped(in.answer, ai.detail_len_max);

        if (answer.len > 0) {
            _ = try steps.append(ctx.db, row.id, .{
                .kind = .answered,
                .summary = ai.summary_of(answer),
                .detail = answer,
                .failed = state == .failed,
            }, ctx.now_ms);
        }

        try conversations.finish(ctx.db, row.id, .{
            .state = state,
            .answer = ai.clipped(in.answer, ai.answer_len_max),
            .input_tokens = in.input_tokens,
            .output_tokens = in.output_tokens,
            .cached_tokens = in.cached_tokens,
        }, ctx.now_ms);
        ctx.notice("ai.finished", row.id);

        try conversations.set_draft(ctx.db, row.id, "");
        try store.ai_browsers.settle(ctx.db, row.id);
        try store.ai_activity.clear(ctx.db, row.id);
        live.changed(ctx, row.id);

        return conversation.conversation_of(try conversation.own(ctx, row.id));
    }
};

fn refuse_unless_operator(ctx: *const Ctx) Error!void {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(ai.device_name.len > 0);

    if (ctx.caller != .system) {
        return error.Denied;
    }
}

test "a turn: begun once as the person's device, its steps, stopped, finished, and private" {
    const SDK = @import("../../server/registry.zig").SDK;
    const Ask = conversation.Ask;
    const Get = conversation.Get;
    const Stop = conversation.Stop;
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    const connection = &harness.fixture.connection;
    const arena = system.arena;
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const users = @import("../user.zig");
    const ada_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
    });
    const bob_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "bob@example.com",
        .display_name = "Bob",
    });
    const ada_id = ada_account.user_id;
    var ada = harness.ctx(.{
        .user = .{
            .id = ada_id,
            .roles = &.{"editor"},
        },
    });
    var bob = harness.ctx(.{
        .user = .{
            .id = bob_account.user_id,
            .roles = &.{"editor"},
        },
    });
    var anon = harness.ctx(.anonymous);

    // Asking needs a person, a server to run the agent beside, and a provider.
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, Ask, .{
        .prompt = "x",
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&ada, Ask, .{
        .prompt = " ",
    }));
    try std.testing.expectError(error.Failed, SDK.dispatch(&ada, Ask, .{
        .prompt = "x",
    }));

    const id = try conversations.insert(connection, std.testing.io, arena, .{
        .user_id = ada_id,
        .prompt = "Add recipes",
        .provider = "scripted",
        .model = "",
        .scope = "drafts",
    }, 1789650000000);

    // Only the local operator keeps the books.
    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, Begin, .{
        .id = id,
    }));
    const begun = try SDK.dispatch(&system, Begin, .{
        .id = id,
    });
    try std.testing.expectEqualStrings("Add recipes", begun.prompt);
    try std.testing.expect(begun.token.len > 0);
    try std.testing.expectError(error.Conflict, SDK.dispatch(&system, Begin, .{
        .id = id,
    }));
    const devices = try store.devices.list(connection, arena, ada_id);
    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings(ai.device_name, devices[0].name);

    const ran: Record.In = .{
        .id = id,
        .kind = "ran",
        .summary = "publr --help",
    };
    try std.testing.expect((try SDK.dispatch(&system, Record, ran)).go_on);
    const unknown: Record.In = .{
        .id = id,
        .kind = "thought",
        .summary = "hm",
    };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Record, unknown));

    // Private: another person sees nothing of it.
    try std.testing.expectError(error.NotFound, SDK.dispatch(&bob, Get, .{
        .id = id,
    }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&bob, Stop, .{
        .id = id,
    }));
    const listed = try SDK.dispatch(&bob, conversation.List, .{});
    try std.testing.expectEqual(@as(usize, 0), listed.conversations.len);

    const stopping = try SDK.dispatch(&ada, Stop, .{
        .id = id,
    });
    try std.testing.expectEqualStrings("stopping", stopping.state);
    const said: Record.In = .{
        .id = id,
        .kind = "said",
        .summary = "Done",
    };
    try std.testing.expect(!(try SDK.dispatch(&system, Record, said)).go_on);

    const stopped: Finish.In = .{
        .id = id,
        .state = "stopped",
        .answer = "Stopped.",
    };
    const ended = try SDK.dispatch(&system, Finish, stopped);
    try std.testing.expectEqualStrings("stopped", ended.state);
    const running: Finish.In = .{
        .id = id,
        .state = "running",
    };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Finish, running));
    try std.testing.expectError(error.Conflict, SDK.dispatch(&system, Record, said));

    const read = try SDK.dispatch(&ada, Get, .{
        .id = id,
    });
    try std.testing.expectEqual(@as(usize, 3), read.steps.len);
    try std.testing.expectEqualStrings("answered", read.steps[2].kind);
    try std.testing.expectEqualStrings("Stopped.", read.conversation.answer);

    // Only the agent's own kinds come through `ai step`; an ask is the person's.
    const asking: Record.In = .{
        .id = id,
        .kind = "asked",
        .summary = "hm",
    };
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Record, asking));
    // The turn's device is revoked with its end.
    const left = try store.devices.list(connection, arena, ada_id);
    try std.testing.expectEqual(@as(usize, 0), left.len);
}
