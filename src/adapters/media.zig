//! `/media/<key>`: a library file, as uploaded or resized. `?w=` and `?h=` resize (never
//! larger), with both `?fit=cover` scales before it crops (else it crops at full size)
//! around the focal point (`?fp=x,y`, else the file's own), `?q=` sets the quality; a
//! browser that takes WebP gets WebP. Copies are cached beside the originals where the
//! files are on disk. A public file is cached by browsers for good (its key never names
//! other bytes); a private one only reaches signed-in users and is never stored.

const std = @import("std");
const http = @import("../lib/http.zig");
const files_module = @import("../lib/files.zig");
const image = @import("../lib/image.zig");
const Project = @import("../server/project.zig").Project;
const identity = @import("rest/identity.zig");
const registry = @import("../server/registry.zig");
const media = @import("../operations/media.zig");
const ranges = @import("apps/media.zig");

pub const prefix = "/media/";
pub const routes_count: u32 = 1;
pub const upload_path = "/media/upload";
const side_requested_max: u32 = 4096;
const file_allocator = media.library.file_allocator;

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < 256 - routes_count);

    const before = router.routes_len;

    router.get(prefix ++ "*", &serve);
    router.stream(.post, upload_path, &upload.stream);

    std.debug.assert(router.routes_len == before + routes_count);
}

pub const upload = @import("media/upload.zig");

fn serve(request: *http.Request, response: *http.Response, ctx: *http.Context) anyerror!void {
    std.debug.assert(std.mem.startsWith(u8, request.path(), prefix));
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const key = request.path()[prefix.len..];

    if (!files_module.valid_key(key)) {
        return response.text(.not_found, "Not Found");
    }

    const files = project.files orelse return response.text(.service_unavailable, "No files");
    const who = identity.identify(request, ctx.arena, project);
    var sdk_ctx = identity.context(project, ctx.arena, who.caller);
    const facts = registry.SDK.dispatch(&sdk_ctx, media.File, .{ .key = key }) catch |err| {
        return switch (err) {
            error.NotFound, error.Invalid => response.text(.not_found, "Not Found"),
            else => err,
        };
    };
    const asked = params_of(ctx.arena, request.query(), facts) catch {
        return response.text(.bad_request, "Bad size");
    };
    const resized = asked != null and image.processable(facts.mime_type);
    const format = image.negotiate(request.header("accept"), facts.mime_type);
    var suffix_buffer: [image.suffix_len_max]u8 = undefined;
    const suffix = if (resized)
        image.cache_suffix(&suffix_buffer, asked.?, format, facts.mime_type)
    else
        "";
    const etag = try std.fmt.allocPrint(ctx.arena, "\"{s}{s}\"", .{ facts.hash, suffix });

    try headers(response, facts.private, etag, resized);

    // A file opened on its own must not run what it carries: an SVG's script, a text file
    // a browser takes for a page. A PDF keeps its viewer, which a sandbox would block.
    if (!std.mem.eql(u8, facts.mime_type, "application/pdf")) {
        try response.set_header(
            "Content-Security-Policy",
            "default-src 'none'; img-src 'self' data:; media-src 'self'; " ++
                "style-src 'unsafe-inline'; sandbox",
        );
    }

    if (matches_etag(request.header("if-none-match"), etag)) {
        return response.set_body(.not_modified, facts.mime_type, "");
    }

    if (!resized) {
        if (request.header("range")) |range| {
            return ranged(response, ctx, files, key, facts, range);
        }

        return original(response, ctx, files, key, facts.mime_type);
    }

    var params = asked.?;

    params.format = format;

    const bytes = copy(ctx.arena, files, key, params, suffix) catch |err| {
        return switch (err) {
            error.Needed, error.Storage => response.text(.service_unavailable, "Unavailable"),
            error.NotFound => response.text(.not_found, "Not Found"),
            error.TooLarge => response.text(.payload_too_large, "Too large to resize"),
            else => response.text(.unprocessable_content, "Not an image this can resize"),
        };
    };

    try response.set_body(.ok, format.mime_type(), bytes);
}

fn headers(response: *http.Response, private: bool, etag: []const u8, resized: bool) !void {
    std.debug.assert(etag.len > 2);
    std.debug.assert(!resized or etag.len > 66);

    const cache = if (private) "private, no-store" else "public, max-age=31536000, immutable";

    try response.set_header("Cache-Control", cache);
    try response.set_header("ETag", etag);
    try response.set_header("Vary", "Accept");
    try response.set_header("Accept-Ranges", "bytes");
}

fn matches_etag(header: ?[]const u8, etag: []const u8) bool {
    std.debug.assert(etag.len > 2);

    const sent = header orelse return false;

    std.debug.assert(sent.len <= 8 << 10);

    var tags = std.mem.splitScalar(u8, sent, ',');

    while (tags.next()) |tag| {
        const trimmed = std.mem.trim(u8, tag, " ");
        const weak = std.mem.cutPrefix(u8, trimmed, "W/") orelse trimmed;

        if (std.mem.eql(u8, weak, etag) or std.mem.eql(u8, trimmed, "*")) {
            return true;
        }
    }

    return false;
}

/// The file as uploaded, when it fits one response.
fn original(
    response: *http.Response,
    ctx: *http.Context,
    files: files_module.Files,
    key: []const u8,
    mime_type: []const u8,
) !void {
    std.debug.assert(files_module.valid_key(key));
    std.debug.assert(mime_type.len > 0);

    const room = ctx.options.response_bytes_max - 4096;
    const limit: u32 = @min(room, files_module.bytes_max);
    const bytes = files.read(ctx.arena, .files, key, limit) catch |err| {
        return switch (err) {
            error.Needed, error.Storage => response.text(.service_unavailable, "Unavailable"),
            error.TooLarge => response.text(.payload_too_large, "Too large to serve whole"),
            else => response.text(.not_found, "Not Found"),
        };
    };

    try response.set_body(.ok, mime_type, bytes);
}

/// The part of the file a `Range` asks for, at most a response's worth: how a browser plays
/// a video, and how any file larger than one response is read.
fn ranged(
    response: *http.Response,
    ctx: *http.Context,
    files: files_module.Files,
    key: []const u8,
    facts: media.File.Out,
    header: []const u8,
) !void {
    std.debug.assert(files_module.valid_key(key));
    std.debug.assert(header.len <= 8 << 10);

    const room = ctx.options.response_bytes_max - 4096;
    const selected = ranges.parse_range(header, facts.size, room) orelse {
        const value = try std.fmt.allocPrint(ctx.arena, "bytes */{d}", .{facts.size});

        try response.set_header("Content-Range", value);
        return response.text(.range_not_satisfiable, "Range Not Satisfiable");
    };
    const buffer = try ctx.arena.alloc(u8, @intCast(selected.end - selected.start + 1));
    const bytes = files.read_range(.files, key, selected.start, buffer) catch |err| {
        return switch (err) {
            error.Needed, error.Storage => response.text(.service_unavailable, "Unavailable"),
            else => response.text(.not_found, "Not Found"),
        };
    };
    const value = try std.fmt.allocPrint(ctx.arena, "bytes {d}-{d}/{d}", .{
        selected.start, selected.start + bytes.len -| 1, facts.size,
    });

    try response.set_header("Content-Range", value);
    try response.set_body(.partial_content, facts.mime_type, bytes);
}

/// The resized copy: from the cache when it was made before, else made from the original
/// and cached. The bytes are the request's.
fn copy(
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

    const source = try files.read(file_allocator, .files, key, files_module.bytes_max);
    defer file_allocator.free(source);

    const processed = try image.process(file_allocator, source, params);
    defer file_allocator.free(processed.bytes);

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

/// What the query asks of the image; null when it asks for the file as it is.
fn params_of(
    arena: std.mem.Allocator,
    query: []const u8,
    facts: media.File.Out,
) !?image.Params {
    std.debug.assert(query.len <= 64 << 10);
    std.debug.assert(facts.focal_x <= 100 and facts.focal_y <= 100);

    const width = try side_of(http.Form.query_param(arena, query, "w"));
    const height = try side_of(http.Form.query_param(arena, query, "h"));
    const quality = http.Form.query_param(arena, query, "q");

    if (width == null and height == null and quality == null) {
        return null;
    }

    var params: image.Params = .{
        .width = width,
        .height = height,
        .focal_x = facts.focal_x,
        .focal_y = facts.focal_y,
    };

    if (quality) |text| {
        params.quality = std.fmt.parseInt(u8, text, 10) catch return error.Invalid;

        if (params.quality < 1 or params.quality > 100) {
            return error.Invalid;
        }
    }

    if (http.Form.query_param(arena, query, "fit")) |fit| {
        params.fit = std.meta.stringToEnum(image.Fit, fit) orelse return error.Invalid;
    }

    if (http.Form.query_param(arena, query, "fp")) |focal| {
        try focal_of(focal, &params);
    }

    return params;
}

fn side_of(text: ?[]const u8) !?u32 {
    std.debug.assert(side_requested_max > 0);

    const given = text orelse return null;
    const side = std.fmt.parseInt(u32, given, 10) catch return error.Invalid;

    if (side == 0 or side > side_requested_max) {
        return error.Invalid;
    }

    return side;
}

fn focal_of(text: []const u8, params: *image.Params) !void {
    std.debug.assert(text.len > 0);
    std.debug.assert(params.quality > 0);

    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return error.Invalid;
    const across = std.fmt.parseInt(u8, text[0..comma], 10) catch return error.Invalid;
    const down = std.fmt.parseInt(u8, text[comma + 1 ..], 10) catch return error.Invalid;

    if (across > 100 or down > 100) {
        return error.Invalid;
    }

    params.focal_x = across;
    params.focal_y = down;
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

test "matches_etag: exact, weak, listed, any" {
    try std.testing.expect(matches_etag("\"abc\"", "\"abc\""));
    try std.testing.expect(matches_etag("W/\"abc\"", "\"abc\""));
    try std.testing.expect(matches_etag("\"x\", \"abc\"", "\"abc\""));
    try std.testing.expect(matches_etag("*", "\"abc\""));
    try std.testing.expect(!matches_etag("\"abd\"", "\"abc\""));
    try std.testing.expect(!matches_etag(null, "\"abc\""));
}

test "side_of and focal_of: bounded numbers only" {
    var params: image.Params = .{};

    try std.testing.expectEqual(@as(?u32, 400), try side_of("400"));
    try std.testing.expectEqual(@as(?u32, null), try side_of(null));
    try std.testing.expectError(error.Invalid, side_of("0"));
    try std.testing.expectError(error.Invalid, side_of("99999"));
    try std.testing.expectError(error.Invalid, side_of("-1"));
    try focal_of("30,70", &params);
    try std.testing.expectEqual(@as(u8, 70), params.focal_y);
    try std.testing.expectError(error.Invalid, focal_of("30", &params));
    try std.testing.expectError(error.Invalid, focal_of("101,0", &params));
}
