//! A conversation as it happens: the model's words while it writes them (`ai.progress`
//! from its provider, `ai.draft` from the agent), and the pages watching told of each
//! change.
const operation = @import("../../operation.zig");
const conversation = @import("../ai.zig");

/// `ai.progress`, which provider plugins call: declared beside the rest of what they use.
pub const Progress = @import("../../ai.zig").Progress;

pub const Draft = struct {
    pub const name = "ai.draft";
    pub const description = "Keep the words a running conversation's model has written so far";
    pub const details =
        \\What a page watching shows before the words are a step; the step or the end of the
        \\turn clears them. The local operator only (the agent, beside the server).
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .words = "Everything written so far in this reply; cut to 16 KiB",
    };
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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .doing = "What it does now, in one line; cut to 120 bytes",
    };
};
