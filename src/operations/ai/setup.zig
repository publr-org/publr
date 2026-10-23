//! Setting a provider up: the providers Publr's plugin server offers (`catalog.zig`), some
//! installed and started in a click, and a test call to the one chosen.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const lib_ai = @import("../../lib/ai.zig");
const sdk_ai = @import("../../sdk/ai.zig");
const providers = @import("providers.zig");
const catalog = @import("catalog.zig");
const lifecycle = @import("../plugin/lifecycle.zig");
const state = @import("../plugin/state.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Catalog, SetUp, Test };

/// Most providers set up in one call.
const set_up_max: u32 = 8;

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
        \\already. `reached` is false, and the list empty, when the server could not be
        \\reached. Administrators only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        offered: []const Offered,
        reached: bool,
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
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .offered = "Each provider: its plugin's name, label, summary, and whether it is installed",
        .reached = "Whether the list of official plugins could be read",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        const file = catalog.read(ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                ctx.failure = null;

                return .{
                    .offered = &.{},
                    .reached = false,
                };
            },
        };
        var offered: std.ArrayList(Offered) = .empty;

        for (file.plugins) |plugin| {
            if (!std.mem.eql(u8, plugin.kind, "ai_provider")) {
                continue;
            }

            offered.append(ctx.arena, .{
                .name = plugin.name,
                .label = plugin.label,
                .summary = plugin.summary,
                .installed = try providers.find(ctx, plugin.name) != null,
            }) catch return error.OutOfMemory;
        }

        return .{
            .offered = offered.items,
            .reached = true,
        };
    }
};

pub const SetUp = struct {
    pub const name = "ai.set_up";
    pub const description = "Install and start model providers from the official plugins";
    pub const details =
        \\Each provider's built module is fetched from the catalog and added as an installed
        \\plugin, as uploading it does, then enabled and granted sending requests out, its
        \\key and its raised limits: what a provider needs to answer. Anything else it asks
        \\for waits for an administrator under Plugins. One already added is only enabled.
        \\All or none. Administrators only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        names: []const []const u8,
    };
    pub const Out = struct {
        names: []const []const u8,
    };
    pub const example: In = .{
        .names = &.{"ai_example"},
    };
    pub const example_out: Out = .{
        .names = &.{"ai_example"},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .names = "The provider plugins' names, as the catalog lists them",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .names = "The plugins set up, now running",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.names.len < 1 or in.names.len > set_up_max) {
            return ctx.refuse(&.{.{
                .field = "names",
                .message = std.fmt.comptimePrint("Name 1 to {d} providers.", .{set_up_max}),
            }});
        }

        const file = try catalog.read(ctx);

        for (in.names) |wanted| {
            const entry = for (file.plugins) |plugin| {
                if (std.mem.eql(u8, plugin.name, wanted)) {
                    break plugin;
                }
            } else {
                return error.NotFound;
            };

            if (try store.sandboxed_plugins.get(ctx.db, ctx.arena, entry.name) == null) {
                _ = try lifecycle.add(ctx, try catalog.stage(ctx, entry));
            }

            try start(ctx, entry.name);
        }

        return .{
            .names = in.names,
        };
    }
};

/// Enables it, granting what a provider is set up for: requests out and the room a model's
/// answer takes (its raised limits). Its key is a secret it declares, set apart.
fn start(ctx: *Ctx, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const enabled = try lifecycle.enable(ctx, name, &.{});
    const shown = try state.requests_of(
        ctx.arena,
        &enabled.manifest,
        enabled.granted,
        enabled.denied,
        enabled.grants,
    );

    for (shown) |request| {
        const wanted = std.mem.eql(u8, request.key, "http.fetch") or
            std.mem.startsWith(u8, request.key, "limit.");

        if (wanted and request.state == .pending) {
            _ = try lifecycle.decide(ctx, name, request.key, .grant);
        }
    }
}

pub const Test = struct {
    pub const name = "ai.test";
    pub const description = "Ask a provider for one short answer, to check it works";
    pub const details =
        \\One small request with the provider's key: `ok` when it answered, else what went
        \\wrong in its words. The server waits for the answer, a second or two.
        \\Administrators only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        provider: []const u8,
        model: []const u8 = "",
    };
    pub const Out = struct {
        ok: bool,
        reply: []const u8,
    };
    pub const example: In = .{
        .provider = "ai_example",
    };
    pub const example_out: Out = .{
        .ok = true,
        .reply = "OK",
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

        const asked = [_]lib_ai.Message{.{
            .role = .user,
            .parts = &.{lib_ai.Part.of_text("Reply with the single word OK.")},
        }};
        const request = lib_ai.request_json(ctx.arena, .{
            .model = in.model,
            .messages = &asked,
            .output_tokens_max = 16,
        }) catch return error.OutOfMemory;
        const input = std.json.Stringify.valueAlloc(ctx.arena, sdk_ai.Completion.In{
            .request = request,
        }, .{}) catch return error.OutOfMemory;
        const provider = try providers.registered(ctx, in.provider) orelse
            return error.NotFound;
        const operation = provider.operation_of("complete").?;
        const SDK = @import("../../server/registry.zig").SDK;
        const output = SDK.call_json(ctx, operation, input) catch |err| {
            const failure = if (ctx.failure) |found| found.message else @errorName(err);

            ctx.failure = null;

            return .{
                .ok = false,
                .reply = failure,
            };
        };

        return .{
            .ok = true,
            .reply = try reply_of(ctx, output),
        };
    }
};

fn reply_of(ctx: *Ctx, output: []const u8) Error![]const u8 {
    std.debug.assert(output.len > 0);

    const out = std.json.parseFromSliceLeaky(sdk_ai.Completion.Out, ctx.arena, output, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;
    const response = lib_ai.response_of(ctx.arena, out.response) catch return error.Invalid;

    for (response.parts) |part| {
        if (part.kind == .text) {
            return part.text orelse "";
        }
    }

    return "";
}
