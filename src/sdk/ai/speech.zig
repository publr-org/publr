//! Speech to text, as a provider plugin offers it: `<plugin>.transcribe`, a recording in,
//! its words out. A provider that offers it says `speech` in its description; core's
//! `ai.transcribe` asks the one chosen, else the first connected one that hears.

const std = @import("std");
const operation = @import("../operation.zig");
const Grant = @import("../grant.zig").Grant;
const PluginCtx = @import("../plugin/context.zig").PluginCtx;

pub const transcribe_verb = "transcribe";

/// A recording, at most two minutes of the browser's compressed speech.
pub const audio_bytes_max: u32 = 768 << 10;
/// Its words, at most.
pub const text_len_max: u32 = 16 << 10;

/// A recording as a provider gets it.
pub const Speech = struct {
    /// The recording, base64.
    audio: []const u8,
    /// Its media type, without parameters: `audio/webm`, `audio/ogg`, `audio/mp4`,
    /// `audio/wav` or `audio/mpeg`.
    format: []const u8,

    /// The file name a provider that takes files names it by: `speech.webm`.
    pub fn file_name(speech: Speech) []const u8 {
        std.debug.assert(speech.format.len > 0);

        const names = [_][2][]const u8{
            .{ "audio/webm", "speech.webm" },
            .{ "audio/ogg", "speech.ogg" },
            .{ "audio/mp4", "speech.mp4" },
            .{ "audio/wav", "speech.wav" },
            .{ "audio/mpeg", "speech.mp3" },
        };

        for (names) |pair| {
            if (std.mem.eql(u8, pair[0], speech.format)) {
                return pair[1];
            }
        }

        return "";
    }

    pub fn valid(speech: Speech) bool {
        std.debug.assert(audio_bytes_max > 0);

        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(speech.audio) catch return false;

        return size > 0 and size <= audio_bytes_max and speech.file_name().len > 0;
    }
};

/// `<plugin>.transcribe`: a recording's words. `hear` sends it to the provider's model.
pub fn Transcribe(
    comptime plugin: []const u8,
    comptime hear: fn (ctx: *PluginCtx, speech: Speech) operation.Error![]const u8,
) type {
    return struct {
        pub const name = plugin ++ "." ++ transcribe_verb;
        pub const description = "The words said in a recording";
        pub const details =
            \\`audio` is the recording, base64 (up to 768 KiB of audio: WebM, Ogg, MP4, WAV or
            \\MP3, `format` saying which); the answer is what was said, as written text.
            \\Nothing is kept. The local operator's alone: core's `ai.transcribe` calls it.
        ;
        pub const kind: operation.Kind = .read;
        pub const operator_only = true;
        pub const failures = @import("../ai.zig").provider_failures;
        pub const In = Speech;
        pub const Out = struct {
            text: []const u8,
        };
        pub const example: In = .{
            .audio = "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQRChYEC",
            .format = "audio/webm",
        };
        pub const example_out: Out = .{
            .text = "Add a contact page.",
        };
        pub const field_docs: operation.Docs(In) = .{
            .audio = "The recording, base64",
            .format = "Its media type: audio/webm, audio/ogg, audio/mp4, audio/wav or audio/mpeg",
        };

        pub fn run(ctx: *PluginCtx, in: In, granted: *const Grant) operation.Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(text_len_max > 0);

            if (!in.valid()) {
                return error.Invalid;
            }

            const text = std.mem.trim(u8, try hear(ctx, in), " \t\r\n");

            if (text.len > text_len_max) {
                return error.Invalid;
            }

            return .{
                .text = text,
            };
        }
    };
}

test "a recording names its file by its type, and is checked for size" {
    const webm: Speech = .{
        .audio = "GkXfow==",
        .format = "audio/webm",
    };

    try std.testing.expectEqualStrings("speech.webm", webm.file_name());
    try std.testing.expect(webm.valid());
    try std.testing.expect(!(Speech{
        .audio = "GkXfow==",
        .format = "video/webm",
    }).valid());
    try std.testing.expect(!(Speech{
        .audio = "not base64!",
        .format = "audio/webm",
    }).valid());
    try std.testing.expect(!(Speech{
        .audio = "",
        .format = "audio/webm",
    }).valid());
}
