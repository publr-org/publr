//! The model providers: every provider of core's `ai.model` contract that is on, compiled
//! in or installed, in the administrator's order. Which one conversations use, and
//! with which model, is a setting an administrator chooses under Settings › AI.
const operation = @import("../../operation.zig");
const lib_ai = @import("publr_ai");

pub const Listed = struct {
    /// The provider's name: what a conversation names as its provider.
    plugin: []const u8,
    description: lib_ai.Description,
    /// Whether its key is set, in the environment or kept; true for one with no key.
    key_set: bool,
    chosen: bool,
};

pub const Providers = struct {
    pub const name = "ai.providers";
    pub const description = "List the model providers installed, and the one chosen";
    pub const details =
        \\Every plugin that registers a provider, with its models and whether its key is
        \\set; `model` is the model chosen, empty for the provider's default. Administrators
        \\only.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        providers: []const Listed,
        provider: []const u8,
        model: []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .providers = &.{},
        .provider = "",
        .model = "",
    };
};

pub const Choose = struct {
    pub const name = "ai.choose";
    pub const description = "Choose the model provider conversations use, and its model";
    pub const details =
        \\`provider` is a plugin that registers one; `model` one of its models, empty for its
        \\default. Administrators only.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        provider: []const u8,
        model: []const u8 = "",
    };
    pub const Out = struct {
        provider: []const u8,
        model: []const u8,
    };
    pub const example: In = .{
        .provider = "ai_example",
        .model = "small",
    };
    pub const example_out: Out = .{
        .provider = "ai_example",
        .model = "small",
    };
    pub const field_docs: operation.Docs(In) = .{
        .provider = "The plugin that provides it",
        .model = "One of its models; empty for its default",
    };
};
