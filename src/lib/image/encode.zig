//! Pixels to bytes: JPEG and PNG through stb's writers, WebP through libwebp (lossless when the
//! pixels carry transparency, so it survives).

const std = @import("std");
const api = @import("api.zig").api;
const image = @import("../image.zig");
const View = @import("pixels.zig").View;

const Sink = struct {
    list: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    failed: bool = false,
};

fn write_to_sink(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    std.debug.assert(context != null);
    std.debug.assert(size >= 0);

    const sink: *Sink = @ptrCast(@alignCast(context.?));
    const bytes: [*]const u8 = @ptrCast(data orelse return);

    sink.list.appendSlice(sink.allocator, bytes[0..@intCast(size)]) catch {
        sink.failed = true;
    };
}

pub fn encode(
    allocator: std.mem.Allocator,
    pixels: View,
    format: image.Format,
    quality: u8,
) image.Error![]u8 {
    std.debug.assert(pixels.bytes.len == @as(usize, pixels.width) * pixels.height *
        pixels.channels);
    std.debug.assert(quality >= 1 and quality <= 100);

    if (format == .webp) {
        if (!image.webp_written) {
            return error.Encode;
        }

        return webp(allocator, pixels, quality);
    }

    return stb(allocator, pixels, format, quality);
}

fn stb(
    allocator: std.mem.Allocator,
    pixels: View,
    format: image.Format,
    quality: u8,
) image.Error![]u8 {
    std.debug.assert(format != .webp);
    std.debug.assert(pixels.channels == 3 or pixels.channels == 4);

    var sink: Sink = .{ .allocator = allocator };
    errdefer sink.list.deinit(allocator);

    const width: c_int = @intCast(pixels.width);
    const height: c_int = @intCast(pixels.height);
    const channels: c_int = @intCast(pixels.channels);
    const written = switch (format) {
        .jpeg => api.stbi_write_jpg_to_func(
            write_to_sink,
            &sink,
            width,
            height,
            channels,
            pixels.bytes.ptr,
            quality,
        ),
        else => api.stbi_write_png_to_func(
            write_to_sink,
            &sink,
            width,
            height,
            channels,
            pixels.bytes.ptr,
            width * channels,
        ),
    };

    if (sink.failed) {
        return error.OutOfMemory;
    }

    if (written == 0 or sink.list.items.len == 0) {
        return error.Encode;
    }

    return sink.list.toOwnedSlice(allocator);
}

fn webp(allocator: std.mem.Allocator, pixels: View, quality: u8) image.Error![]u8 {
    std.debug.assert(pixels.channels == 3 or pixels.channels == 4);
    std.debug.assert(pixels.width > 0 and pixels.height > 0);

    var output: [*c]u8 = null;
    const width: c_int = @intCast(pixels.width);
    const height: c_int = @intCast(pixels.height);
    const stride: c_int = width * @as(c_int, @intCast(pixels.channels));
    const factor: f32 = @floatFromInt(quality);
    const source = pixels.bytes.ptr;
    const size = if (pixels.channels == 4)
        api.WebPEncodeLosslessRGBA(source, width, height, stride, &output)
    else
        api.WebPEncodeRGB(source, width, height, stride, factor, &output);

    if (size == 0 or output == null) {
        return error.Encode;
    }

    defer api.WebPFree(output);

    return allocator.dupe(u8, output[0..size]);
}

/// A small PNG with a gradient, for the tests of everything that reads images.
pub fn sample_png(allocator: std.mem.Allocator, width: u32, height: u32) image.Error![]u8 {
    std.debug.assert(width > 0 and height > 0);
    std.debug.assert(width <= 64 and height <= 64);

    var bytes: [64 * 64 * 3]u8 = undefined;
    const len = @as(usize, width) * height * 3;

    for (bytes[0..len], 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }

    const pixels: View = .{
        .bytes = bytes[0..len],
        .width = width,
        .height = height,
        .channels = 3,
    };

    return stb(allocator, pixels, .png, image.quality_default);
}
