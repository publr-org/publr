//! Conversations with a model: a person asks (`ai.ask`, `ai.reply`), an agent works as their
//! device, and each step lands as it happens (`ai.conversation`). The agent's bookkeeping,
//! the providers, their set-up, the person's browser and speech are the sub-files'.
const operation = @import("../operation.zig");
const ai_markdown = @import("../model/ai_markdown.zig");
const browser = @import("ai/browser.zig");

pub const namespace: operation.Namespace = .{
    .name = "ai",
    .label = "AI conversations",
    .area = .system,
    .summary = "Conversations with a model: a person asks, an agent builds as their device",
    .details =
    \\A person asks for something in plain words (`ai ask`); an agent then works on the
    \\project in a process of its own beside the server, as a device of that person with the
    \\access they chose (`read`, `write`, `production` or `publish`), running `publr` commands
    \\and reading the agents guide, until the model is done. Each step lands as it happens
    \\(`ai conversation`), and the device is revoked when the turn ends. Conversations are
    \\private: each belongs to the person who asked. The agent's own bookkeeping (`ai
    \\begin`, `ai step`, `ai finish`) is the local operator's alone.
    ,
};

pub const Ready = browser.Ready;
pub const Browse = browser.Browse;
pub const Browsed = browser.Browsed;
pub const Answer = browser.Answer;
pub const Begin = turn.Begin;
pub const Record = turn.Record;
pub const Finish = turn.Finish;
pub const Said = turn.Said;
pub const Providers = providers.Providers;
pub const Choose = providers.Choose;
pub const Listed = providers.Listed;
pub const Catalog = setup.Catalog;
pub const SetUp = setup.SetUp;
pub const Test = setup.Test;
pub const Offered = setup.Offered;
pub const Progress = live.Progress;
pub const Draft = live.Draft;
pub const Doing = live.Doing;
pub const Transcribe = speech.Transcribe;
pub const Pending = browser.Pending;
const turn = @import("ai/turn.zig");
const providers = @import("ai/providers.zig");
const setup = @import("ai/setup.zig");
const live = @import("ai/live.zig");
const speech = @import("ai/speech.zig");

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
    blocks: []const ai_markdown.Block,
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
    .scope = "publish",
    .state = "running",
    .answer = "",
    .input_tokens = 0,
    .output_tokens = 0,
    .created_at = 1789650000000,
    .updated_at = 1789650000000,
};

const pictures_doc = "Pictures the model looks at with it, up to 8: keys of chat pictures " ++
    "(`media upload --type ai_picture`)";

/// The steps a conversation's page shows at first, and loads at a time after.
pub const steps_page: u32 = 50;

/// A step a page points at, wherever it is in the conversation; position 0 for none.
pub const Pointed = struct {
    position: u32 = 0,
    summary: []const u8 = "",
    href: []const u8 = "",
};

pub const Ask = struct {
    pub const name = "ai.ask";
    pub const description = "Ask a model to build something; an agent starts on it at once";
    pub const details =
        \\Starts a conversation and its turn: an agent works on the project beside the server,
        \\as a device of the caller with `scope` (`publish`, the default: what the caller may do;
        \\`production`, writing but not publishing; `write`, on copies only; or `read`),
        \\and the steps land in the conversation as they happen. Only for accounts whose roles
        \\grant `ai.ask` (administrators, editors and contributors do), on a server (`publr
        \\serve`) with a model provider connected. Answers at once, `running`.
    ;
    pub const kind: operation.Kind = .write;
    pub const example_signed_in = true;
    pub const In = struct {
        prompt: []const u8,
        scope: []const u8 = "publish",
        pictures: []const []const u8 = &.{},
        page: []const u8 = "",
    };
    pub const Out = Conversation;
    pub const example: In = .{
        .prompt = example_prompt,
    };
    pub const example_out: Out = example_conversation;
    pub const field_docs: operation.Docs(In) = .{
        .prompt = "What to build, in plain words; up to 16 KiB",
        .scope = "What the agent may do: publish (as you may), production (it writes, you " ++
            "publish), write (on copies only) or read",
        .pictures = pictures_doc,
        .page = "The page it was asked on, which the words may mean by \"this\": an " ++
            "admin path (`/admin/content/post/<id>`) or a site's address; empty for none",
    };
};

pub const Reply = struct {
    pub const name = "ai.reply";
    pub const description = "Ask a follow-up in a conversation; the agent carries on";
    pub const details =
        \\Once its last turn is over: another turn starts, with what was asked and answered
        \\before, under the conversation's scope. The caller's own conversations only.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .prompt = "The follow-up, in plain words; up to 16 KiB",
        .pictures = pictures_doc,
    };
};

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
    pub const kind: operation.Kind = .read;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
        .after = "Only the steps after this position, oldest first: what a page following " ++
            "it has not seen",
        .before = "Only the steps before this position: the earlier ones a page shows next",
        .limit = "How many steps at most; 50 when omitted, up to 512",
    };
    pub const output_docs: operation.Docs(Out) = .{
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
};

pub const List = struct {
    pub const name = "ai.conversations";
    pub const description = "List the caller's conversations, newest first";
    pub const details =
        \\Newest first, 50 a page, without their steps; `total` counts them all.
    ;
    pub const kind: operation.Kind = .read;
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
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many at most; 50 when omitted, up to 50",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .conversations = &.{example_conversation},
    };
};

pub const Stop = struct {
    pub const name = "ai.stop";
    pub const description = "Ask a running conversation's agent to stop";
    pub const details =
        \\The agent stops before its next step: what it already did stays. The state is
        \\`stopping` until it does, then `stopped`. A turn already over is left as it is.
    ;
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "The conversation's id",
    };
};
