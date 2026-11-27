//! The providers of each contract (`publr.contract.define`), compiled in or installed: which
//! are on, and in what order the owner tries them. The administrator manages both; the
//! provider's own settings are on its plugin's page.
const operation = @import("../operation.zig");
const provider_model = @import("../model/provider.zig");

const Authorized = @import("../authorize.zig").Answer;
const Registered = provider_model.Registered;
const Part = provider_model.Part;

pub const namespace: operation.Namespace = .{
    .name = "provider",
    .label = "Providers",
    .area = .system,
    .summary = "The providers of each contract: which are on, in what order",
    .details =
    \\A contract is a named set of operations providers implement (sign-in, AI models,
    \\messaging), owned by core or a plugin. Any plugin registers providers into one; the
    \\owner never names them. Each provider is on until an administrator switches it off,
    \\and the owner tries them in the order set here. A provider's own settings and
    \\secrets are on its plugin's page. A contract may ask one part at install
    \\(`.at_install`): each provider's answer is kept as its defaults until it updates.
    ,
};

pub const Answers = answers.Answers;
pub const Answer = answers.Answer;
const answers = @import("provider/answers.zig");

pub const Listed = struct {
    contract: []const u8,
    name: []const u8,
    plugin: []const u8,
    /// The parts it has, required and optional.
    parts: []const Part,
    component: []const u8,
    on: bool,
};

/// A provider as people read it: its label and its plugin's, in the caller's language.
pub const Shown = struct {
    label: []const u8,
    plugin: []const u8,
};

pub const List = struct {
    pub const name = "provider.list";
    pub const description = "List the providers of a contract, in order, each on or off";
    pub const details =
        \\Every provider registered into `contract`, compiled in or installed, in the
        \\order the administrator set (the rest after, as registered). `can` keeps those
        \\with every optional part named; `on_only` those switched on. Administrators, and
        \\plugins listing the providers of a contract they call.
    ;
    pub const kind: operation.Kind = .read;
    pub const untrusted_callers = false;
    /// `.authorize`: administrators and plugin calls, never anyone else.
    pub const answer: ?Authorized = .plugin_calls;
    /// Plugins and administrators: the example is an administrator's.
    pub const example_signed_in = true;
    pub const In = struct {
        contract: []const u8,
        can: []const []const u8 = &.{},
        on_only: bool = false,
    };
    pub const Out = struct {
        providers: []const Registered,
        on: []const bool,
        /// Each provider as people read it, in the caller's language.
        shown: []const Shown = &.{},
    };
    pub const example: In = .{
        .contract = "messaging",
    };
    pub const example_out: Out = .{
        .providers = &.{},
        .on = &.{},
    };
    pub const output_docs: operation.Docs(Out) = .{
        .providers = "Each provider, in order",
        .on = "Whether each is switched on",
        .shown = "Each provider's label and its plugin's, in the caller's language",
    };
    pub const field_docs: operation.Docs(In) = .{
        .contract = "The contract's name: `messaging`, `ai.model`, `payments.method`",
        .can = "Optional parts every provider listed has",
        .on_only = "Only the providers switched on",
    };
};

pub const Set = struct {
    pub const name = "provider.set";
    pub const description = "Set the order of a contract's providers, and which are off";
    pub const details =
        \\`order` names providers first to last; any left out follow as registered. `off`
        \\names those switched off: the owner never calls them. Names need not be installed
        \\now: a provider installed later takes its place. Administrators, and the plugin that
        \\owns the contract for its own.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        contract: []const u8,
        order: []const []const u8 = &.{},
        off: []const []const u8 = &.{},
    };
    pub const Out = struct {
        contract: []const u8,
    };
    pub const example: In = .{
        .contract = "messaging",
        .order = &.{"postmark"},
        .off = &.{"smtp"},
    };
    pub const example_out: Out = .{
        .contract = "messaging",
    };
    pub const field_docs: operation.Docs(In) = .{
        .contract = "The contract's name",
        .order = "Provider names, first to last",
        .off = "Provider names switched off",
    };
};
