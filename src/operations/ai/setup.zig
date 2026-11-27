//! Setting a provider up: the providers Publr's plugin server offers (`catalog.zig`), some
//! installed and started in a click, and a test call to the one chosen. What reaches
//! another server runs as core's queued work (`job.zig`): the calls answer at once.

const std = @import("std");
const public = @import("../../publr/operations/ai/setup.zig");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const lib_ai = @import("../../lib/ai.zig");
const sdk_ai = @import("../../publr/ai.zig");
const providers = @import("providers.zig");
const catalog = @import("catalog.zig");
const lifecycle = @import("../plugin/lifecycle.zig");
const state = @import("../plugin/state.zig");
const jobs = @import("../job.zig");
const http_stream = @import("../http_stream.zig");
const market = @import("../plugin/market.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Catalog, SetUp, Test };

/// Most providers set up in one call.
const set_up_max: u32 = 8;

pub const Offered = public.Offered;

pub const Catalog = struct {
    pub const shape = public.Catalog;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        const kept = try catalog.kept(ctx);
        var offered: std.ArrayList(Offered) = .empty;

        for (kept.plugins) |plugin| {
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
            .reached = kept.reached,
            .looking = kept.looking,
            .offline = kept.offline,
        };
    }
};

pub const SetUp = struct {
    pub const shape = public.SetUp;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.names.len < 1 or in.names.len > set_up_max) {
            return ctx.refuse(&.{.{
                .field = "names",
                .message = std.fmt.comptimePrint("Name 1 to {d} providers.", .{set_up_max}),
            }});
        }

        return .{
            .asked = try jobs.ask(ctx, "install", market.Installing{
                .names = in.names,
                .providers = true,
            }),
        };
    }
};

/// Grants an enabled provider what it is set up for: requests out and the room a model's
/// answer takes (its raised limits). Its key is a secret it declares, set apart.
pub fn grant_provider(ctx: *Ctx, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const enabled = try state.load(ctx, name);
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
            const SDK = @import("../../server/registry.zig").SDK;

            _ = try SDK.dispatch(ctx, @import("../plugin.zig").GrantRequest, .{
                .name = name,
                .key = request.key,
            });
        }
    }
}

pub const Test = struct {
    pub const shape = public.Test;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.provider.len == 0 or in.provider.len > 64) {
            return error.Invalid;
        }

        _ = try providers.registered(ctx, in.provider) orelse return error.NotFound;

        return .{
            .asked = try jobs.ask(ctx, "ai_test", Testing{
                .provider = in.provider,
                .model = in.model,
            }),
        };
    }
};

pub const Testing = struct {
    asked: []const u8 = "",
    provider: []const u8,
    model: []const u8 = "",
};

pub const Tested = struct {
    ok: bool,
    reply: []const u8,
};

/// The `ai_test` job: the provider's `complete` asked for one word, its answer or what went
/// wrong kept for whoever asked.
pub fn test_job(ctx: *Ctx, in: Testing) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(in.asked.len > 0);

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
        .request = .{
            .text = request,
        },
    }, .{}) catch return error.OutOfMemory;
    const provider = try providers.registered(ctx, in.provider) orelse {
        return jobs.answer(ctx, in.asked, Tested{
            .ok = false,
            .reply = "The provider is not on.",
        });
    };
    const operation = provider.operation_of("complete").?;
    const SDK = @import("../../server/registry.zig").SDK;
    // A provider reads its model's answer as it arrives: the responses it opens are held
    // here for the run.
    var streams: http_stream.Streams = .{};
    defer streams.deinit();

    ctx.streams = &streams;
    defer ctx.streams = null;

    const output = SDK.call_json(ctx, operation, input) catch |err| {
        return jobs.answer(ctx, in.asked, Tested{
            .ok = false,
            .reply = jobs.problem_of(ctx, err),
        });
    };
    const reply = reply_of(ctx, output) catch |err| {
        return jobs.answer(ctx, in.asked, Tested{
            .ok = false,
            .reply = jobs.problem_of(ctx, err),
        });
    };

    return jobs.answer(ctx, in.asked, Tested{
        .ok = true,
        .reply = reply,
    });
}

fn reply_of(ctx: *Ctx, output: []const u8) Error![]const u8 {
    std.debug.assert(output.len > 0);

    const out = std.json.parseFromSliceLeaky(sdk_ai.Completion.Out, ctx.arena, output, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;
    const response = lib_ai.response_of(ctx.arena, out.response.text) catch return error.Invalid;

    for (response.parts) |part| {
        if (part.kind == .text) {
            return part.text orelse "";
        }
    }

    return "";
}
