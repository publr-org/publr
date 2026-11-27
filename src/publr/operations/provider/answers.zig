//! What providers answer at install: a contract's part named `.at_install` (`orders.item`'s
//! `declare`) is asked once when a provider is installed and again when it updates, never
//! per call. Its answer is kept as the provider's defaults (an item type's tax facts), with
//! the version it came from.
const operation = @import("../../operation.zig");

const Authorized = @import("../../authorize.zig").Answer;

pub const Answers = struct {
    pub const name = "provider.answers";
    pub const description = "What a provider answered at install: its defaults";
    pub const details =
        \\The answer of `provider` to its contract's part asked at install (`.at_install`),
        \\kept since it was installed or last updated, as JSON. Asked now, and not kept, when
        \\nothing is kept for its version yet. Not found when the provider is not registered
        \\or the contract asks nothing at install. Administrators, and plugin calls.
    ;
    pub const kind: operation.Kind = .read;
    pub const untrusted_callers = false;
    /// `.authorize`: administrators and plugin calls, never anyone else.
    pub const answer: ?Authorized = .plugin_calls;
    pub const example_signed_in = true;
    pub const In = struct {
        contract: []const u8,
        provider: []const u8,
    };
    pub const Out = struct {
        answers: operation.Json,
        version: []const u8,
    };
    pub const example: In = .{
        .contract = "orders.item",
        .provider = "products",
    };
    pub const example_out: Out = .{
        .answers = .{
            .text = "{\"supply\":\"goods\"}",
        },
        .version = "1.0.0",
    };
    pub const field_docs: operation.Docs(In) = .{
        .contract = "The contract's name",
        .provider = "The provider's name",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .answers = "Its answer, as JSON",
        .version = "The provider's version it came from",
    };
};

pub const Answer = struct {
    pub const name = "provider.answer";
    pub const description = "Ask providers installed or updated since for their defaults";
    pub const details =
        \\Every provider of a contract that asks a part at install, compiled in or installed,
        \\whose kept answer is missing or from another version, is asked it now; its answer
        \\is kept with its version. Run by core when plugins change; administrators may run
        \\it too. A provider whose answer fails is left out and asked again next time.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {};
    pub const Out = struct {
        answered: []const []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .answered = &.{"orders.item/products"},
    };
    pub const field_docs: operation.Docs(In) = .{};
    pub const output_docs: operation.Docs(Out) = .{
        .answered = "Each provider asked now, as `<contract>/<provider>`",
    };
};
