//! How a field is shown and edited: its control, its choices, what it points at, a date's
//! shape. Rules a value must meet are its `validation`, never here. Every part has a
//! default, so a field carries only what was set.
const std = @import("std");

pub const message_len_max: u32 = 255;
pub const media_types_max: u32 = 16;
pub const list_max: u32 = 64;
pub const label_len_max: u32 = 64;
pub const pattern_len_max: u32 = 255;
pub const decimals_max: u32 = 10;
pub const dimension_max: u32 = 100_000;

const public = @import("../../publr/field_options.zig");

pub const DateFormat = public.DateFormat;
pub const Date = public.Date;
pub const TextFormat = public.TextFormat;
pub const Text = public.Text;
pub const RichFormat = public.RichFormat;
pub const RichText = public.RichText;
pub const Slug = public.Slug;
pub const Email = public.Email;
pub const BooleanControl = public.BooleanControl;
pub const Boolean = public.Boolean;
pub const NumberControl = public.NumberControl;
pub const Number = public.Number;
pub const SelectControl = public.SelectControl;
pub const Select = public.Select;
pub const OnDelete = public.OnDelete;
pub const Reference = public.Reference;
pub const Container = public.Container;
pub const Provider = public.Provider;
pub const Media = public.Media;
pub const Options = public.Options;

pub const MediaType = struct {
    id: []const u8,
    label: []const u8,
};

/// The file families a media field can be limited to; a file's family is decided by its
/// mime type when it is uploaded.
pub const media_types = [_]MediaType{
    .{
        .id = "image",
        .label = "Image",
    },
    .{
        .id = "video",
        .label = "Video",
    },
    .{
        .id = "audio",
        .label = "Audio",
    },
    .{
        .id = "pdf",
        .label = "PDF document",
    },
    .{
        .id = "document",
        .label = "Document",
    },
    .{
        .id = "spreadsheet",
        .label = "Spreadsheet",
    },
    .{
        .id = "presentation",
        .label = "Presentation",
    },
    .{
        .id = "text",
        .label = "Plain text",
    },
    .{
        .id = "code",
        .label = "Code",
    },
    .{
        .id = "archive",
        .label = "Archive",
    },
    .{
        .id = "font",
        .label = "Font",
    },
};

/// The schemes a url field can be limited to; the first two are what an empty list means.
pub const url_schemes = [_][]const u8{ "http", "https", "mailto", "tel" };

pub fn valid_media_type(id: []const u8) bool {
    std.debug.assert(media_types.len <= media_types_max);
    std.debug.assert(media_types.len > 0);

    for (media_types) |known| {
        if (std.mem.eql(u8, known.id, id)) {
            return true;
        }
    }

    return false;
}

pub fn valid_scheme(id: []const u8) bool {
    std.debug.assert(url_schemes.len > 0);
    std.debug.assert(url_schemes.len <= list_max);

    for (url_schemes) |known| {
        if (std.mem.eql(u8, known, id)) {
            return true;
        }
    }

    return false;
}

/// Whether a scheme is accepted by the field: http and https when none is listed.
pub fn scheme_allowed(url: @import("validation.zig").Url, scheme: []const u8) bool {
    std.debug.assert(url.schemes.len <= list_max);
    std.debug.assert(url_schemes.len >= 2);

    if (url.schemes.len == 0) {
        return std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https");
    }

    return contains(url.schemes, scheme);
}

pub fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(list.len <= 256);
    std.debug.assert(item.len <= 64 << 10);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

/// Whether a lower and an upper bound, each optional, can both hold.
pub fn ordered(comptime Bound: type, low: ?Bound, high: ?Bound) bool {
    std.debug.assert(@typeInfo(Bound) == .int or @typeInfo(Bound) == .float);
    std.debug.assert(dimension_max > 0);

    if (low == null or high == null) {
        return true;
    }

    return low.? <= high.?;
}

test "media types, schemes and bounds" {
    try std.testing.expect(valid_media_type("image"));
    try std.testing.expect(valid_media_type("archive"));
    try std.testing.expect(valid_media_type("font"));
    try std.testing.expect(!valid_media_type("typeface"));
    try std.testing.expect(!valid_media_type(""));

    try std.testing.expect(valid_scheme("mailto"));
    try std.testing.expect(!valid_scheme("ftp"));
    try std.testing.expect(scheme_allowed(.{}, "https"));
    try std.testing.expect(!scheme_allowed(.{}, "mailto"));
    try std.testing.expect(scheme_allowed(.{
        .schemes = &.{"mailto"},
    }, "mailto"));
    try std.testing.expect(!scheme_allowed(.{
        .schemes = &.{"mailto"},
    }, "https"));

    try std.testing.expect(ordered(u32, null, null));
    try std.testing.expect(ordered(u32, 1, null));
    try std.testing.expect(ordered(u32, 1, 1));
    try std.testing.expect(!ordered(u32, 2, 1));
    try std.testing.expect(ordered(f64, -1.5, 0));
    try std.testing.expect(!ordered(f64, 0.5, 0));

    const options: Options = .{};
    try std.testing.expectEqual(DateFormat.datetime, options.date.format);
    try std.testing.expect(options.media.create and options.media.link);
    try std.testing.expect(options.reference.create and options.reference.link);
    try std.testing.expectEqual(OnDelete.keep, options.reference.on_delete);
}

test "options are written sparsely and read back whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare: Options = .{};
    const nothing = try std.json.Stringify.valueAlloc(arena, bare, .{});
    try std.testing.expectEqualStrings("{}", nothing);

    const set: Options = .{
        .step = 2,
        .reference = .{
            .on_delete = .clear,
        },
        .media = .{
            .link = false,
        },
        .richtext = .{
            .formats = &.{.bold},
        },
    };
    const text = try std.json.Stringify.valueAlloc(arena, set, .{});
    const expected = "{\"step\":2,\"richtext\":{\"formats\":[\"bold\"]}," ++
        "\"reference\":{\"on_delete\":\"clear\"},\"media\":{\"link\":false}}";
    try std.testing.expectEqualStrings(expected, text);

    const parsed = try std.json.parseFromSliceLeaky(Options, arena, text, .{});
    try std.testing.expectEqual(@as(f64, 2), parsed.step.?);
    try std.testing.expectEqual(OnDelete.clear, parsed.reference.on_delete);
    try std.testing.expect(parsed.reference.create and !parsed.media.link);
    try std.testing.expectEqual(RichFormat.bold, parsed.richtext.formats.?[0]);
    try std.testing.expect(bare.richtext.formats == null);
}
