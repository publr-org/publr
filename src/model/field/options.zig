//! What a field's kind lets an editor tune: limits over a value, the messages shown when
//! a value breaks them, and the kind-specific groups (a date's shape, a media file's
//! rules, a reference's behaviour). Every part has a default, so a field carries only
//! what was set.
const std = @import("std");

pub const message_len_max: u32 = 255;
pub const media_types_max: u32 = 16;
pub const list_max: u32 = 64;
pub const label_len_max: u32 = 64;
pub const pattern_len_max: u32 = 255;
pub const decimals_max: u32 = 10;
pub const dimension_max: u32 = 100_000;

/// The message an editor sees when a value breaks the matching rule; the built-in one
/// when empty.
pub const Messages = struct {
    length: []const u8 = "",
    range: []const u8 = "",
    size: []const u8 = "",
    types: []const u8 = "",
    dimensions: []const u8 = "",
    items: []const u8 = "",
    pattern: []const u8 = "",
    words: []const u8 = "",
    domain: []const u8 = "",
    scheme: []const u8 = "",
    host: []const u8 = "",
    reserved: []const u8 = "",
    choices: []const u8 = "",
};

/// A shape a text must have, short of writing a pattern.
pub const Preset = enum {
    any,
    digits,
    letters,
    alphanumeric,
    no_spaces,
    lowercase,
    uppercase,
    phone,
};

/// How a date and time field is shown and posted: a moment, or a day alone.
pub const DateFormat = enum { datetime, date };

pub const Date = struct {
    format: DateFormat = .datetime,
    /// Refuse moments before the day the record is written.
    from_now: bool = false,
};

pub const TextFormat = enum { plain, markdown };

pub const Text = struct {
    format: TextFormat = .plain,
};

pub const Slug = struct {
    /// Once the record is live the slug stays as it is, whatever the source does.
    lock_on_publish: bool = false,
    /// Slugs the site keeps for itself; refused on any record.
    reserved: []const []const u8 = &.{},
    /// A slug someone gave (typed, sent) that another record holds is refused as a
    /// conflict instead of numbered (`-2`): where the slug is an address the person was
    /// shown, it must be the one they get. Derived slugs are numbered either way.
    refuse_taken: bool = false,
};

pub const Email = struct {
    /// Empty accepts any domain; else only addresses at these.
    domains: []const []const u8 = &.{},
    lowercase: bool = false,
};

pub const Url = struct {
    /// Empty accepts http and https; else only these, from `url_schemes`.
    schemes: []const []const u8 = &.{},
    /// Empty accepts any host; else only these.
    hosts: []const []const u8 = &.{},
};

pub const BooleanControl = enum { toggle, checkbox, radio };

pub const Boolean = struct {
    true_label: []const u8 = "",
    false_label: []const u8 = "",
    control: BooleanControl = .toggle,
};

pub const NumberControl = enum { input, slider, rating };

pub const Number = struct {
    /// Shown beside the input: `kg`, `$`, `%`.
    unit: []const u8 = "",
    unit_after: bool = true,
    /// How many decimal places the input steps by; null for any.
    decimals: ?u32 = null,
    control: NumberControl = .input,
};

pub const SelectControl = enum { dropdown, list, buttons };

pub const Select = struct {
    /// A dropdown, or the choices laid out as radios (one value) or checkboxes (many).
    control: SelectControl = .dropdown,
};

pub const OnDelete = enum { keep, block, clear };

pub const Reference = struct {
    create: bool = true,
    link: bool = true,
    /// Only records that are live may be pointed at.
    live_only: bool = false,
    /// Only publicly readable record types may be selected.
    public_only: bool = false,
    /// What purging a record this field points at does to the pointer.
    on_delete: OnDelete = .keep,
};

pub const Container = struct {
    collapsed: bool = false,
    /// The child whose value names a repeater item in its header.
    label_field: []const u8 = "",
    add_label: []const u8 = "",
};

/// The rules a media field puts on the file it points at, and what the field's editor
/// offers: creating new files, linking existing ones. Sizes in bytes, dimensions in
/// pixels; a null bound is no bound.
pub const Media = struct {
    size_min: ?u64 = null,
    size_max: ?u64 = null,
    /// Empty accepts any file; else only these, from `media_types`.
    types: []const []const u8 = &.{},
    width_min: ?u32 = null,
    width_max: ?u32 = null,
    height_min: ?u32 = null,
    height_max: ?u32 = null,
    create: bool = true,
    link: bool = true,
};

pub const Options = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    min_len: ?u32 = null,
    max_len: ?u32 = null,
    /// A select's values, or the only values a number may take.
    choices: []const []const u8 = &.{},
    /// What the choices read as, one per choice; empty when the values are the labels.
    labels: []const []const u8 = &.{},
    source: []const u8 = "",
    /// The record types a reference may point at, by handle; empty for any record type.
    /// A virtual field names the one type its records are of.
    to: []const []const u8 = &.{},
    /// A virtual field: which kind (`referenced_by`), and the reference field of the `to`
    /// type that points here.
    virtual: []const u8 = "",
    via: []const u8 = "",
    /// The taxonomy a terms field assigns from, by handle.
    taxonomy: []const u8 = "",
    rows: ?u32 = null,
    placeholder: []const u8 = "",
    /// How many values a list holds, and whether every value must differ.
    items_min: ?u32 = null,
    items_max: ?u32 = null,
    distinct: bool = false,
    /// A shape the text must have: a preset, or a pattern of `*` `?` `#` `@`.
    preset: Preset = .any,
    pattern: []const u8 = "",
    words_min: ?u32 = null,
    words_max: ?u32 = null,
    messages: Messages = .{},
    text: Text = .{},
    date: Date = .{},
    slug: Slug = .{},
    email: Email = .{},
    url: Url = .{},
    boolean: Boolean = .{},
    number: Number = .{},
    select: Select = .{},
    reference: Reference = .{},
    container: Container = .{},
    media: Media = .{},

    /// Written sparsely: only what differs from the defaults, groups included, so a
    /// definition carries what was set and reads as such.
    pub fn jsonStringify(self: Options, writer: anytype) !void {
        try write_sparse(Options, self, writer);
    }
};

fn write_sparse(comptime Struct: type, value: Struct, writer: anytype) !void {
    comptime std.debug.assert(@typeInfo(Struct) == .@"struct");
    comptime std.debug.assert(std.meta.fields(Struct).len > 0);

    const base: Struct = .{};

    try writer.beginObject();

    inline for (std.meta.fields(Struct)) |info| {
        const field_value = @field(value, info.name);

        if (!std.meta.eql(field_value, @field(base, info.name))) {
            try writer.objectField(info.name);

            if (@typeInfo(info.type) == .@"struct") {
                try write_sparse(info.type, field_value, writer);
            } else {
                try writer.write(field_value);
            }
        }
    }

    try writer.endObject();
}

pub const MediaType = struct { id: []const u8, label: []const u8 };

/// The file families a media field can be limited to; a file's family is decided by its
/// mime type when it is uploaded.
pub const media_types = [_]MediaType{
    .{ .id = "image", .label = "Image" },
    .{ .id = "video", .label = "Video" },
    .{ .id = "audio", .label = "Audio" },
    .{ .id = "pdf", .label = "PDF document" },
    .{ .id = "document", .label = "Document" },
    .{ .id = "spreadsheet", .label = "Spreadsheet" },
    .{ .id = "presentation", .label = "Presentation" },
    .{ .id = "text", .label = "Plain text" },
    .{ .id = "code", .label = "Code" },
    .{ .id = "archive", .label = "Archive" },
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
pub fn scheme_allowed(url: Url, scheme: []const u8) bool {
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
    try std.testing.expect(!valid_media_type("font"));
    try std.testing.expect(!valid_media_type(""));

    try std.testing.expect(valid_scheme("mailto"));
    try std.testing.expect(!valid_scheme("ftp"));
    try std.testing.expect(scheme_allowed(.{}, "https"));
    try std.testing.expect(!scheme_allowed(.{}, "mailto"));
    try std.testing.expect(scheme_allowed(.{ .schemes = &.{"mailto"} }, "mailto"));
    try std.testing.expect(!scheme_allowed(.{ .schemes = &.{"mailto"} }, "https"));

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
    try std.testing.expectEqual(@as(usize, 0), options.messages.length.len);
}

test "options are written sparsely and read back whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare: Options = .{};
    const nothing = try std.json.Stringify.valueAlloc(arena, bare, .{});
    try std.testing.expectEqualStrings("{}", nothing);

    const set: Options = .{
        .max_len = 12,
        .messages = .{ .length = "Short" },
        .reference = .{ .on_delete = .clear },
        .media = .{ .types = &.{"image"} },
    };
    const text = try std.json.Stringify.valueAlloc(arena, set, .{});
    const expected = "{\"max_len\":12,\"messages\":{\"length\":\"Short\"}," ++
        "\"reference\":{\"on_delete\":\"clear\"},\"media\":{\"types\":[\"image\"]}}";
    try std.testing.expectEqualStrings(expected, text);

    const parsed = try std.json.parseFromSliceLeaky(Options, arena, text, .{});
    try std.testing.expectEqual(@as(u32, 12), parsed.max_len.?);
    try std.testing.expectEqual(OnDelete.clear, parsed.reference.on_delete);
    try std.testing.expect(parsed.reference.create and parsed.media.link);
    try std.testing.expectEqualStrings("image", parsed.media.types[0]);
}
