//! The person's browser as the agent's hands: the agent asks for one call at a time, the
//! workspace page hands it to the Publr extension and answers with what came back.

const std = @import("std");
const public = @import("../../publr/operations/ai/browser.zig");
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

pub const Pending = public.Pending;

const example_call = public.example_call;

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
        .call = if (row.call.len > 0) .{
            .text = row.call,
        } else null,
    };
}

pub const Ready = struct {
    pub const shape = public.Ready;
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
    pub const shape = public.Browse;
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
        std.debug.assert(ai.browser_call_len_max > 0);

        if (ctx.caller != .system) {
            return error.Denied;
        }

        if (!an_id(in.id) or !an_action(ctx.arena, in.call.text)) {
            return error.Invalid;
        }

        const row = try conversation.own(ctx, in.id);
        const state = ai.State.parse(row.state) orelse return error.Invalid;

        if (state.over()) {
            return error.Conflict;
        }

        const number = try browsers.call(ctx.db, row.id, in.call.text);

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
    pub const shape = public.Browsed;
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
    pub const shape = public.Answer;
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
        .roles = &.{"editor"},
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
            .scope = "production",
        },
        1789650000000,
    );

    // Only the agent asks, and only for a call that names its action.
    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, Browse, .{
        .id = id,
        .call = .{
            .text = example_call,
        },
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Browse, .{
        .id = id,
        .call = .{
            .text = "{\"tab\":1}",
        },
    }));

    const asked = try SDK.dispatch(&system, Browse, .{
        .id = id,
        .call = .{
            .text = example_call,
        },
    });
    try std.testing.expectEqual(@as(u32, 1), asked.number);

    const read = try SDK.dispatch(&ada, conversation.Get, .{
        .id = id,
    });
    try std.testing.expectEqual(@as(u32, 1), read.browser_call.number);
    try std.testing.expectEqualStrings(example_call, read.browser_call.call.?.text);

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
        .call = .{
            .text = example_call,
        },
    });
    const dropped = try SDK.dispatch(&system, Browsed, .{
        .id = id,
        .number = 2,
        .give_up = true,
    });
    try std.testing.expectEqualStrings("gone", dropped.state);
    try std.testing.expect(try browsers.get(ada.db, ada.arena, id) == null);
}
