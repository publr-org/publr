//! The media library as data: which files it takes and how each is recognised, where a file
//! is kept (its key), the `media` type its records are of and the two taxonomies that file
//! them, folders and tags. No database.

const std = @import("std");
const content_type = @import("content_type.zig");
const files = @import("../lib/files.zig");
const image = @import("../lib/image.zig");

pub const type_handle = "media";
pub const folders_handle = "media_folders";
pub const tags_handle = "media_tags";
pub const filename_len_max: u32 = 200;
/// How deep folders nest: the explorer indents five levels.
pub const folder_depth_max: u32 = 5;
pub const random_len: u32 = 6;

/// What a file is, decided by its extension and confirmed by its first bytes where the
/// format has a signature. `family` is one of the media field's file families.
pub const Kind = struct {
    extension: []const u8,
    mime_type: []const u8,
    family: []const u8,
    /// The bytes it starts with, at `magic_at`; empty for formats without one.
    magic: []const u8 = "",
    magic_at: u32 = 0,
};

pub const kinds = [_]Kind{
    known("jpg", "image/jpeg", "image", "\xff\xd8\xff", 0),
    known("jpeg", "image/jpeg", "image", "\xff\xd8\xff", 0),
    known("png", "image/png", "image", "\x89PNG", 0),
    known("gif", "image/gif", "image", "GIF8", 0),
    known("webp", "image/webp", "image", "WEBP", 8),
    known("avif", "image/avif", "image", "ftyp", 4),
    known("svg", "image/svg+xml", "image", "", 0),
    known("ico", "image/x-icon", "image", "\x00\x00\x01\x00", 0),
    known("bmp", "image/bmp", "image", "BM", 0),
    known("mp4", "video/mp4", "video", "ftyp", 4),
    known("mov", "video/quicktime", "video", "ftyp", 4),
    known("webm", "video/webm", "video", "\x1a\x45\xdf\xa3", 0),
    known("mp3", "audio/mpeg", "audio", "", 0),
    known("wav", "audio/wav", "audio", "RIFF", 0),
    known("ogg", "audio/ogg", "audio", "OggS", 0),
    known("flac", "audio/flac", "audio", "fLaC", 0),
    known("m4a", "audio/mp4", "audio", "ftyp", 4),
    known("pdf", "application/pdf", "pdf", "%PDF-", 0),
    known("txt", "text/plain; charset=utf-8", "text", "", 0),
    known("csv", "text/csv; charset=utf-8", "spreadsheet", "", 0),
    known("zip", "application/zip", "archive", "PK\x03\x04", 0),
};

fn known(
    extension: []const u8,
    mime_type: []const u8,
    family: []const u8,
    magic: []const u8,
    magic_at: u32,
) Kind {
    std.debug.assert(extension.len > 0 and mime_type.len > 0);
    std.debug.assert(magic_at + magic.len <= 16);

    return .{
        .extension = extension,
        .mime_type = mime_type,
        .family = family,
        .magic = magic,
        .magic_at = magic_at,
    };
}

/// The kind a file name's extension names, if the library takes it.
pub fn kind_of(filename: []const u8) ?Kind {
    std.debug.assert(kinds.len > 0);

    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return null;
    const extension = filename[dot + 1 ..];

    if (extension.len == 0 or extension.len > 8) {
        return null;
    }

    for (kinds) |kind| {
        if (std.ascii.eqlIgnoreCase(kind.extension, extension)) {
            std.debug.assert(kind.mime_type.len > 0);
            return kind;
        }
    }

    return null;
}

/// Whether the bytes are what the extension says: the signature where the format has one,
/// a readable image for the formats stb reads, an `<svg` element for SVG.
pub fn matches(kind: Kind, bytes: []const u8) bool {
    std.debug.assert(kind.extension.len > 0);
    std.debug.assert(kind.magic_at + kind.magic.len <= 16);

    if (bytes.len == 0) {
        return false;
    }

    if (std.mem.eql(u8, kind.extension, "svg")) {
        const head = bytes[0..@min(bytes.len, 4096)];

        return std.mem.indexOf(u8, head, "<svg") != null;
    }

    if (kind.magic.len > 0) {
        const end = kind.magic_at + kind.magic.len;

        if (bytes.len < end or !std.mem.eql(u8, bytes[kind.magic_at..end], kind.magic)) {
            return false;
        }
    }

    if (image.processable(kind.mime_type)) {
        return image.size_of(bytes) != null;
    }

    return true;
}

/// Where an upload is kept: `YYYY/MM/<stem>-<random><.ext>`, the stem the file name's,
/// lowercased, every run of other characters a dash, at most 60 long.
pub fn key_of(
    buffer: *[files.key_len_max]u8,
    now_ms: i64,
    filename: []const u8,
    random: *const [random_len]u8,
) []const u8 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(filename.len > 0 and filename.len <= filename_len_max);

    const kind = kind_of(filename).?;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(now_ms, 1000)) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month = year_day.calculateMonthDay().month.numeric();
    var stem_buffer: [60]u8 = undefined;
    const stem = stem_of(&stem_buffer, filename);
    const key = std.fmt.bufPrint(buffer, "{d}/{d:0>2}/{s}-{s}.{s}", .{
        year_day.year, month, stem, random, kind.extension,
    }) catch unreachable;

    std.debug.assert(files.valid_key(key));

    return key;
}

fn stem_of(buffer: *[60]u8, filename: []const u8) []const u8 {
    std.debug.assert(filename.len > 0);
    std.debug.assert(buffer.len == 60);

    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
    var len: u32 = 0;
    var dashed = true;

    for (filename[0..dot]) |char| {
        if (len == buffer.len) {
            break;
        }

        if (std.ascii.isAlphanumeric(char)) {
            buffer[len] = std.ascii.toLower(char);
            len += 1;
            dashed = false;
        } else if (!dashed) {
            buffer[len] = '-';
            len += 1;
            dashed = true;
        }
    }

    while (len > 0 and buffer[len - 1] == '-') {
        len -= 1;
    }

    if (len == 0) {
        return "file";
    }

    return buffer[0..len];
}

/// What a person may name a file: one line, no path, no control characters.
pub fn valid_filename(filename: []const u8) bool {
    std.debug.assert(filename_len_max > 0);

    if (filename.len == 0 or filename.len > filename_len_max) {
        return false;
    }

    for (filename) |char| {
        if (char < 0x20 or char == 0x7f or char == '/' or char == '\\') {
            return false;
        }
    }

    return kind_of(filename) != null;
}

/// The core's type for the library's records: what people write about a file. The file's
/// own facts (name, size, dimensions) are not fields; only the library writes them.
pub const type_def: content_type.Def = .{
    .handle = type_handle,
    .name = "Media",
    .description = "Files in the media library: what each shows, and who made it.",
    .icon = "image",
    .system = true,
    .owner = "publr",
    .title_field = "title",
    .fields = &.{
        .{ .name = "title", .label = "Title", .kind = "string", .required = true },
        .{ .name = "alt", .label = "Alt text", .kind = "string" },
        .{ .name = "caption", .label = "Caption", .kind = "text" },
        .{ .name = "credit", .label = "Credit", .kind = "string" },
        .{ .name = "focal_x", .label = "Focal point across", .kind = "integer" },
        .{ .name = "focal_y", .label = "Focal point down", .kind = "integer" },
    },
};

pub const folders_definition =
    \\{"handle":"media_folders","name":"Media folders","hierarchical":true,"single":true,
    \\ "system":true,"applies_to":["media"],"title_field":"name",
    \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
    \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
;

pub const tags_definition =
    \\{"handle":"media_tags","name":"Media tags","system":true,"applies_to":["media"],
    \\ "title_field":"name",
    \\ "fields":[{"name":"name","label":"Name","kind":"string","required":true},
    \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
;

/// Whether a content type is the library's: its records are files, kept out of Content.
/// Where a file put into the media folder by hand belongs: its name, and the library
/// folders its directories name, outermost first and no deeper than folders nest. A top
/// directory of four digits is the library's own dated layout and names no folder.
pub const Placed = struct { filename: []const u8, folders: []const []const u8 };

pub fn placed_of(buffer: *[folder_depth_max][]const u8, path: []const u8) Placed {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[path.len - 1] != '/');

    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return .{ .filename = path, .folders = &.{} };
    var directories = std.mem.splitScalar(u8, path[0..slash], '/');
    var count: u32 = 0;
    const first = directories.first();
    const dated = first.len == 4 and for (first) |char| {
        if (!std.ascii.isDigit(char)) {
            break false;
        }
    } else true;

    if (!dated) {
        directories.reset();

        while (directories.next()) |directory| {
            if (count == folder_depth_max) {
                break;
            }

            if (directory.len > 0) {
                buffer[count] = directory;
                count += 1;
            }
        }
    }

    return .{ .filename = path[slash + 1 ..], .folders = buffer[0..count] };
}

pub fn is_library(handle: []const u8) bool {
    const library = std.mem.eql(u8, handle, type_handle);

    std.debug.assert(!library or handle.len == type_handle.len);

    return library;
}

test "placed_of: directories name folders, the dated layout none" {
    var buffer: [folder_depth_max][]const u8 = undefined;
    const trip = placed_of(&buffer, "Photos/Trips/Beach Day.JPG");

    try std.testing.expectEqualStrings("Beach Day.JPG", trip.filename);
    try std.testing.expectEqual(@as(usize, 2), trip.folders.len);
    try std.testing.expectEqualStrings("Trips", trip.folders[1]);
    try std.testing.expectEqual(@as(usize, 0), placed_of(&buffer, "2026/10/cat.jpg").folders.len);
    try std.testing.expectEqual(@as(usize, 0), placed_of(&buffer, "cat.jpg").folders.len);
    try std.testing.expectEqual(
        @as(usize, folder_depth_max),
        placed_of(&buffer, "a/b/c/d/e/f/g/cat.jpg").folders.len,
    );
}

test "kind_of: by extension, any case; unknown and missing ones refused" {
    try std.testing.expectEqualStrings("image/jpeg", kind_of("Cat.JPG").?.mime_type);
    try std.testing.expectEqualStrings("application/pdf", kind_of("a.b.pdf").?.mime_type);
    try std.testing.expect(kind_of("script.exe") == null);
    try std.testing.expect(kind_of("README") == null);
    try std.testing.expect(kind_of("dot.") == null);
}

test "matches: signatures, readable images, SVG markup" {
    try std.testing.expect(matches(kind_of("a.pdf").?, "%PDF-1.7 rest"));
    try std.testing.expect(!matches(kind_of("a.pdf").?, "<html>"));
    try std.testing.expect(!matches(kind_of("a.jpg").?, "\xff\xd8\xff not really"));
    try std.testing.expect(matches(kind_of("a.svg").?, "<?xml version=\"1.0\"?><svg></svg>"));
    try std.testing.expect(!matches(kind_of("a.svg").?, "<html></html>"));
    try std.testing.expect(matches(kind_of("a.txt").?, "hello"));
    try std.testing.expect(!matches(kind_of("a.txt").?, ""));
}

test "key_of: dated, slugged, random, keeps the extension" {
    var buffer: [files.key_len_max]u8 = undefined;
    const random = "a1b2c3";
    // 2026-10-06
    const now_ms: i64 = 1_791_244_800_000;

    try std.testing.expectEqualStrings(
        "2026/10/summer-in-krakow-a1b2c3.jpg",
        key_of(&buffer, now_ms, "Summer in  KRAKOW!.JPG", random),
    );
    try std.testing.expectEqualStrings(
        "2026/10/file-a1b2c3.png",
        key_of(&buffer, now_ms, "---.png", random),
    );
}

test "valid_filename: one line, a known extension, no path" {
    try std.testing.expect(valid_filename("holiday photo.jpg"));
    try std.testing.expect(!valid_filename("../etc/passwd.txt"));
    try std.testing.expect(!valid_filename("a\nb.jpg"));
    try std.testing.expect(!valid_filename("tool.exe"));
    try std.testing.expect(!valid_filename(""));
}
