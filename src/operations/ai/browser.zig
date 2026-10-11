//! The person's browser as the agent's hands: the agent asks for one call at a time, the
//! workspace page hands it to the Publr extension and answers with what came back.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const conversation = @import("../ai.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const ai = model.ai;
const browsers = store.ai_browsers;

pub const operations = [_]type{ Ready, Browse, Browsed, Answer };

/// A call waiting for the browser, as the workspace page reads it; number 0 for none.
pub const Pending = struct {
    number: u32 = 0,
    call: []const u8 = "",
};

/// The call the conversation's browser has to make, if one waits.
pub fn pending_of(ctx: *Ctx, id: []const u8) Error!Pending {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    const row = try browsers.get(ctx.db, ctx.arena, id) orelse return .{};
    const waiting = ai.BrowserState.parse(row.state) == .pending;

    if (!waiting) {
        return .{};
    }

    return .{
        .number = @intCast(row.number),
        .call = row.call,
    };
}

const example_call = "{\"action\":\"screenshot\",\"tab\":1}";

pub const Ready = struct {
    pub const name = "ai.browser_ready";
    pub const description = "Say the workspace has the Publr extension, to lend the agent";
    pub const details =
        \\The workspace page sends it when the extension says it is there. The agent then
        \\waits up to a minute for each browser call before it gives up on the browser. The
        \\caller's own conversations only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .id = conversation.example_id,
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (ctx.caller == .system) {
            return error.Denied;
        }

        if (!an_id(in.id)) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);

        // Never 0, which says no workspace ever had the extension.
        try browsers.ready(ctx.db, row.id, @max(ctx.now_ms, 1));

        return .{};
    }
};

pub const Browse = struct {
    pub const name = "ai.browse";
    pub const description = "Ask the person's browser for one call, for the agent";
    pub const details =
        \\`call` is a JSON object naming its `action`; the workspace page reads it from `ai
        \\conversation` and hands it to the Publr extension. One call at a time: a new one
        \\replaces the last. Answers the call's number, for `ai browsed`. The local
        \\operator only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
        call: []const u8,
    };
    pub const Out = struct {
        number: u32,
    };
    pub const example: In = .{
        .id = conversation.example_id,
        .call = example_call,
    };
    pub const example_out: Out = .{
        .number = 1,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .call = "The call: a JSON object with its `action`; up to 8 KiB",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .number = "The call's number",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ai.browser_call_len_max > 0);

        if (ctx.caller != .system) {
            return error.Denied;
        }

        if (!an_id(in.id) or !an_action(ctx.arena, in.call)) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);
        const state = ai.State.parse(row.state) orelse return error.Invalid;

        if (state.over()) {
            return error.Conflict;
        }

        const number = try browsers.call(ctx.db, row.id, in.call);

        conversation.live.changed(ctx, row.id);

        return .{
            .number = number,
        };
    }
};

fn an_id(id: []const u8) bool {
    std.debug.assert(id.len <= std.math.maxInt(u32));

    return id.len > 0 and id.len <= 128;
}

/// Whether `text` is a call: a JSON object, small, naming its action.
fn an_action(arena: std.mem.Allocator, text: []const u8) bool {
    std.debug.assert(ai.browser_call_len_max > 2);

    if (text.len < 2 or text.len > ai.browser_call_len_max) {
        return false;
    }

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return false;
    };
    const object = switch (value) {
        .object => |object| object,
        else => return false,
    };
    const action = object.get("action") orelse return false;

    return action == .string and action.string.len > 0 and action.string.len <= 32;
}

pub const Browsed = struct {
    pub const name = "ai.browsed";
    pub const description = "What the person's browser answered to a call, for the agent";
    pub const details =
        \\`state` is `pending` until the browser answers, then `answered` with its words and
        \\the screenshot it took, if any. With `give_up` a call still pending is dropped and
        \\the browser forgotten: `gone`. `ready` says whether a workspace ever said it has
        \\the extension. The local operator only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
        number: u32,
        give_up: bool = false,
    };
    pub const Out = struct {
        state: []const u8,
        ready: bool = false,
        answer: []const u8 = "",
        failed: bool = false,
        picture: []const u8 = "",
    };
    pub const example: In = .{
        .id = conversation.example_id,
        .number = 1,
    };
    pub const example_out: Out = .{
        .state = "answered",
        .ready = true,
        .answer = "Took a screenshot of https://example.com/",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .number = "The call's number, as `ai browse` answered it",
        .give_up = "Stop waiting: drop the call and forget the browser",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .state = "pending, answered, or gone",
        .ready = "Whether the workspace said it has the extension",
        .answer = "What the browser answered",
        .failed = "Whether the browser could not do it",
        .picture = "The screenshot it took, a base64 JPEG; empty for none",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ai.browser_picture_len_max > 0);

        if (ctx.caller != .system) {
            return error.Denied;
        }

        if (!an_id(in.id)) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);
        const browser = try browsers.get(ctx.db, ctx.arena, row.id) orelse return .{
            .state = "gone",
        };
        const state = ai.BrowserState.parse(browser.state) orelse return error.Invalid;
        const current = browser.number == in.number;

        if (current and state == .answered) {
            try browsers.settle(ctx.db, row.id);

            return .{
                .state = "answered",
                .ready = browser.ready_at > 0,
                .answer = browser.answer,
                .failed = browser.failed != 0,
                .picture = browser.picture,
            };
        }

        if (!current or state != .pending or in.give_up) {
            try browsers.forget(ctx.db, row.id);

            return .{
                .state = "gone",
            };
        }

        return .{
            .state = "pending",
            .ready = browser.ready_at > 0,
        };
    }
};

pub const Answer = struct {
    pub const name = "ai.browser_answer";
    pub const description = "Answer the agent's browser call with what the browser did";
    pub const details =
        \\The workspace page sends what the Publr extension answered to call `number`, with
        \\the screenshot it took, if any. Only the call still waiting is answered: an older
        \\or answered one is a conflict. The caller's own conversations only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
        number: u32,
        answer: []const u8,
        failed: bool = false,
        picture: []const u8 = "",
    };
    pub const Out = struct {};
    pub const example: In = .{
        .id = conversation.example_id,
        .number = 1,
        .answer = "Took a screenshot of https://example.com/",
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The conversation's id",
        .number = "The call's number, from `ai conversation`'s `browser_call`",
        .answer = "What the browser did or read; cut to 48 KiB",
        .failed = "Whether the browser could not do it",
        .picture = "A screenshot, a base64 JPEG, up to 176 KiB",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ai.browser_answer_len_max > 0);

        if (ctx.caller == .system) {
            return error.Denied;
        }

        const sized = in.number > 0 and in.picture.len <= ai.browser_picture_len_max;

        if (!an_id(in.id) or !sized) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);
        const given: browsers.Answer = .{
            .text = ai.clipped(in.answer, ai.browser_answer_len_max),
            .failed = in.failed,
            .picture = in.picture,
        };

        if (!try browsers.answer(ctx.db, row.id, in.number, given)) {
            return error.Conflict;
        }

        return .{};
    }
};

test "a browser call: asked by the agent, read and answered by the person, taken once" {
    const SDK = @import("../../server/registry.zig").SDK;
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const users = @import("../user.zig");
    const account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
    });
    var ada = harness.ctx(.{
        .user = .{
            .id = account.user_id,
            .roles = &.{"editor"},
        },
    });
    const id = try store.ai_conversations.insert(
        &harness.fixture.connection,
        std.testing.io,
        system.arena,
        .{
            .user_id = account.user_id,
            .prompt = "Look at example.com",
            .provider = "scripted",
            .model = "",
            .scope = "drafts",
        },
        1789650000000,
    );

    // Only the agent asks, and only for a call that names its action.
    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, Browse, .{
        .id = id,
        .call = example_call,
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Browse, .{
        .id = id,
        .call = "{\"tab\":1}",
    }));

    const asked = try SDK.dispatch(&system, Browse, .{
        .id = id,
        .call = example_call,
    });
    try std.testing.expectEqual(@as(u32, 1), asked.number);

    const read = try SDK.dispatch(&ada, conversation.Get, .{
        .id = id,
    });
    try std.testing.expectEqual(@as(u32, 1), read.browser_call.number);
    try std.testing.expectEqualStrings(example_call, read.browser_call.call);

    const waiting = try SDK.dispatch(&system, Browsed, .{
        .id = id,
        .number = 1,
    });
    try std.testing.expectEqualStrings("pending", waiting.state);
    try std.testing.expect(!waiting.ready);

    _ = try SDK.dispatch(&ada, Ready, .{
        .id = id,
    });
    const answered: Answer.In = .{
        .id = id,
        .number = 1,
        .answer = "Took a screenshot",
        .picture = "/9j/",
    };
    try std.testing.expectError(error.Conflict, SDK.dispatch(&ada, Answer, .{
        .id = id,
        .number = 2,
        .answer = "late",
    }));
    _ = try SDK.dispatch(&ada, Answer, answered);
    try std.testing.expectError(error.Conflict, SDK.dispatch(&ada, Answer, answered));

    const taken = try SDK.dispatch(&system, Browsed, .{
        .id = id,
        .number = 1,
    });
    try std.testing.expectEqualStrings("answered", taken.state);
    try std.testing.expect(taken.ready);
    try std.testing.expectEqualStrings("/9j/", taken.picture);
    try std.testing.expectEqual(@as(u32, 0), (try pending_of(&ada, id)).number);

    // A call nobody answers is given up on, and the browser with it.
    _ = try SDK.dispatch(&system, Browse, .{
        .id = id,
        .call = example_call,
    });
    const dropped = try SDK.dispatch(&system, Browsed, .{
        .id = id,
        .number = 2,
        .give_up = true,
    });
    try std.testing.expectEqualStrings("gone", dropped.state);
    try std.testing.expect(try browsers.get(ada.db, ada.arena, id) == null);
}
