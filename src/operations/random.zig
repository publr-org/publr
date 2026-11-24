//! Random bytes from the host's cryptographic source: what a plugin's `ctx.random(&buffer)`
//! reads, compiled in and installed alike (a sandboxed module has no source of its own).
const std = @import("std");
const sdk = @import("../sdk.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const bytes_max: u32 = 64;

pub const Random = struct {
    pub const name = "project.random";
    pub const open = true;
    pub const description = "Random bytes from the host's cryptographic source";
    pub const details =
        \\Anyone. What a plugin's `ctx.random(&buffer)` reads: `bytes` (1 to 64) random
        \\bytes from the operating system's cryptographic source, as lowercase hex, for
        \\codes a person must not guess (a locker's pickup code, a voucher). Changes nothing.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        bytes: u32 = 16,
    };
    pub const Out = struct {
        hex: []const u8,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .bytes = "How many bytes, 1 to 64",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .hex = "The bytes as lowercase hex, two characters each",
    };
    pub const example: In = .{
        .bytes = 4,
    };
    pub const example_out: Out = .{
        .hex = "9f04c2e1",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.bytes == 0 or in.bytes > bytes_max) {
            return error.Invalid;
        }

        var raw: [bytes_max]u8 = undefined;

        ctx.io.random(raw[0..in.bytes]);

        const hex = std.fmt.bytesToHex(raw, .lower);
        const kept = ctx.arena.dupe(u8, hex[0 .. in.bytes * 2]) catch return error.OutOfMemory;

        std.debug.assert(kept.len == in.bytes * 2);

        return .{
            .hex = kept,
        };
    }
};

/// The hex `project.random` answers, read back into `buffer`.
pub fn fill(buffer: []u8, hex: []const u8) Error!void {
    std.debug.assert(buffer.len <= bytes_max);

    if (hex.len != buffer.len * 2) {
        return error.Invalid;
    }

    _ = std.fmt.hexToBytes(buffer, hex) catch return error.Invalid;
}

pub const operations = [_]type{Random};

test "random: bytes read back from hex, a wrong length refused" {
    var buffer: [4]u8 = undefined;

    try fill(&buffer, "9f04c2e1");
    try std.testing.expectEqualSlices(u8, &.{ 0x9f, 0x04, 0xc2, 0xe1 }, &buffer);
    try std.testing.expectError(error.Invalid, fill(&buffer, "9f04"));
}
