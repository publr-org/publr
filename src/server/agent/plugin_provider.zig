//! A provider plugin, as the agent calls it: `<plugin>.complete` run here, in the agent's
//! own process with its own connection to the project, so a model taking its time never
//! holds up the server. The plugin calls out through `http.fetch`, which fills in its key.

const std = @import("std");
const server = @import("../../server.zig");
const registry = @import("../registry.zig");
const sdk = @import("../../sdk.zig");
const ai = @import("../../lib/ai.zig");
const sdk_ai = @import("../../sdk/ai.zig");
const http_stream = @import("../../operations/http_stream.zig");

/// What a turn runs as: core's queued work (`ai.ask` starts it, answering at once), in the
/// agent's own process.
const turn_job = "publr.turn";

pub const PluginProvider = struct {
    application: *server.Server,
    io: std.Io,
    /// `<plugin>.complete`.
    operation: []const u8,
    /// The responses the plugin reads as streams, open across its calls.
    streams: http_stream.Streams = .{},
    /// Where the words go as the plugin streams them.
    progress: ?sdk.context.Progress = null,

    pub fn provider(plugin_provider: *PluginProvider) ai.Provider {
        std.debug.assert(plugin_provider.operation.len > 0);
        std.debug.assert(std.mem.endsWith(u8, plugin_provider.operation, sdk_ai.complete_verb));

        return .{
            .context = plugin_provider,
            .complete_fn = complete,
        };
    }

    /// A web page as text, read through the provider's `read_page`.
    pub fn read(
        plugin_provider: *PluginProvider,
        arena: std.mem.Allocator,
        url: []const u8,
    ) ![]const u8 {
        std.debug.assert(url.len > 0);
        std.debug.assert(plugin_provider.operation.len > sdk_ai.complete_verb.len);

        var ctx = plugin_provider.context_of(arena);
        const operation_name = plugin_provider.operation;
        const plugin = operation_name[0 .. operation_name.len - sdk_ai.complete_verb.len];
        const operation = try std.mem.concat(arena, u8, &.{ plugin, sdk_ai.read_verb });
        const input = try std.json.Stringify.valueAlloc(arena, .{
            .url = url,
        }, .{});
        const output = registry.SDK.call_json(&ctx, operation, input) catch |err| {
            const failure = if (ctx.failure) |found| found.message else @errorName(err);

            return std.fmt.allocPrint(arena, "Could not read it: {s}", .{failure});
        };
        const Out = struct {
            status: u16,
            text: []const u8,
        };
        const out = std.json.parseFromSliceLeaky(Out, arena, output, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;

        if (out.status != 200) {
            const said = .{ out.status, out.text };

            return std.fmt.allocPrint(arena, "The page answered {d}.\n{s}", said);
        }

        return out.text;
    }

    /// Whether the provider says its models look at pictures; one written before pictures
    /// were does not say, and is sent none.
    pub fn reads_pictures(plugin_provider: *PluginProvider, arena: std.mem.Allocator) bool {
        std.debug.assert(plugin_provider.operation.len > sdk_ai.complete_verb.len);

        var ctx = plugin_provider.context_of(arena);
        const operation_name = plugin_provider.operation;
        const plugin = operation_name[0 .. operation_name.len - sdk_ai.complete_verb.len];
        const operation = std.mem.concat(arena, u8, &.{ plugin, sdk_ai.describe_verb }) catch {
            return false;
        };
        const output = registry.SDK.call_json(&ctx, operation, "{}") catch return false;
        const Said = struct {
            pictures: bool = false,
        };
        const said = std.json.parseFromSliceLeaky(Said, arena, output, .{
            .ignore_unknown_fields = true,
        }) catch return false;

        return said.pictures;
    }

    fn context_of(plugin_provider: *PluginProvider, arena: std.mem.Allocator) sdk.Ctx {
        const application = plugin_provider.application;

        std.debug.assert(plugin_provider.operation.len > 0);

        var ctx = sdk.Ctx.init(
            &application.connection,
            plugin_provider.io,
            arena,
            &application.auth,
            .system,
            .{
                .now_ms = sdk.context.wall_clock_ms(plugin_provider.io),
            },
        );

        // The turn is queued work, never a request: the provider may call out.
        ctx.job = turn_job;
        ctx.sandboxed_plugins = application.sandboxed();
        ctx.plugin_states = &application.plugin_states;
        ctx.files = application.files_of();
        ctx.streams = &plugin_provider.streams;
        ctx.progress = plugin_provider.progress;

        return ctx;
    }

    fn complete(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: ai.Request,
    ) ai.Error!ai.Response {
        const plugin_provider: *PluginProvider = @ptrCast(@alignCast(context));

        std.debug.assert(request.messages.len > 0);

        var ctx = plugin_provider.context_of(arena);

        const request_text = ai.request_json(arena, request) catch return error.OutOfMemory;
        const in: sdk_ai.Completion.In = .{
            .request = request_text,
        };
        const input = std.json.Stringify.valueAlloc(arena, in, .{}) catch return error.OutOfMemory;
        const output = registry.SDK.call_json(&ctx, plugin_provider.operation, input) catch |err| {
            return failure_of(&ctx, err);
        };
        const out = std.json.parseFromSliceLeaky(sdk_ai.Completion.Out, arena, output, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;

        return ai.response_of(arena, out.response) catch error.InvalidResponse;
    }
};

/// A provider's refusal in the loop's words: a missing key, a refused one, a limit.
fn failure_of(ctx: *const sdk.Ctx, err: anyerror) ai.Error {
    std.debug.assert(ctx.now_ms >= 0);

    const failure = ctx.failure orelse {
        std.log.warn("provider: {t}", .{err});

        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
    };

    std.log.warn("provider: {s}: {s}", .{ failure.name, failure.message });

    if (std.mem.eql(u8, failure.name, "SecretMissing")) {
        return error.KeyMissing;
    }

    if (std.mem.eql(u8, failure.name, "KeyRejected")) {
        return error.KeyRejected;
    }

    if (std.mem.eql(u8, failure.name, "Limited")) {
        return error.Limited;
    }

    return error.Unavailable;
}
