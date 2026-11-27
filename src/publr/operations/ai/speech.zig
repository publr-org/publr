//! `ai.transcribe`: what a person said into the admin, as text. The recording is kept as a
//! private file (`ai_recording`, apart from the library), and a job (core's queued work)
//! sends it to the provider that hears (the chosen one when it does, else the first
//! connected one that does); the page reads the words once they land (`job.answer`).
const operation = @import("../../operation.zig");

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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .audio = "The recording, base64",
        .format = "Its media type (audio/webm, audio/ogg, audio/mp4, audio/wav or " ++
            "audio/mpeg); parameters such as codecs are ignored",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .asked = "For `job answer`: `{ text, provider }`, what was said and the provider " ++
            "that heard it (`scripted` in tests)",
    };
};
