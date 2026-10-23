//! `ai.transcribe`: what a person said into the admin, as text. The recording is kept as a
//! private file (`ai_recording`, apart from the library), and a job (core's queued work)
//! sends it to the provider that hears (the chosen one when it does, else the first
//! connected one that does); the page reads the words once they land (`job.answer`).

const std = @import("std");
const sdk = @import("../../sdk.zig");
const sdk_ai = @import("../../sdk/ai.zig");
const environment = @import("../../lib/environment.zig");
const providers = @import("providers.zig");
const model = @import("../../model.zig");
const files_module = @import("../../lib/files.zig");
const upload = @import("../media/upload.zig");
const library = @import("../media/library.zig");
const jobs = @import("../job.zig");
const audio_bytes_max = @import("../../sdk/ai/speech.zig").audio_bytes_max;

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
        \\compressed speech); `format` its media type. It is kept as a private recording,
        \\and answers at once with an id: a connected provider that hears (the one chosen
        \\when it does, else the first with a key set that does) turns it into words in the
        \\background, and `job answer` reads `{ text, provider }` once they land. Anyone
        \\signed in who may ask; fails with NoHearer when no connected provider turns speech
        \\into text.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        audio: []const u8,
        format: []const u8,
    };
    pub const Out = struct {
        /// What `job.answer` reads: `{ text, provider }`.
        asked: []const u8,
    };
    pub const example: In = .{
        .audio = "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQRChYEC",
        .format = "audio/webm;codecs=opus",
    };
    pub const example_out: Out = .{
        .asked = "6a1f0c2e9b3d4a5f60718293",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .audio = "The recording, base64",
        .format = "Its media type (audio/webm, audio/ogg, audio/mp4, audio/wav or " ++
            "audio/mpeg); parameters such as codecs are ignored",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .asked = "For `job answer`: `{ text, provider }`, what was said and the provider " ++
            "that heard it (`scripted` in tests)",
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

        const plugin = try providers.hearer(ctx) orelse "";

        if (plugin.len == 0 and environment.get(providers.script_variable) == null) {
            return ctx.fail(no_hearer);
        }

        const decoder = std.base64.standard.Decoder;
        const bytes = ctx.arena.alloc(u8, decoder.calcSizeForSlice(speech.audio) catch {
            return error.Invalid;
        }) catch return error.OutOfMemory;

        decoder.decode(bytes, speech.audio) catch return error.Invalid;

        const kept = try upload.add(
            ctx,
            try library.files_of(ctx),
            model.ai.recording_type_def,
            speech.file_name(),
            bytes,
            null,
        );

        return .{
            .asked = try jobs.ask(ctx, "transcribe", Hearing{
                .key = kept.key,
                .format = speech.format,
                .plugin = plugin,
            }),
        };
    }
};

pub const Hearing = struct {
    asked: []const u8 = "",
    /// The recording, kept private: its key.
    key: []const u8,
    format: []const u8,
    /// The provider that hears; empty for the scripted words.
    plugin: []const u8,
};

const no_hearer: sdk.operation.Failure = .{
    .name = "NoHearer",
    .status = 409,
    .message = "No connected provider turns speech into text: connect one that does under " ++
        "Settings > AI",
};

const Heard = struct {
    text: []const u8,
    provider: []const u8,
};

/// The `transcribe` job: the recording read from where it is kept and sent to the provider
/// that hears; its words, or why there are none, kept for whoever asked.
pub fn transcribe_job(ctx: *Ctx, in: Hearing) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(in.asked.len > 0);

    if (in.plugin.len == 0) {
        return jobs.answer(ctx, in.asked, Heard{
            .text = environment.get(heard_variable) orelse "Scripted words",
            .provider = providers.scripted,
        });
    }

    const files = try library.files_of(ctx);
    const bytes = files.read(ctx.arena, .files, in.key, audio_bytes_max) catch {
        return jobs.fail(ctx, in.asked, "The recording is gone");
    };
    const encoder = std.base64.standard.Encoder;
    const audio = ctx.arena.alloc(u8, encoder.calcSize(bytes.len)) catch {
        return error.OutOfMemory;
    };
    const text = heard(ctx, in.plugin, .{
        .audio = encoder.encode(audio, bytes),
        .format = in.format,
    }) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        return jobs.fail(ctx, in.asked, jobs.problem_of(ctx, err));
    };

    return jobs.answer(ctx, in.asked, Heard{
        .text = text,
        .provider = in.plugin,
    });
}

/// `<plugin>.transcribe`, as the system: who may ask was checked, the plugin's own
/// operations are core's to call.
fn heard(ctx: *Ctx, plugin: []const u8, speech: sdk_ai.Speech) Error![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(speech.audio.len > 0);

    const SDK = @import("../../server/registry.zig").SDK;
    const found = try providers.registered(ctx, plugin) orelse return error.NotFound;
    const operation = found.operation_of("transcribe") orelse return error.NotFound;
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
