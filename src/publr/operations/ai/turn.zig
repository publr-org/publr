//! The agent's side of a turn, sent by `publr agent` over the operator channel: the device
//! it runs as, each step as it lands, and how it ended. The local operator's alone.
const operation = @import("../../operation.zig");
const conversation = @import("../ai.zig");

const example_token = "56a0794f6b1c67062563204a." ++ &@as([64]u8, @splat('0'));

/// One thing said in a conversation, as the model is reminded of it: an ask with the keys
/// of the pictures that came with it.
pub const Said = struct {
    role: []const u8,
    text: []const u8,
    pictures: []const []const u8 = &.{},
};

pub const Begin = struct {
    pub const name = "ai.begin";
    pub const description = "Start a conversation's turn: the device its agent runs as";
    pub const details =
        \\Makes the device the agent works as: the person's, named "Publr agent", with the
        \\conversation's scope, revoked by `ai finish`. Once per turn, while it runs. `prompt`
        \\is what the person asked last; `history` the turns before it, each ask and the
        \\answer to it with what was done. The local operator only: `publr agent` sends it.
    ;
    pub const kind: operation.Kind = .write;
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
        .scope = "production",
        .provider = "scripted",
        .model = "",
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .token = "The device's token, for `/api/cli`; shown once",
        .prompt = "What the person asked last",
        .pictures = "The pictures that came with it: keys of chat pictures",
        .history = "The turns before, the last 200: `user` asks and `assistant` answers, " ++
            "in order",
        .scope = "The device's scope",
        .provider = "Who answers",
        .model = "The model, empty for the provider's default",
    };
};

pub const Record = struct {
    pub const name = "ai.step";
    pub const description = "Add a step to a running conversation";
    pub const details =
        \\`kind` is `said` (the model's words) or `ran` (a command and what it answered).
        \\Answers whether the agent should go on: false once the person asked it to stop, or
        \\the conversation holds 256 steps. The local operator only.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .kind = "said or ran",
        .summary = "One line: the command, or the first line said; cut to 300 bytes",
        .detail = "The whole of it; cut to 16 KiB",
        .failed = "Whether the command failed",
        .href = "The page that shows it: a path on this project, or an https address it read",
    };
};

pub const Finish = struct {
    pub const name = "ai.finish";
    pub const description = "End a conversation's turn and revoke its device";
    pub const details =
        \\`state` is `finished`, `stopped` or `failed`; `answer` the model's last words, or
        \\why the turn failed. A turn ends once: a conversation already over is a conflict.
        \\The local operator only.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .state = "finished, stopped or failed",
        .answer = "The model's last words, or why it failed; cut to 64 KiB",
        .input_tokens = "What the turn read, as the provider counted; added to the " ++
            "conversation's total",
        .output_tokens = "What the turn wrote, as the provider counted; added to its total",
        .cached_tokens = "Of what it read, what the provider read from its cache; added " ++
            "to its total",
    };
};
