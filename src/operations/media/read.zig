//! `media.read`: a file's bytes as the caller may read them, of any media type, private
//! ones included; how an agent or a command looks at a picture without the site serving
//! it to anyone. Resized copies are made and cached as `/media/<key>` makes them.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/media/read.zig");
const store = @import("../../store.zig");
const files_module = @import("../../lib/files.zig");
const image = @import("../../lib/image.zig");
const library = @import("library.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const read_bytes_max = public.read_bytes_max;
pub const side_max = public.side_max;

pub const operations = [_]type{Read};

pub const Read = struct {
    pub const shape = public.Read;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (!files_module.valid_key(in.key) or ctx.caller == .anonymous) {
            return error.NotFound;
        }

        const row = try store.media.by_key(ctx.db, ctx.arena, in.key) orelse return error.NotFound;

        if (row.private and library.public_only(granted)) {
            return error.NotFound;
        }

        const handle = try store.media.type_of(ctx.db, ctx.arena, row.record) orelse {
            return error.NotFound;
        };

        // A type the caller may not read hides its files as it hides its records.
        _ = try library.media_type_for(ctx, granted, handle);

        const files = try library.files_of(ctx);
        const params = try params_of(ctx, in, row.record);
        const resized = params != null and image.processable(row.mime_type);
        const bytes, const mime_type = if (resized) converted: {
            var asked = params.?;
            const format = asked.format orelse source_format(row.mime_type);

            asked.format = format;

            var suffix_buffer: [image.suffix_len_max]u8 = undefined;
            const suffix = image.cache_suffix(&suffix_buffer, asked, format, row.mime_type);
            const made = copy(ctx.arena, files, in.key, asked, suffix) catch |err| {
                return failed(ctx, err);
            };

            break :converted .{ made, format.mime_type() };
        } else whole: {
            const read = files.read(ctx.arena, .files, in.key, read_bytes_max) catch |err| {
                return library.fail(err);
            };

            break :whole .{ read, row.mime_type };
        };

        if (bytes.len > read_bytes_max) {
            return ctx.fail(too_large);
        }

        const encoder = std.base64.standard.Encoder;
        const data = try ctx.arena.alloc(u8, encoder.calcSize(bytes.len));

        _ = encoder.encode(data, bytes);

        return .{
            .mime_type = mime_type,
            .size = bytes.len,
            .data = data,
        };
    }
};

const too_large: sdk.operation.Failure = .{
    .name = "TooLarge",
    .status = 413,
    .message = "Larger than one answer carries (8 MiB): ask for it smaller with `width`",
};

const not_resizable: sdk.operation.Failure = .{
    .name = "NotResizable",
    .status = 422,
    .message = "Not an image this can resize",
};

fn failed(ctx: *Ctx, err: (files_module.Error || image.Error)) Error {
    std.debug.assert(@intFromError(err) != 0);

    return switch (err) {
        error.TooLarge => ctx.fail(too_large),
        error.NotFound => error.NotFound,
        error.Needed, error.Storage => error.Unavailable,
        error.OutOfMemory => error.OutOfMemory,
        else => ctx.fail(not_resizable),
    };
}

fn source_format(mime_type: []const u8) image.Format {
    std.debug.assert(image.processable(mime_type));

    return if (std.mem.eql(u8, mime_type, "image/png")) .png else .jpeg;
}

/// What the call asks of the image, around the file's focal point; null for the file as
/// it is.
fn params_of(ctx: *Ctx, in: Read.In, record_id: []const u8) Error!?image.Params {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(side_max > 0);

    const asked = in.width != null or in.height != null or in.quality != null or
        in.format.len > 0 or in.fit.len > 0;

    if (!asked) {
        return null;
    }

    for ([_]?u32{ in.width, in.height }) |side| {
        if (side) |given| {
            if (given == 0 or given > side_max) {
                return error.Invalid;
            }
        }
    }

    const focal = try store.media.focal(ctx.db, ctx.arena, record_id);
    var params: image.Params = .{
        .width = in.width,
        .height = in.height,
        .focal_x = @intCast(std.math.clamp(focal.across orelse 50, 0, 100)),
        .focal_y = @intCast(std.math.clamp(focal.down orelse 50, 0, 100)),
    };

    if (in.quality) |quality| {
        if (quality < 1 or quality > 100) {
            return error.Invalid;
        }

        params.quality = quality;
    }

    if (in.fit.len > 0) {
        params.fit = std.meta.stringToEnum(image.Fit, in.fit) orelse return error.Invalid;
    }

    if (in.format.len > 0) {
        const format = std.meta.stringToEnum(image.Format, in.format) orelse {
            return error.Invalid;
        };

        if (format == .webp and !image.webp_written) {
            return error.Invalid;
        }

        params.format = format;
    }

    return params;
}

/// The resized copy: from the cache when it was made before, else made from the original
/// and cached. The bytes are the arena's.
pub fn copy(
    arena: std.mem.Allocator,
    files: files_module.Files,
    key: []const u8,
    params: image.Params,
    suffix: []const u8,
) (files_module.Error || image.Error)![]const u8 {
    std.debug.assert(suffix.len > 0);
    std.debug.assert(files_module.valid_key(key));

    const name = try cache_key(arena, key, suffix);

    if (files.read(arena, .cache, name, files_module.bytes_max)) |cached| {
        return cached;
    } else |err| switch (err) {
        error.NotFound => {},
        else => return err,
    }

    const source = try files.read(library.file_allocator, .files, key, files_module.bytes_max);
    defer library.file_allocator.free(source);

    const processed = try image.process(library.file_allocator, source, params);
    defer library.file_allocator.free(processed.bytes);

    files.write(.cache, name, processed.bytes) catch |err| {
        std.log.warn("media: could not cache {s}: {t}", .{ name, err });
    };

    return arena.dupe(u8, processed.bytes);
}

/// `2026/10/cat-a1b2c3.jpg` resized to `_w400` is cached as `2026/10/cat-a1b2c3_w400.jpg`;
/// a WebP copy's suffix carries its own extension.
fn cache_key(arena: std.mem.Allocator, key: []const u8, suffix: []const u8) ![]const u8 {
    std.debug.assert(suffix.len > 0);
    std.debug.assert(files_module.valid_key(key));

    const dot = std.mem.lastIndexOfScalar(u8, key, '.') orelse key.len;
    const converted = std.mem.indexOfScalar(u8, suffix, '.') != null;
    const extension = if (converted) "" else key[dot..];
    const name = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ key[0..dot], suffix, extension });

    if (!files_module.valid_key(name)) {
        return error.InvalidKey;
    }

    return name;
}

test "cache_key: the stem, the suffix, the extension unless the suffix converts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "2026/10/cat-a1_w400.jpg",
        try cache_key(arena, "2026/10/cat-a1.jpg", "_w400"),
    );
    try std.testing.expectEqualStrings(
        "2026/10/cat-a1_w400.webp",
        try cache_key(arena, "2026/10/cat-a1.jpg", "_w400.webp"),
    );
}

test "media types: kept apart, private, read only as a caller may" {
    const registry = @import("../../server/registry.zig");
    const media_operations = @import("../media.zig");
    const encode = @import("../../lib/image/encode.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var disk = try files_module.Disk.open(std.testing.io, root);
    defer disk.close();

    var system = harness.ctx(.system);
    system.files = .{
        .disk = &disk,
    };
    try registry.SDK.bootstrap(&system);

    const png = try encode.sample_png(std.testing.allocator, 8, 4);
    defer std.testing.allocator.free(png);

    try system.files.?.write(.incoming, "upload0001", png);

    const pasted = try registry.SDK.dispatch(&system, media_operations.Upload, .{
        .upload = "upload0001",
        .filename = "Pasted.png",
        .type = "ai_picture",
    });

    try std.testing.expect(std.mem.startsWith(u8, pasted.key, "ai_picture/"));
    try std.testing.expect(pasted.private);
    try system.files.?.write(.incoming, "upload0002", "plain words");
    try std.testing.expectError(error.Failed, registry.SDK.dispatch(
        &system,
        media_operations.Upload,
        .{
            .upload = "upload0002",
            .filename = "notes.txt",
            .type = "ai_picture",
        },
    ));
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(
        &system,
        media_operations.Upload,
        .{
            .upload = "upload0002",
            .filename = "notes.txt",
            .type = "nothing_here",
        },
    ));

    const library_files = try registry.SDK.dispatch(&system, media_operations.List, .{});
    const pictures = try registry.SDK.dispatch(&system, media_operations.List, .{
        .type = "ai_picture",
    });

    try std.testing.expectEqual(@as(u32, 0), library_files.total);
    try std.testing.expectEqual(@as(u32, 1), pictures.total);
    try std.testing.expectEqual(@as(usize, 0), pictures.folders.len);
    try std.testing.expectError(error.Failed, registry.SDK.dispatch(
        &system,
        media_operations.Update,
        .{
            .id = pasted.id,
            .private = false,
        },
    ));

    const whole = try registry.SDK.dispatch(&system, Read, .{
        .key = pasted.key,
    });
    const smaller = try registry.SDK.dispatch(&system, Read, .{
        .key = pasted.key,
        .width = 4,
        .format = "png",
    });

    try std.testing.expectEqualStrings("image/png", whole.mime_type);
    try std.testing.expectEqual(@as(u64, png.len), whole.size);
    try std.testing.expect(smaller.size > 0 and smaller.data.len > 0);
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&system, Read, .{
        .key = "ai_picture/2026/10/gone-a1b2c3.png",
    }));
    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&system, Read, .{
        .key = pasted.key,
        .width = 0,
    }));

    var visitor = harness.ctx(.anonymous);
    visitor.files = system.files;

    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(
        &visitor,
        media_operations.File,
        .{
            .key = pasted.key,
        },
    ));
}
