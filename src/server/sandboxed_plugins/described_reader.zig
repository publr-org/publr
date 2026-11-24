//! The bytes of a plugin's description, taken in order: never past their end.
const std = @import("std");

const Error = @import("described.zig").Error;

pub const Reader = struct {
    text: []const u8,
    at: u32 = 0,

    pub fn take(reader: *Reader, len: u32) Error![]const u8 {
        std.debug.assert(reader.at <= reader.text.len);

        if (len > reader.text.len - reader.at) {
            return error.Invalid;
        }

        reader.at += len;

        return reader.text[reader.at - len .. reader.at];
    }

    pub fn byte(reader: *Reader) Error!u8 {
        const taken = try reader.take(1);

        std.debug.assert(taken.len == 1);

        return taken[0];
    }

    pub fn word(reader: *Reader) Error!u32 {
        const bytes = try reader.take(4);

        std.debug.assert(bytes.len == 4);

        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    pub fn name(reader: *Reader) Error![]const u8 {
        const len = try reader.byte();

        std.debug.assert(reader.at <= reader.text.len);

        if (len == 0) {
            return error.Invalid;
        }

        return reader.take(len);
    }

    /// Whether a number or an enum may take `size` bytes.
    pub fn whole_size(size: u8) bool {
        const whole = size == 1 or size == 2 or size == 4 or size == 8;

        std.debug.assert(!whole or size <= 8);

        return whole;
    }
};
