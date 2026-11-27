//! Random bytes from the host's cryptographic source: what a plugin's `ctx.random(&buffer)`
//! reads, compiled in and installed alike (a sandboxed module has no source of its own).
const operation = @import("../operation.zig");

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
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        bytes: u32 = 16,
    };
    pub const Out = struct {
        hex: []const u8,
    };
    pub const field_docs: operation.Docs(In) = .{
        .bytes = "How many bytes, 1 to 64",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .hex = "The bytes as lowercase hex, two characters each",
    };
    pub const example: In = .{
        .bytes = 4,
    };
    pub const example_out: Out = .{
        .hex = "9f04c2e1",
    };
};
