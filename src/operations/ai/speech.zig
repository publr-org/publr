//! `ai.transcribe`: what a person said into the admin, as text. The recording goes to the
//! provider that hears (the chosen one when it does, else the first connected one that
//! does) and is not kept.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const sdk_ai = @import("../../sdk/ai.zig");
const environment = @import("../../lib/environment.zig");
const providers = @import("providers.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{Transcribe};

/// With `PUBLR_AI_SCRIPT` and no provider that hears, the words every recording is heard
/// as; "Scripted words" when unset.
pub const heard_variable = "PUBLR_AI_SCRIPT_HEARD";

pub const Transcribe = struct {
    pub const name = "ai.transcribe";
    pub const description = "Turn a recording of speech into its words";
    pub const details =
        \\`audio` is the recording, base64, up to 768 KiB (two minutes of the browser's
        \\compressed speech); `format` its media type. A connected provider that hears
        \\answers: the one chosen when it does, else the first with a key set that does.
        \\Nothing is kept. Anyone signed in who may ask; fails with NoHearer when no
        \\connected provider turns speech into text.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        audio: []const u8,
        format: []const u8,
    };
    pub const Out = struct {
        text: []const u8,
        /// The plugin that heard it.
        provider: []const u8,
    };
    pub const example: In = .{
        .audio = "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQRChYEC",
        .format = "audio/webm;codecs=opus",
    };
    pub const example_out: Out = .{
        .text = "Add a contact page.",
        .provider = "ai_example",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .audio = "The recording, base64",
        .format = "Its media type (audio/webm, audio/ogg, audio/mp4, audio/wav or " ++
            "audio/mpeg); parameters such as codecs are ignored",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .text = "What was said",
        .provider = "The provider that heard it; `scripted` in tests",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (ctx.caller.user_id() == null) {
            return error.Denied;
        }

        const speech: sdk_ai.Speech = .{
            .audio = in.audio,
            .format = media_type_of(in.format),
        };

        if (!speech.valid()) {
            return error.Invalid;
        }

        const plugin = try providers.hearer(ctx) orelse {
            if (environment.get(providers.script_variable) == null) {
                return ctx.fail(no_hearer);
            }

            return .{
                .text = environment.get(heard_variable) orelse "Scripted words",
                .provider = providers.scripted,
            };
        };

        return .{
            .text = try heard(ctx, plugin, speech),
            .provider = plugin,
        };
    }
};

const no_hearer: sdk.operation.Failure = .{
    .name = "NoHearer",
    .status = 409,
    .message = "No connected provider turns speech into text: connect one that does under " ++
        "Settings > AI",
};

/// `<plugin>.transcribe`, as the system: who may ask was checked, the plugin's own
/// operations are core's to call.
fn heard(ctx: *Ctx, plugin: []const u8, speech: sdk_ai.Speech) Error![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(speech.audio.len > 0);

    const SDK = @import("../../server/registry.zig").SDK;
    const operation = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{
        plugin,
        sdk_ai.transcribe_verb,
    });
    const input = std.json.Stringify.valueAlloc(ctx.arena, speech, .{}) catch {
        return error.OutOfMemory;
    };
    const saved = ctx.caller;

    ctx.caller = .system;
    defer ctx.caller = saved;

    const output = try SDK.call_json(ctx, operation, input);
    const Said = struct {
        text: []const u8,
    };
    const said = std.json.parseFromSliceLeaky(Said, ctx.arena, output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.Invalid;

    return said.text;
}

/// `audio/webm;codecs=opus` as `audio/webm`.
fn media_type_of(format: []const u8) []const u8 {
    std.debug.assert(format.len <= std.math.maxInt(u32));

    const end = std.mem.indexOfScalar(u8, format, ';') orelse format.len;
    const media_type = std.mem.trim(u8, format[0..end], " ");

    std.debug.assert(media_type.len <= format.len);

    return media_type;
}

test "a recording's type is read without its parameters" {
    try std.testing.expectEqualStrings("audio/webm", media_type_of("audio/webm;codecs=opus"));
    try std.testing.expectEqualStrings("audio/mp4", media_type_of("audio/mp4"));
    try std.testing.expectEqualStrings("", media_type_of(""));
}
