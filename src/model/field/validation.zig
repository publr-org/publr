//! A field's rules: what a value must be for a write to go through, the messages shown when
//! it is not, and the hint that says the rules beside the field's help. Only rules live
//! here; how a field is shown and edited is its `options`. Every part has a default, so a
//! field carries only what was set.
const std = @import("std");
const options = @import("options.zig");

pub const hint_len_max: u32 = 255;

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

pub const Date = struct {
    /// Refuse moments before the day the record is written.
    from_now: bool = false,
};

pub const Slug = struct {
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
};

pub const Url = struct {
    /// Empty accepts http and https; else only these, from `options.url_schemes`.
    schemes: []const []const u8 = &.{},
    /// Empty accepts any host; else only these.
    hosts: []const []const u8 = &.{},
};

pub const Reference = struct {
    /// Only records that are live may be pointed at.
    live_only: bool = false,
    /// Only publicly readable record types may be selected.
    public_only: bool = false,
};

/// The file a media field points at: sizes in bytes, dimensions in pixels; a null bound
/// is no bound.
pub const Media = struct {
    size_min: ?u64 = null,
    size_max: ?u64 = null,
    /// Empty accepts any file; else only these, from `options.media_types`.
    types: []const []const u8 = &.{},
    width_min: ?u32 = null,
    width_max: ?u32 = null,
    height_min: ?u32 = null,
    height_max: ?u32 = null,
};

pub const Validation = struct {
    required: bool = false,
    /// No two records of the type may hold the same value; a text value held once.
    unique: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    min_len: ?u32 = null,
    max_len: ?u32 = null,
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
    /// The rules as the field shows them beside its help, replacing the line its kind
    /// writes; `{max_len}` and the other bounds are filled in.
    hint: []const u8 = "",
    date: Date = .{},
    slug: Slug = .{},
    email: Email = .{},
    url: Url = .{},
    reference: Reference = .{},
    media: Media = .{},

    /// Written sparsely: only what differs from the defaults.
    pub fn jsonStringify(self: Validation, writer: anytype) !void {
        try options.write_sparse(Validation, self, writer);
    }
};

test "a validation writes only what was set" {
    const set: Validation = .{
        .required = true,
        .max_len = 280,
    };
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, set, .{});
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("{\"required\":true,\"max_len\":280}", text);
    try std.testing.expect(!(Validation{}).required);
}
