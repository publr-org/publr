//! Setting a provider up: the providers Publr's plugin server offers (`catalog.zig`), some
//! installed and started in a click, and a test call to the one chosen. What reaches
//! another server runs as core's queued work (`job.zig`): the calls answer at once.
const operation = @import("../../operation.zig");

pub const Offered = struct {
    name: []const u8,
    label: []const u8,
    summary: []const u8,
    /// Whether it is installed already.
    installed: bool,
};

pub const Catalog = struct {
    pub const name = "ai.catalog";
    pub const description = "List the model providers that can be set up in a click";
    pub const details =
        \\The official provider plugins on Publr's plugin server (plugins.publr.app, or the
        \\folder or address `PUBLR_PLUGIN_CATALOG` names), each marked when it is installed
        \\already: the list as last read, read again in the background once it is an hour
        \\old. `looking` while the first read is on its way; `reached` is false, and the
        \\list empty, when the server could not be reached; `offline` too when this server's
        \\host keeps it off the internet. Administrators only.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        offered: []const Offered,
        reached: bool,
        looking: bool = false,
        offline: bool = false,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .offered = &.{.{
            .name = "ai_example",
            .label = "Example",
            .summary = "Models on your own Example key",
            .installed = false,
        }},
        .reached = true,
    };
    pub const output_docs: operation.Docs(Out) = .{
        .offered = "Each provider: its plugin's name, label, summary, and whether it is installed",
        .reached = "Whether the list of official plugins could be read",
        .looking = "Whether the list is being read for the first time: ask again shortly",
        .offline = "Whether this server's host keeps it off the internet, so nothing is read",
    };
};

pub const SetUp = struct {
    pub const name = "ai.set_up";
    pub const description = "Install and start model providers from the official plugins";
    pub const details =
        \\Answers at once with an id, `job answer` reading how it went. In the background,
        \\each provider's built module is fetched from the catalog and added as an installed
        \\plugin, as uploading it does, then enabled and granted sending requests out, its
        \\key and its raised limits: what a provider needs to answer. Anything else it asks
        \\for waits for an administrator under Plugins. One already added is only enabled.
        \\All or none; the answer lists the plugins set up. Administrators only.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        names: []const []const u8,
    };
    pub const Out = struct {
        /// What `job.answer` reads: `{ names }` once they run.
        asked: []const u8,
    };
    pub const example: In = .{
        .names = &.{"ai_example"},
    };
    pub const example_out: Out = .{
        .asked = "6a1f0c2e9b3d4a5f60718293",
    };
    pub const field_docs: operation.Docs(In) = .{
        .names = "The provider plugins' names, as the catalog lists them",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .asked = "For `job answer`: `{ names }`, the plugins set up and running",
    };
};

pub const Test = struct {
    pub const name = "ai.test";
    pub const description = "Ask a provider for one short answer, to check it works";
    pub const details =
        \\One small request with the provider's key, sent in the background: answers at once
        \\with an id, and `job answer` reads `{ ok, reply }` a second or two later: `ok` when
        \\it answered, else what went wrong in its words. Administrators only.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        provider: []const u8,
        model: []const u8 = "",
    };
    pub const Out = struct {
        /// What `job.answer` reads: `{ ok, reply }`.
        asked: []const u8,
    };
    pub const example: In = .{
        .provider = "ai_example",
    };
    pub const example_out: Out = .{
        .asked = "6a1f0c2e9b3d4a5f60718293",
    };
    pub const field_docs: operation.Docs(In) = .{
        .provider = "The plugin that provides it",
        .model = "One of its models; empty for its default",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .asked = "For `job answer`: `{ ok, reply }`, whether it answered and its words",
    };
};
