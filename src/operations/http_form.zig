//! A form upload a plugin sends (`http.fetch`'s `form`), written here as
//! `multipart/form-data`: a file goes as base64, which JSON can carry, and leaves as its
//! bytes. A plugin never encodes files itself.

const std = @import("std");

/// Parts in one form, at most.
pub const parts_max: u32 = 16;
const boundary_len: u32 = 32;

pub const Part = struct {
    name: []const u8,
    /// The text, or a file's bytes as base64 when `file_name` is set.
    value: []const u8 = "",
    /// Set for a file: the name it is uploaded under.
    file_name: []const u8 = "",
    /// A file's media type; `application/octet-stream` when empty.
    content_type: []const u8 = "",
};

pub const Written = struct {
    body: []const u8,
    /// The `Content-Type` header's value, with the boundary.
    content_type: []const u8,
};

pub const Problem = error{ Invalid, OutOfMemory };

/// `parts` as a multipart body, between lines of `seed`'s random boundary.
pub fn write(
    arena: std.mem.Allocator,
    parts: []const Part,
    seed: [boundary_len / 2]u8,
) Problem!Written {
    std.debug.assert(parts.len > 0);
    std.debug.assert(parts.len <= parts_max);

    const boundary = std.fmt.bytesToHex(seed, .lower);
    var body: std.ArrayList(u8) = .empty;

    for (parts) |part| {
        if (part.name.len == 0 or !plain(part.name) or !plain(part.file_name) or
            !plain(part.content_type))
        {
            return error.Invalid;
        }

        try body.print(arena, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"", .{
            &boundary,
            part.name,
        });

        if (part.file_name.len == 0) {
            try body.print(arena, "\r\n\r\n{s}\r\n", .{part.value});
            continue;
        }

        const media_type = if (part.content_type.len > 0)
            part.content_type
        else
            "application/octet-stream";

        try body.print(arena, "; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n", .{
            part.file_name,
            media_type,
        });
        try append_decoded(arena, &body, part.value);
        try body.appendSlice(arena, "\r\n");
    }

    try body.print(arena, "--{s}--\r\n", .{&boundary});

    return .{
        .body = body.items,
        .content_type = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{
            &boundary,
        }),
    };
}

/// On one line, without quotes: what a part's header may hold.
fn plain(text: []const u8) bool {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '"') {
            return false;
        }
    }

    return true;
}

fn append_decoded(
    arena: std.mem.Allocator,
    body: *std.ArrayList(u8),
    encoded: []const u8,
) Problem!void {
    std.debug.assert(encoded.len <= std.math.maxInt(u32));

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.Invalid;
    const start = body.items.len;

    try body.resize(arena, start + size);
    decoder.decode(body.items[start..], encoded) catch return error.Invalid;
    std.debug.assert(body.items.len == start + size);
}

test "a form's text and files are written as multipart, files as their bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const seed = [_]u8{0xab} ** (boundary_len / 2);
    const written = try write(arena_state.allocator(), &.{
        .{
            .name = "model",
            .value = "small",
        },
        .{
            .name = "file",
            .value = "aGk=",
            .file_name = "speech.webm",
            .content_type = "audio/webm",
        },
    }, seed);
    const boundary = "abababababababababababababababab";

    const content_type = "multipart/form-data; boundary=" ++ boundary;

    try std.testing.expectEqualStrings(content_type, written.content_type);
    try std.testing.expectEqualStrings("--" ++ boundary ++
        "\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nsmall\r\n" ++
        "--" ++ boundary ++ "\r\nContent-Disposition: form-data; name=\"file\"; " ++
        "filename=\"speech.webm\"\r\nContent-Type: audio/webm\r\n\r\nhi\r\n" ++
        "--" ++ boundary ++ "--\r\n", written.body);
}

test "a form's headers stay on one line, and a file must be base64" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const seed = [_]u8{0} ** (boundary_len / 2);

    try std.testing.expectError(error.Invalid, write(arena_state.allocator(), &.{.{
        .name = "a\"b",
    }}, seed));
    try std.testing.expectError(error.Invalid, write(arena_state.allocator(), &.{.{
        .name = "file",
        .value = "not base64!",
        .file_name = "x.bin",
    }}, seed));
}
