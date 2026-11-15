//! Encode text as base64.
//!
//! The text in standard base64, worked out by the plugin itself with Zig's own encoder: an
//! installed plugin's build must carry it whole. Administrators may call it; text over
//! 4,096 bytes is refused as Invalid.
//!
//! Example:
//!   in: { "text": "hello, wasm" }
//!   out: { "base64": "aGVsbG8sIHdhc20=" }
const publr = @import("publr");
const std = @import("std");

const encoder = std.base64.standard.Encoder;
const text_bytes_max: u32 = 4096;

pub const In = struct {
    /// The text to encode
    text: []const u8 = "",
};

pub const Out = struct {
    /// The text in standard base64
    base64: []const u8,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.text.len > text_bytes_max) {
        return error.Invalid;
    }

    var buffer: [encoder.calcSize(text_bytes_max)]u8 = undefined;
    const encoded = encoder.encode(&buffer, in.text);

    std.debug.assert(encoded.len == encoder.calcSize(in.text.len));

    return .{
        .base64 = try ctx.arena().dupe(u8, encoded),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "encode",
    .kind = .read,
    .run = run,
});
