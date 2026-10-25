//! An app file's bytes as an operation carries them: text when they are UTF-8, else base64
//! (an icon, an image, a font), so any file fits a JSON field.
const std = @import("std");
const file_path = @import("file_path.zig");

pub const Encoding = enum {
    text,
    base64,
};

pub const Carried = struct {
    content: []const u8,
    encoding: Encoding = .text,
};

/// `bytes` as carried: as they are when UTF-8, else base64.
pub fn carried(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Carried {
    std.debug.assert(bytes.len <= file_path.bytes_max);

    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{
            .content = bytes,
        };
    }

    const encoder = std.base64.standard.Encoder;
    const text = try arena.alloc(u8, encoder.calcSize(bytes.len));
    const written = encoder.encode(text, bytes);

    std.debug.assert(written.len == text.len);

    return .{
        .content = written,
        .encoding = .base64,
    };
}

/// The bytes `content` carries; Invalid when it is not what `encoding` says, TooBig past
/// an app file's limit.
pub fn bytes_of(
    arena: std.mem.Allocator,
    content: []const u8,
    encoding: Encoding,
) error{ OutOfMemory, Invalid, TooBig }![]const u8 {
    std.debug.assert(content.len < 1 << 32);

    switch (encoding) {
        .text => {
            if (!std.unicode.utf8ValidateSlice(content)) {
                return error.Invalid;
            }

            if (content.len > file_path.bytes_max) {
                return error.TooBig;
            }

            return content;
        },
        .base64 => {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(content) catch return error.Invalid;

            if (size > file_path.bytes_max) {
                return error.TooBig;
            }

            const bytes = try arena.alloc(u8, size);

            decoder.decode(bytes, content) catch return error.Invalid;

            return bytes;
        },
    }
}

test "text stays text, anything else goes as base64 and comes back whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const page = try carried(arena, "<h1>Cześć</h1>\n");

    try std.testing.expectEqual(Encoding.text, page.encoding);
    try std.testing.expectEqualStrings("<h1>Cześć</h1>\n", page.content);

    const icon = [_]u8{ 0x00, 0x00, 0x01, 0x00, 0xff, 0xfe };
    const sent = try carried(arena, &icon);

    try std.testing.expectEqual(Encoding.base64, sent.encoding);
    try std.testing.expectEqualSlices(u8, &icon, try bytes_of(arena, sent.content, .base64));
}

test "a carried file that is not what it says is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Invalid, bytes_of(arena, "\xff\xfe", .text));
    try std.testing.expectError(error.Invalid, bytes_of(arena, "not base64!", .base64));
}
