//! The model providers: every provider of core's `ai.model` contract that is on, compiled
//! in or installed, in the administrator's order. Which one conversations use, and
//! with which model, is a setting an administrator chooses under Settings › AI.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const environment = @import("../../lib/environment.zig");
const lib_ai = @import("../../lib/ai.zig");
const sdk_ai = @import("../../sdk/ai.zig");
const secret = @import("../secret.zig");
const contract = @import("../../sdk/contract.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Providers, Choose };

const provider_key = "ai.provider";
const model_key = "ai.model";
/// Set to a file of scripted answers, the provider every conversation uses.
pub const script_variable = "PUBLR_AI_SCRIPT";
pub const scripted = "scripted";
const listed_max: u32 = 32;

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
    pub const kind: sdk.operation.Kind = .read;
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        const chosen = try store.settings.get(ctx.db, ctx.arena, provider_key) orelse "";
        const model = try store.settings.get(ctx.db, ctx.arena, model_key) orelse "";
        const listed = try in_use(ctx, chosen);
        var provider: []const u8 = "";

        for (listed) |one| {
            if (one.chosen) {
                provider = one.plugin;
            }
        }

        return .{
            .providers = listed,
            .provider = provider,
            .model = if (std.mem.eql(u8, provider, chosen)) model else "",
        };
    }
};

pub const Choose = struct {
    pub const name = "ai.choose";
    pub const description = "Choose the model provider conversations use, and its model";
    pub const details =
        \\`provider` is a plugin that registers one; `model` one of its models, empty for its
        \\default. Administrators only.
    ;
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .provider = "The plugin that provides it",
        .model = "One of its models; empty for its default",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.provider.len == 0 or in.provider.len > 64) {
            return error.Invalid;
        }

        const found = try find(ctx, in.provider) orelse return error.NotFound;

        if (in.model.len > 0 and !offers(found.description, in.model)) {
            return error.Invalid;
        }

        try store.settings.set(ctx.db, provider_key, in.provider, ctx.now_ms);
        try store.settings.set(ctx.db, model_key, in.model, ctx.now_ms);

        return .{
            .provider = in.provider,
            .model = in.model,
        };
    }
};

/// What a new conversation is answered by: the provider in use (see `in_use`); else the
/// script `PUBLR_AI_SCRIPT` names; null when there is neither.
pub const Answerer = struct {
    provider: []const u8,
    model: []const u8,
};

pub fn answerer(ctx: *Ctx) Error!?Answerer {
    std.debug.assert(script_variable.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const chosen = try store.settings.get(ctx.db, ctx.arena, provider_key) orelse "";

    for (try in_use(ctx, chosen)) |one| {
        if (!one.chosen) {
            continue;
        }

        const model = try store.settings.get(ctx.db, ctx.arena, model_key) orelse "";

        return .{
            .provider = one.plugin,
            .model = if (std.mem.eql(u8, one.plugin, chosen)) model else "",
        };
    }

    if (environment.get(script_variable) != null) {
        return .{
            .provider = scripted,
            .model = "",
        };
    }

    return null;
}

/// The provider that turns speech into text: the chosen one when it hears, else the first
/// installed one with its key set that does; null for none.
pub fn hearer(ctx: *Ctx) Error!?[]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(listed_max > 0);

    const chosen = try store.settings.get(ctx.db, ctx.arena, provider_key) orelse "";
    const listed = try installed(ctx, chosen);
    var first: ?[]const u8 = null;

    for (listed) |one| {
        if (!one.key_set or !one.description.speech) {
            continue;
        }

        if (one.chosen) {
            return one.plugin;
        }

        first = first orelse one.plugin;
    }

    return first;
}

/// Whether some provider is installed or scripted, without asking any: for the Overview.
pub fn any(ctx: *Ctx) bool {
    std.debug.assert(ctx.now_ms >= 0);

    const found = answerer(ctx) catch return false;

    return found != null;
}

pub fn find(ctx: *Ctx, plugin: []const u8) Error!?Listed {
    std.debug.assert(plugin.len > 0);

    for (try installed(ctx, "")) |listed| {
        if (std.mem.eql(u8, listed.plugin, plugin)) {
            return listed;
        }
    }

    return null;
}

/// Every provider registered, the one in use marked `chosen`: the one chosen while it is
/// installed, else the first with its key set, so a key pasted in is enough to build.
fn in_use(ctx: *Ctx, chosen: []const u8) Error![]Listed {
    std.debug.assert(listed_max > 0);
    std.debug.assert(chosen.len <= 64 << 10);

    const listed = try installed(ctx, chosen);

    for (listed) |one| {
        if (one.chosen) {
            return listed;
        }
    }

    for (listed) |*one| {
        if (one.key_set) {
            one.chosen = true;
            return listed;
        }
    }

    return listed;
}

/// Every provider of `ai.model` that is on, in order.
fn installed(ctx: *Ctx, chosen: []const u8) Error![]Listed {
    std.debug.assert(listed_max > 0);

    var found: std.ArrayList(Listed) = .empty;

    for (try contract.providers(ctx, sdk_ai.contract, .{})) |provider| {
        const description = provider.call(ctx, .describe, .{}) catch |err| {
            std.log.warn("{s}: {t}", .{ provider.name(), err });
            continue;
        };

        try add(ctx, &found, provider.name(), description, chosen);
    }

    return found.items;
}

/// The `ai.model` provider named `name` that is on, when there is one: its parts are the
/// operations core calls.
pub fn registered(ctx: *Ctx, name: []const u8) Error!?contract.Registered {
    std.debug.assert(name.len > 0);

    for (try contract.enabled(ctx, sdk_ai.contract.contract_name, &.{})) |provider| {
        if (std.mem.eql(u8, provider.name, name)) {
            return provider;
        }
    }

    return null;
}

fn add(
    ctx: *Ctx,
    found: *std.ArrayList(Listed),
    plugin: []const u8,
    description: lib_ai.Description,
    chosen: []const u8,
) Error!void {
    std.debug.assert(plugin.len > 0);

    if (found.items.len >= listed_max or !description.valid()) {
        return;
    }

    const key_set = if (description.key) |key|
        secrets_valid(key.secret) and try secret.value_of(ctx, key.secret) != null
    else
        true;

    found.append(ctx.arena, .{
        .plugin = plugin,
        .description = description,
        .key_set = key_set,
        .chosen = std.mem.eql(u8, plugin, chosen),
    }) catch return error.OutOfMemory;
}

fn secrets_valid(secret_name: []const u8) bool {
    return @import("../../model/secrets.zig").valid_name(secret_name);
}

fn offers(description: lib_ai.Description, model: []const u8) bool {
    std.debug.assert(model.len > 0);

    for (description.models) |offered| {
        if (std.mem.eql(u8, offered.id, model)) {
            return true;
        }
    }

    return false;
}
