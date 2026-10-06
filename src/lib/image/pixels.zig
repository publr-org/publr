//! A decoded image: RGB, or RGBA when the source has transparency, cropped and resized in
//! place of itself.

const std = @import("std");
const api = @import("api.zig").api;
const image = @import("../image.zig");

const Pixels = @This();

/// What stb decoded, freed with `stbi_image_free`; the buffer `owned` replaces it after a
/// crop or a resize.
decoded: [*]u8,
owned: ?[]u8 = null,
width: u32,
height: u32,
channels: u32,

pub const View = struct { bytes: []const u8, width: u32, height: u32, channels: u32 };

pub fn decode(source: []const u8) image.Error!Pixels {
    std.debug.assert(source.len > 0);
    std.debug.assert(source.len <= std.math.maxInt(c_int));

    var width: c_int = 0;
    var height: c_int = 0;
    var found: c_int = 0;
    const length: c_int = @intCast(source.len);

    if (api.stbi_info_from_memory(source.ptr, length, &width, &height, &found) == 0) {
        return error.Decode;
    }

    // Grey and grey-alpha are widened, so every buffer is RGB or RGBA.
    const wanted: c_int = if (@mod(found, 2) == 0) 4 else 3;
    const decoded = api.stbi_load_from_memory(source.ptr, length, &width, &height, &found, wanted);
    const pixels = decoded orelse return error.Decode;

    std.debug.assert(width > 0 and height > 0);

    return .{
        .decoded = pixels,
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = @intCast(wanted),
    };
}

pub fn deinit(pixels: *Pixels, allocator: std.mem.Allocator) void {
    std.debug.assert(pixels.channels == 3 or pixels.channels == 4);

    if (pixels.owned) |owned| {
        allocator.free(owned);
    }

    api.stbi_image_free(pixels.decoded);
    pixels.* = undefined;
}

pub fn view(pixels: *const Pixels) View {
    const len = @as(usize, pixels.width) * pixels.height * pixels.channels;

    std.debug.assert(len > 0);

    const bytes = if (pixels.owned) |owned| owned else pixels.decoded[0..len];

    std.debug.assert(bytes.len == len);

    return .{
        .bytes = bytes,
        .width = pixels.width,
        .height = pixels.height,
        .channels = pixels.channels,
    };
}

/// Crop, cover or resize as `params` ask; never past the image's own size.
pub fn apply(pixels: *Pixels, allocator: std.mem.Allocator, params: image.Params) image.Error!void {
    std.debug.assert(pixels.width > 0 and pixels.height > 0);
    std.debug.assert(params.focal_x <= 100 and params.focal_y <= 100);

    const focal: Focal = .{ .x_percent = params.focal_x, .y_percent = params.focal_y };

    if (params.width != null and params.height != null) {
        const width = @max(params.width.?, 1);
        const height = @max(params.height.?, 1);

        if (params.fit == .cover) {
            const scale = @max(ratio(width, pixels.width), ratio(height, pixels.height));

            try pixels.scale_by(allocator, @min(scale, 1.0));
        }

        try pixels.crop(allocator, @min(width, pixels.width), @min(height, pixels.height), focal);

        return;
    }

    if (params.width) |width| {
        if (width > 0 and width < pixels.width) {
            const height = @max(1, @as(u64, pixels.height) * width / pixels.width);

            try pixels.resize(allocator, width, @intCast(height));
        }
    } else if (params.height) |height| {
        if (height > 0 and height < pixels.height) {
            const width = @max(1, @as(u64, pixels.width) * height / pixels.height);

            try pixels.resize(allocator, @intCast(width), height);
        }
    }
}

fn ratio(target: u32, actual: u32) f64 {
    std.debug.assert(actual > 0);
    std.debug.assert(target > 0);

    return @as(f64, @floatFromInt(target)) / @as(f64, @floatFromInt(actual));
}

fn scale_by(pixels: *Pixels, allocator: std.mem.Allocator, scale: f64) image.Error!void {
    std.debug.assert(scale > 0 and scale <= 1.0);
    std.debug.assert(pixels.width > 0 and pixels.height > 0);

    const width: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(pixels.width)) *
        scale)));
    const height: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(pixels.height)) *
        scale)));

    if (width != pixels.width or height != pixels.height) {
        try pixels.resize(allocator, width, height);
    }
}

fn resize(pixels: *Pixels, allocator: std.mem.Allocator, width: u32, height: u32) image.Error!void {
    std.debug.assert(width > 0 and width <= pixels.width);
    std.debug.assert(height > 0 and height <= pixels.height);

    const source = pixels.view();
    const out = try allocator.alloc(u8, @as(usize, width) * height * pixels.channels);
    errdefer allocator.free(out);

    const layout: api.stbir_pixel_layout = if (pixels.channels == 4)
        api.STBIR_RGBA
    else
        api.STBIR_RGB;
    const resized = api.stbir_resize_uint8_linear(
        source.bytes.ptr,
        @intCast(source.width),
        @intCast(source.height),
        0,
        out.ptr,
        @intCast(width),
        @intCast(height),
        0,
        layout,
    );

    if (resized == null) {
        return error.Resize;
    }

    pixels.replace(allocator, out, width, height);
}

pub const Focal = struct { x_percent: u8, y_percent: u8 };

/// Cut `width` × `height` with the focal point as near the middle as the edges allow.
pub fn crop(
    pixels: *Pixels,
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    focal: Focal,
) image.Error!void {
    std.debug.assert(width > 0 and width <= pixels.width);
    std.debug.assert(height > 0 and height <= pixels.height);

    if (width == pixels.width and height == pixels.height) {
        return;
    }

    const left = origin(pixels.width, width, focal.x_percent);
    const top = origin(pixels.height, height, focal.y_percent);
    const source = pixels.view();
    const source_stride = @as(usize, source.width) * source.channels;
    const stride = @as(usize, width) * source.channels;
    const out = try allocator.alloc(u8, stride * height);

    for (0..height) |row| {
        const from = (top + row) * source_stride + @as(usize, left) * source.channels;

        @memcpy(out[row * stride ..][0..stride], source.bytes[from..][0..stride]);
    }

    pixels.replace(allocator, out, width, height);
}

fn origin(whole: u32, part: u32, percent: u8) u32 {
    std.debug.assert(part <= whole);
    std.debug.assert(percent <= 100);

    const centre = @divTrunc(@as(i64, whole) * percent, 100);
    const ideal = centre - @as(i64, part / 2);
    const clamped = std.math.clamp(ideal, 0, @as(i64, whole - part));

    return @intCast(clamped);
}

fn replace(pixels: *Pixels, allocator: std.mem.Allocator, out: []u8, width: u32, height: u32) void {
    std.debug.assert(out.len == @as(usize, width) * height * pixels.channels);
    std.debug.assert(width > 0 and height > 0);

    if (pixels.owned) |owned| {
        allocator.free(owned);
    }

    pixels.owned = out;
    pixels.width = width;
    pixels.height = height;
}

test "origin: centred on the focal point, held inside the edges" {
    try std.testing.expectEqual(@as(u32, 1), origin(4, 2, 50));
    try std.testing.expectEqual(@as(u32, 0), origin(10, 4, 0));
    try std.testing.expectEqual(@as(u32, 6), origin(10, 4, 100));
    try std.testing.expectEqual(@as(u32, 0), origin(4, 4, 30));
}
