//! The agent's side of a turn, sent by `publr agent` over the operator channel: the device
//! it runs as, each step as it lands, and how it ended. The local operator's alone.

const std = @import("std");
const public = @import("../../publr/operations/ai/turn.zig");
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

pub const Begin = struct {
    pub const shape = public.Begin;
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
    pub const output_docs = shape.output_docs;

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

        const said = try history_of(ctx, row);
        const before = said[0 .. said.len - 1];
        // The most recent turns, a page of them: a longer chat's start is left out.
        const kept = before.len - @min(before.len, sdk.operation.page_limit_max);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .prompt = said[said.len - 1].text,
            .pictures = said[said.len - 1].pictures,
            .history = before[kept..],
            .scope = row.scope,
            .provider = row.provider,
            .model = row.model,
        };
    }
};

const resumed_note = "(You were working on this when the server restarted. Already done, " ++
    "so carry on from there without doing it again:)";

pub const Said = public.Said;

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
    pub const shape = public.Record;
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
    pub const shape = public.Finish;
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
        .roles = &.{"editor"},
    });
    const bob_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "bob@example.com",
        .display_name = "Bob",
        .roles = &.{"editor"},
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
        .scope = "production",
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
