//! Resizing, cropping and re-encoding images in memory on the vendored stb and libwebp: what
//! a media address with `?w=` asks for. JPEG and PNG are read; JPEG, PNG and WebP written.

const std = @import("std");
const builtin = @import("builtin");

const api = @import("image/api.zig").api;
const Pixels = @import("image/pixels.zig");
const encode = @import("image/encode.zig");

/// What one image may hold once decoded, so a small file cannot claim gigabytes of pixels.
pub const pixels_max: u64 = 40_000_000;
pub const side_max: u32 = 16_384;
pub const quality_default: u8 = 90;
pub const suffix_len_max: u32 = 64;
/// The browser build keeps the source's format, as the old one did: libwebp would make the
/// module a third larger for copies a page shows once.
pub const webp_written = builtin.os.tag != .wasi;

pub const Format = enum {
    jpeg,
    png,
    webp,

    pub fn mime_type(format: Format) []const u8 {
        const name = switch (format) {
            .jpeg => "image/jpeg",
            .png => "image/png",
            .webp => "image/webp",
        };

        std.debug.assert(std.mem.startsWith(u8, name, "image/"));

        return name;
    }

    pub fn extension(format: Format) []const u8 {
        const name = switch (format) {
            .jpeg => ".jpg",
            .png => ".png",
            .webp => ".webp",
        };

        std.debug.assert(name[0] == '.');

        return name;
    }
};

/// With a width and a height: `crop` cuts that many pixels around the focal point at full
/// resolution, `cover` scales the image down until it covers them, then cuts.
pub const Fit = enum { crop, cover };

pub const Params = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    /// Where the subject is, in percent of the width and the height.
    focal_x: u8 = 50,
    focal_y: u8 = 50,
    fit: Fit = .crop,
    /// Null keeps the source's format.
    format: ?Format = null,
    quality: u8 = quality_default,
};

pub const Processed = struct { bytes: []u8, format: Format, width: u32, height: u32 };

pub const Size = struct { width: u32, height: u32 };

pub const Error = error{ Decode, TooLarge, Resize, Encode, OutOfMemory };

/// The dimensions of any image stb reads, without decoding it; null when it is not one.
pub fn size_of(bytes: []const u8) ?Size {
    std.debug.assert(bytes.len <= std.math.maxInt(c_int));

    if (bytes.len == 0) {
        return null;
    }

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const length: c_int = @intCast(bytes.len);

    if (api.stbi_info_from_memory(bytes.ptr, length, &width, &height, &channels) == 0) {
        return null;
    }

    std.debug.assert(width > 0 and height > 0);

    return .{ .width = @intCast(width), .height = @intCast(height) };
}

/// Whether `process` reads files of this type.
pub fn processable(mime_type: []const u8) bool {
    std.debug.assert(mime_type.len <= 255);

    const found = std.mem.eql(u8, mime_type, "image/jpeg") or
        std.mem.eql(u8, mime_type, "image/png");

    std.debug.assert(!found or std.mem.startsWith(u8, mime_type, "image/"));

    return found;
}

/// WebP when the request's `Accept` takes it, else the source's own format.
pub fn negotiate(accept: ?[]const u8, source_mime: []const u8) Format {
    std.debug.assert(source_mime.len > 0);

    const source: Format = if (std.mem.eql(u8, source_mime, "image/png")) .png else .jpeg;
    const header = accept orelse return source;

    std.debug.assert(header.len <= 8 << 10);

    if (webp_written and std.mem.indexOf(u8, header, "image/webp") != null) {
        return .webp;
    }

    return source;
}

/// The name a processed copy is cached under, after the source's stem: `_w600`,
/// `_w80_h80_cover_fp30-20_q75.webp`. Defaults leave no mark.
pub fn cache_suffix(
    buffer: *[suffix_len_max]u8,
    params: Params,
    format: Format,
    source_mime: []const u8,
) []const u8 {
    std.debug.assert(source_mime.len > 0);
    std.debug.assert(params.quality >= 1 and params.quality <= 100);

    var writer = std.Io.Writer.fixed(buffer);

    write_suffix(&writer, params, format, source_mime) catch unreachable;

    const written = writer.buffered();

    std.debug.assert(written.len < suffix_len_max);

    return written;
}

fn write_suffix(
    writer: *std.Io.Writer,
    params: Params,
    format: Format,
    source_mime: []const u8,
) std.Io.Writer.Error!void {
    std.debug.assert(params.focal_x <= 100 and params.focal_y <= 100);
    std.debug.assert(source_mime.len > 0);

    if (params.width) |width| {
        try writer.print("_w{d}", .{width});
    }

    if (params.height) |height| {
        try writer.print("_h{d}", .{height});
    }

    if (params.width != null and params.height != null) {
        if (params.fit == .cover) {
            try writer.writeAll("_cover");
        }

        if (params.focal_x != 50 or params.focal_y != 50) {
            try writer.print("_fp{d}-{d}", .{ params.focal_x, params.focal_y });
        }
    }

    if (params.quality != quality_default) {
        try writer.print("_q{d}", .{params.quality});
    }

    const converted = !std.mem.eql(u8, source_mime, format.mime_type());

    if (converted) {
        try writer.writeAll(format.extension());
    }
}

/// Decode, resize or crop as asked (never larger than the source), encode. The bytes are the
/// caller's, from `allocator`.
pub fn process(allocator: std.mem.Allocator, source: []const u8, params: Params) Error!Processed {
    std.debug.assert(params.quality >= 1 and params.quality <= 100);
    std.debug.assert(params.focal_x <= 100 and params.focal_y <= 100);

    const size = size_of(source) orelse return error.Decode;
    const pixels_count = @as(u64, size.width) * size.height;

    if (size.width > side_max or size.height > side_max or pixels_count > pixels_max) {
        return error.TooLarge;
    }

    var pixels = try Pixels.decode(source);
    defer pixels.deinit(allocator);

    try pixels.apply(allocator, params);

    const format = params.format orelse source_format(source);
    const bytes = try encode.encode(allocator, pixels.view(), format, params.quality);

    std.debug.assert(bytes.len > 0);

    return .{ .bytes = bytes, .format = format, .width = pixels.width, .height = pixels.height };
}

fn source_format(source: []const u8) Format {
    std.debug.assert(source.len > 0);

    const png_magic = "\x89PNG";

    if (std.mem.startsWith(u8, source, png_magic)) {
        return .png;
    }

    return .jpeg;
}

test "processable: JPEG and PNG only" {
    try std.testing.expect(processable("image/jpeg"));
    try std.testing.expect(processable("image/png"));
    try std.testing.expect(!processable("image/gif"));
    try std.testing.expect(!processable("image/webp"));
    try std.testing.expect(!processable("application/pdf"));
}

test "negotiate: WebP when accepted, else the source's format" {
    try std.testing.expectEqual(Format.webp, negotiate("image/avif,image/webp,*/*", "image/jpeg"));
    try std.testing.expectEqual(Format.webp, negotiate("image/webp", "image/png"));
    try std.testing.expectEqual(Format.jpeg, negotiate("text/html,*/*", "image/jpeg"));
    try std.testing.expectEqual(Format.png, negotiate(null, "image/png"));
}

test "cache_suffix: what differs from the defaults" {
    var buffer: [suffix_len_max]u8 = undefined;
    const cases = [_]struct { params: Params, format: Format, expected: []const u8 }{
        .{ .params = .{ .width = 600 }, .format = .jpeg, .expected = "_w600" },
        .{ .params = .{ .width = 300 }, .format = .webp, .expected = "_w300.webp" },
        .{ .params = .{ .height = 400 }, .format = .jpeg, .expected = "_h400" },
        .{ .params = .{ .width = 80, .height = 80 }, .format = .jpeg, .expected = "_w80_h80" },
        .{
            .params = .{ .width = 80, .height = 80, .focal_x = 34, .focal_y = 25 },
            .format = .jpeg,
            .expected = "_w80_h80_fp34-25",
        },
        .{
            .params = .{ .width = 80, .height = 80, .fit = .cover },
            .format = .jpeg,
            .expected = "_w80_h80_cover",
        },
        .{ .params = .{ .width = 300, .quality = 80 }, .format = .jpeg, .expected = "_w300_q80" },
        .{ .params = .{}, .format = .webp, .expected = ".webp" },
        .{ .params = .{ .focal_x = 10 }, .format = .jpeg, .expected = "" },
    };

    for (cases) |case| {
        const suffix = cache_suffix(&buffer, case.params, case.format, "image/jpeg");

        try std.testing.expectEqualStrings(case.expected, suffix);
    }
}

test "size_of: refuses what is not an image" {
    try std.testing.expect(size_of("") == null);
    try std.testing.expect(size_of("not an image at all") == null);
}

test "process: resizes a PNG by width, keeping the ratio" {
    const allocator = std.testing.allocator;
    const source = try encode.sample_png(allocator, 8, 4);
    defer allocator.free(source);

    try std.testing.expectEqual(Size{ .width = 8, .height = 4 }, size_of(source).?);

    const resized = try process(allocator, source, .{ .width = 4 });
    defer allocator.free(resized.bytes);

    try std.testing.expectEqual(@as(u32, 4), resized.width);
    try std.testing.expectEqual(@as(u32, 2), resized.height);
    try std.testing.expectEqual(Format.png, resized.format);
    try std.testing.expectEqual(Size{ .width = 4, .height = 2 }, size_of(resized.bytes).?);
}

test "process: never upscales, crops and covers, writes JPEG and WebP" {
    const allocator = std.testing.allocator;
    const source = try encode.sample_png(allocator, 8, 4);
    defer allocator.free(source);

    const same = try process(allocator, source, .{ .width = 100 });
    defer allocator.free(same.bytes);

    try std.testing.expectEqual(@as(u32, 8), same.width);

    const cropped = try process(allocator, source, .{ .width = 2, .height = 2, .format = .jpeg });
    defer allocator.free(cropped.bytes);

    try std.testing.expectEqual(Size{ .width = 2, .height = 2 }, size_of(cropped.bytes).?);

    const covered = try process(allocator, source, .{
        .width = 2,
        .height = 2,
        .fit = .cover,
        .format = .webp,
    });
    defer allocator.free(covered.bytes);

    try std.testing.expectEqual(@as(u32, 2), covered.width);
    try std.testing.expect(std.mem.startsWith(u8, covered.bytes, "RIFF"));
    try std.testing.expectError(error.Decode, process(allocator, "nope", .{ .width = 2 }));
}
