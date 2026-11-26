//! What providers answer at install: a contract's part named `.at_install` (`orders.item`'s
//! `declare`) is asked once when a provider is installed and again when it updates, never
//! per call. Its answer is kept as the provider's defaults (an item type's tax facts), with
//! the version it came from.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const contract = @import("../../sdk/contract.zig");
const operation_define = @import("../../publr/plugin/operation_define.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Registered = contract.Registered;

pub const operations = [_]type{ Answers, Answer };

/// An answer as kept: the provider's version and what it said.
const Kept = struct {
    version: []const u8,
    answers: std.json.Value,
};

pub const Answers = struct {
    pub const name = "provider.answers";
    pub const description = "What a provider answered at install: its defaults";
    pub const details =
        \\The answer of `provider` to its contract's part asked at install (`.at_install`),
        \\kept since it was installed or last updated, as JSON. Asked now, and not kept, when
        \\nothing is kept for its version yet. Not found when the provider is not registered
        \\or the contract asks nothing at install. Administrators, and plugin calls.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const untrusted_callers = false;
    /// `.authorize`: administrators and plugin calls, never anyone else.
    pub const answer: ?operation_define.Answer = .plugin_calls;
    pub const example_signed_in = true;
    pub const In = struct {
        contract: []const u8,
        provider: []const u8,
    };
    pub const Out = struct {
        answers: sdk.operation.Json,
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .contract = "The contract's name",
        .provider = "The provider's name",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .answers = "Its answer, as JSON",
        .version = "The provider's version it came from",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.contract.len == 0 or in.contract.len > contract.name_len_max) {
            return error.Invalid;
        }

        const provider = try find(ctx, in.contract, in.provider) orelse return error.NotFound;
        const version = version_of(ctx, provider.plugin) orelse return error.NotFound;

        if (try kept_of(ctx, provider)) |kept| {
            if (std.mem.eql(u8, kept.version, version)) {
                const text = std.json.Stringify.valueAlloc(ctx.arena, kept.answers, .{}) catch {
                    return error.OutOfMemory;
                };

                return .{
                    .answers = .{
                        .text = text,
                    },
                    .version = version,
                };
            }
        }

        return .{
            .answers = .{
                .text = try asked(ctx, provider),
            },
            .version = version,
        };
    }
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
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {};
    pub const Out = struct {
        answered: []const []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .answered = &.{"orders.item/products"},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .answered = "Each provider asked now, as `<contract>/<provider>`",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        _ = in;

        var answered: std.ArrayList([]const u8) = .empty;

        for (try every(ctx)) |provider| {
            const version = version_of(ctx, provider.plugin) orelse continue;
            const kept = try kept_of(ctx, provider);
            const current = kept != null and std.mem.eql(u8, kept.?.version, version);

            if (current) {
                continue;
            }

            const text = asked(ctx, provider) catch |err| {
                std.log.warn("provider {s}: no answer at install: {t}", .{ provider.name, err });
                continue;
            };

            try keep(ctx, provider, version, text);
            try answered.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{
                provider.contract,
                provider.name,
            }));
        }

        return .{
            .answered = answered.items,
        };
    }
};

/// Every provider, compiled in or installed, of a contract asking a part at install.
fn every(ctx: *Ctx) Error![]const Registered {
    std.debug.assert(registry.providers.len <= contract.providers_max * 64);

    var found: std.ArrayList(Registered) = .empty;

    for (registry.providers) |provider| {
        if (provider.at_install.len > 0) {
            try found.append(ctx.arena, provider);
        }
    }

    const sandboxed = ctx.sandboxed_plugins orelse return found.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.providers) |provider| {
            if (provider.at_install.len > 0) {
                var owned = provider;

                owned.plugin = manifest.name;
                try found.append(ctx.arena, owned);
            }
        }
    }

    return found.items;
}

fn find(ctx: *Ctx, contract_name: []const u8, provider_name: []const u8) Error!?Registered {
    std.debug.assert(contract_name.len > 0);

    for (try contract.listed(ctx, contract_name)) |one| {
        if (std.mem.eql(u8, one.provider.name, provider_name)) {
            return if (one.provider.at_install.len > 0) one.provider else null;
        }
    }

    return null;
}

/// The version of the plugin registering the provider, compiled in or installed.
fn version_of(ctx: *Ctx, plugin: []const u8) ?[]const u8 {
    std.debug.assert(plugin.len > 0);

    inline for (registry.bound_plugins) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, plugin)) {
            return Plugin.manifest.version;
        }
    }

    const sandboxed = ctx.sandboxed_plugins orelse return null;

    for (sandboxed.manifests()) |manifest| {
        if (std.mem.eql(u8, manifest.name, plugin)) {
            return manifest.version;
        }
    }

    return null;
}

fn key_of(ctx: *Ctx, provider: Registered) Error![]const u8 {
    std.debug.assert(provider.name.len > 0);
    std.debug.assert(provider.contract.len > 0);

    return std.fmt.allocPrint(ctx.arena, "provider_answers.{s}.{s}", .{
        provider.contract,
        provider.name,
    }) catch error.OutOfMemory;
}

fn kept_of(ctx: *Ctx, provider: Registered) Error!?Kept {
    std.debug.assert(provider.at_install.len > 0);

    const text = try store.settings.get(ctx.db, ctx.arena, try key_of(ctx, provider)) orelse {
        return null;
    };

    return std.json.parseFromSliceLeaky(Kept, ctx.arena, text, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

fn keep(ctx: *Ctx, provider: Registered, version: []const u8, answers: []const u8) Error!void {
    std.debug.assert(version.len > 0);
    std.debug.assert(answers.len > 0);

    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, answers, .{}) catch {
        return error.Invalid;
    };
    const text = std.json.Stringify.valueAlloc(ctx.arena, Kept{
        .version = version,
        .answers = value,
    }, .{}) catch return error.OutOfMemory;

    try store.settings.set(ctx.db, try key_of(ctx, provider), text, ctx.now_ms);
}

/// The provider's part asked now, with nothing sent: an answer of its code alone.
fn asked(ctx: *Ctx, provider: Registered) Error![]const u8 {
    std.debug.assert(provider.at_install.len > 0);

    const operation = provider.operation_of(provider.at_install) orelse return error.NotFound;
    // The provider's defaults are the same for everyone: asked as the system, never with
    // the grants of whoever's request reached it first (a visitor's cart).
    var system = ctx.*;

    system.caller = .system;
    system.plugin = "";
    system.plugin_code = false;
    system.app_plugins = null;

    const answer = try registry.SDK.call_json(&system, operation, "{}");

    ctx.next_operation_id = system.next_operation_id;

    return answer;
}
