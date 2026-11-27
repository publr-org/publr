//! The person's browser as the agent's hands: the agent asks for one call at a time, the
//! workspace page hands it to the Publr extension and answers with what came back.
const operation = @import("../../operation.zig");
const conversation = @import("../ai.zig");

/// A call waiting for the browser, as the workspace page reads it; number 0 for none.
pub const Pending = struct {
    number: u32 = 0,
    call: ?operation.Json = null,
};

pub const example_call = "{\"action\":\"screenshot\",\"tab\":1}";

pub const Ready = struct {
    pub const name = "ai.browser_ready";
    pub const description = "Say the workspace has the Publr extension, to lend the agent";
    pub const details =
        \\The workspace page sends it when the extension says it is there. The agent then
        \\waits up to a minute for each browser call before it gives up on the browser. The
        \\caller's own conversations only.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
    };
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
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const operator_only = true;
    pub const In = struct {
        id: []const u8,
        call: operation.Json,
    };
    pub const Out = struct {
        number: u32,
    };
    pub const example: In = .{
        .id = conversation.example_id,
        .call = .{
            .text = example_call,
        },
    };
    pub const example_out: Out = .{
        .number = 1,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .call = "The call: a JSON object with its `action`; up to 8 KiB",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .number = "The call's number",
    };
};

pub const Browsed = struct {
    pub const name = "ai.browsed";
    pub const description = "What the person's browser answered to a call, for the agent";
    pub const details =
        \\`state` is `pending` until the browser answers, then `answered` with its words and
        \\the screenshot it took, if any. With `give_up` a call still pending is dropped and
        \\the browser forgotten: `gone`. `ready` says whether a workspace ever said it has
        \\the extension. The local operator only.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .number = "The call's number, as `ai browse` answered it",
        .give_up = "Stop waiting: drop the call and forget the browser",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .state = "pending, answered, or gone",
        .ready = "Whether the workspace said it has the extension",
        .answer = "What the browser answered",
        .failed = "Whether the browser could not do it",
        .picture = "The screenshot it took, a base64 JPEG; empty for none",
    };
};

pub const Answer = struct {
    pub const name = "ai.browser_answer";
    pub const description = "Answer the agent's browser call with what the browser did";
    pub const details =
        \\The workspace page sends what the Publr extension answered to call `number`, with
        \\the screenshot it took, if any. Only the call still waiting is answered: an older
        \\or answered one is a conflict. The caller's own conversations only.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .number = "The call's number, from `ai conversation`'s `browser_call`",
        .answer = "What the browser did or read; cut to 48 KiB",
        .failed = "Whether the browser could not do it",
        .picture = "A screenshot, a base64 JPEG, up to 176 KiB",
    };
};
