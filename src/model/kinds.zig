//! The field kinds as data: every kind, core or plugin, is one descriptor here, and the
//! validator, the store, the converter and the admin read that descriptor instead of
//! switching on a closed enum. A plugin adds a kind the way it adds a status.
const std = @import("std");
const field = @import("field.zig");
const checks = @import("kinds/checks.zig");

pub const id_len_max: u32 = 32;
pub const kinds_max: u32 = 64;
pub const string_len_max: u32 = checks.string_len_max;

/// How a value is kept in `record_values`: the five columns, plus `bool` (an int column
/// holding a JSON boolean) and `none` for the two containers, which have no values of
/// their own. Closed: a plugin kind picks one of these.
pub const Storage = enum { text, int, real, ref, long, bool, none };

/// The control the record form draws for the kind; `json` is the fallback for anything
/// without a control of its own.
pub const Control = enum { input, number, datetime, textarea, checkbox, select, json };

/// Which validation and option controls the field form shows for the kind.
pub const Has = struct {
    length: bool = false,
    range: bool = false,
    /// The range is a span of days: its bounds are dates, not numbers.
    dates: bool = false,
    choices: bool = false,
    target: bool = false,
    source: bool = false,
    rows: bool = false,
    /// A shape the text must have: a preset or a pattern.
    pattern: bool = false,
    /// A word count, beside the character count.
    words: bool = false,
    /// The rules over a media file: size, family, dimensions.
    media: bool = false,
    /// The taxonomy whose terms the field assigns.
    taxonomy: bool = false,
};

/// The kind's own rule over one value that already has the right storage shape.
pub const Check = checks.Check;

pub const Kind = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    icon: []const u8,
    storage: Storage,
    control: Control = .json,
    placeholder: []const u8 = "",
    has: Has = .{},
    many_allowed: bool = true,
    searchable_allowed: bool = false,
    title_allowed: bool = false,
    /// A field of the kind may refuse a value another record of the type holds.
    unique_allowed: bool = false,
    /// A field of the kind may give new records a value to start with.
    default_allowed: bool = false,
    check: ?Check = null,
    /// The kinds whose values this kind takes when a field changes kind.
    convert_from: []const []const u8 = &.{},
};

pub const core = [_]Kind{
    .{
        .id = "string",
        .label = "Text",
        .description = "A short line: a title, a name",
        .icon = "paragraph",
        .storage = .text,
        .control = .input,
        .has = .{ .length = true, .pattern = true },
        .searchable_allowed = true,
        .title_allowed = true,
        .unique_allowed = true,
        .default_allowed = true,
        .convert_from = &.{ "slug", "email", "url", "select", "integer", "number", "boolean" },
    },
    .{
        .id = "text",
        .label = "Long text",
        .description = "Paragraphs without formatting",
        .icon = "text-align-left",
        .storage = .long,
        .control = .textarea,
        .has = .{ .length = true, .rows = true, .pattern = true, .words = true },
        .searchable_allowed = true,
        .default_allowed = true,
        .convert_from = &.{ "string", "richtext", "slug", "email", "url", "select" },
    },
    .{
        .id = "richtext",
        .label = "Rich text",
        .description = "Formatted content",
        .icon = "quote",
        .storage = .long,
        .control = .textarea,
        .has = .{ .length = true, .rows = true },
        .searchable_allowed = true,
        .convert_from = &.{ "string", "text" },
    },
    .{
        .id = "slug",
        .label = "Slug",
        .description = "A URL-safe name made from another field",
        .icon = "tag",
        .storage = .text,
        .control = .input,
        .placeholder = "generated when empty",
        .has = .{ .length = true, .source = true },
        .many_allowed = false,
        .title_allowed = true,
        .check = &checks.slug,
        .convert_from = &.{"string"},
    },
    .{
        .id = "email",
        .label = "Email",
        .description = "An email address",
        .icon = "user",
        .storage = .text,
        .control = .input,
        .has = .{ .length = true },
        .unique_allowed = true,
        .default_allowed = true,
        .check = &checks.email,
        .convert_from = &.{"string"},
    },
    .{
        .id = "url",
        .label = "URL",
        .description = "A web address",
        .icon = "globe",
        .storage = .text,
        .control = .input,
        .has = .{ .length = true },
        .unique_allowed = true,
        .default_allowed = true,
        .check = &checks.url,
        .convert_from = &.{"string"},
    },
    .{
        .id = "boolean",
        .label = "Boolean",
        .description = "True or false",
        .icon = "check",
        .storage = .bool,
        .control = .checkbox,
        .default_allowed = true,
    },
    .{
        .id = "integer",
        .label = "Integer",
        .description = "A whole number",
        .icon = "math",
        .storage = .int,
        .control = .number,
        .has = .{ .range = true, .choices = true },
        .unique_allowed = true,
        .default_allowed = true,
        .convert_from = &.{ "string", "number", "datetime" },
    },
    .{
        .id = "number",
        .label = "Number",
        .description = "A decimal number",
        .icon = "chart",
        .storage = .real,
        .control = .number,
        .has = .{ .range = true, .choices = true },
        .default_allowed = true,
        .convert_from = &.{ "string", "integer" },
    },
    .{
        .id = "datetime",
        .label = "Date and time",
        .description = "A moment",
        .icon = "calendar-check",
        .storage = .int,
        .control = .datetime,
        .has = .{ .range = true, .dates = true },
        .default_allowed = true,
        .check = &checks.datetime,
    },
    .{
        .id = "select",
        .label = "Select",
        .description = "One of a list of values",
        .icon = "list-unordered",
        .storage = .text,
        .control = .select,
        .has = .{ .choices = true },
        .default_allowed = true,
        .check = &checks.select,
        .convert_from = &.{"string"},
    },
    .{
        .id = "media",
        .label = "Media",
        .description = "A file from the media library: an image, a document, a video",
        .icon = "image",
        .storage = .ref,
        .control = .input,
        .has = .{ .media = true },
    },
    .{
        .id = "reference",
        .label = "Reference",
        .description = "Points at records of another type",
        .icon = "link",
        .storage = .ref,
        .control = .input,
        .has = .{ .target = true },
    },
    .{
        .id = "terms",
        .label = "Terms",
        .description = "Terms of a taxonomy the record is classified under",
        .icon = "tag",
        .storage = .ref,
        .control = .select,
        .has = .{ .taxonomy = true },
    },
    .{
        .id = "user",
        .label = "User",
        .description = "Select a user",
        .icon = "user",
        .storage = .ref,
        .control = .input,
    },
    .{
        .id = "embed",
        .label = "Embed",
        .description = "The URL of externally hosted content",
        .icon = "link",
        .storage = .text,
        .control = .input,
        .check = &checks.url,
    },
    .{
        .id = "color",
        .label = "Color",
        .description = "A color",
        .icon = "image",
        .storage = .text,
        .control = .input,
        .default_allowed = true,
        .check = &@import("kinds/extra.zig").color,
    },
    .{
        .id = "time",
        .label = "Time",
        .description = "A time of day without a date",
        .icon = "calendar-check",
        .storage = .text,
        .control = .input,
        .default_allowed = true,
        .check = &@import("kinds/extra.zig").time,
    },
    .{
        .id = "password",
        .label = "Password",
        .description = "Masked text; stored as ordinary field data",
        .icon = "lock",
        .storage = .text,
        .control = .input,
        .has = .{ .length = true },
        .many_allowed = false,
    },
    .{
        .id = "link",
        .label = "Link",
        .description = "A URL, link text and target",
        .icon = "link",
        .storage = .none,
        .many_allowed = false,
    },
    .{
        .id = "location",
        .label = "Location",
        .description = "An address and geographic coordinates",
        .icon = "globe",
        .storage = .none,
        .many_allowed = false,
    },
    .{
        .id = "message",
        .label = "Message",
        .description = "Instructions without a stored value",
        .icon = "paragraph",
        .storage = .none,
        .many_allowed = false,
    },
    .{
        .id = "tab",
        .label = "Tab",
        .description = "Start an editor tab for the fields that follow",
        .icon = "list-unordered",
        .storage = .none,
        .many_allowed = false,
    },
    .{
        .id = "accordion",
        .label = "Accordion",
        .description = "A collapsible editor section",
        .icon = "group",
        .storage = .none,
        .many_allowed = false,
    },
    .{
        .id = "group",
        .label = "Group",
        .description = "A named set of fields",
        .icon = "group",
        .storage = .none,
        .many_allowed = false,
    },
    .{
        .id = "repeater",
        .label = "Repeater",
        .description = "A list of field sets",
        .icon = "duplicate",
        .storage = .none,
        .many_allowed = false,
    },
};

/// What a stored field shows as when its kind is gone (a plugin no longer built in):
/// kept as it is, edited as JSON, never validated.
pub const unknown: Kind = .{
    .id = "",
    .label = "Unknown kind",
    .description = "No plugin provides this kind any more",
    .icon = "components",
    .storage = .long,
};

pub fn find(kinds: []const Kind, id: []const u8) ?Kind {
    std.debug.assert(kinds.len <= kinds_max);

    if (id.len > string_len_max) {
        return null;
    }

    for (kinds) |kind| {
        if (std.mem.eql(u8, kind.id, id)) {
            return kind;
        }
    }

    return null;
}

/// The kind, or `unknown` for an id no kind answers to.
pub fn lookup(kinds: []const Kind, id: []const u8) Kind {
    std.debug.assert(kinds.len <= kinds_max);

    return find(kinds, id) orelse unknown;
}

pub fn column_of(storage: Storage) field.Column {
    std.debug.assert(storage != .none);
    std.debug.assert(@intFromEnum(storage) <= 6);

    return switch (storage) {
        .text => .text,
        .int, .bool => .int,
        .real => .real,
        .ref => .ref,
        .long => .long,
        .none => unreachable,
    };
}

/// Whether values of `from` are taken by fields of `to` when a field changes kind.
pub fn convertible(kinds: []const Kind, from: []const u8, to: []const u8) bool {
    std.debug.assert(from.len > 0);
    std.debug.assert(to.len > 0);

    if (std.mem.eql(u8, from, to)) {
        return true;
    }

    const target = find(kinds, to) orelse return false;

    for (target.convert_from) |source| {
        if (std.mem.eql(u8, source, from)) {
            return true;
        }
    }

    return false;
}

pub const valid_slug = checks.valid_slug;

/// The kinds a build knows: the core's, then the plugins', checked once at compile time.
pub fn Registry(comptime kinds: []const Kind) type {
    comptime validate(kinds);

    return struct {
        pub const all = kinds;

        pub fn find_kind(id: []const u8) ?Kind {
            comptime std.debug.assert(kinds.len > 0);

            return find(kinds, id);
        }
    };
}

fn validate(comptime kinds: []const Kind) void {
    comptime {
        @setEvalBranchQuota(100_000);

        if (kinds.len == 0 or kinds.len > kinds_max) {
            @compileError("kind registry needs 1 to 64 kinds");
        }

        for (kinds, 0..) |kind, index| {
            if (kind.id.len == 0 or kind.id.len > id_len_max) {
                @compileError("kind id length: " ++ kind.id);
            }

            const container = field.is_container(kind.id) or field.is_layout(kind.id);

            if (kind.storage == .none and !container) {
                @compileError("only containers and layout elements have no storage: " ++ kind.id);
            }

            for (kinds[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.id, kind.id)) {
                    @compileError("duplicate kind: " ++ kind.id);
                }
            }

            for (kind.convert_from) |source| {
                if (find(kinds, source) == null) {
                    @compileError("kind " ++ kind.id ++ " converts from unknown kind " ++ source);
                }
            }
        }
    }
}

pub const Core = Registry(&core);

test "core registry: every kind found, storage columns, conversions" {
    try std.testing.expectEqual(@as(usize, 26), Core.all.len);
    try std.testing.expect(Core.find_kind("terms").?.has.taxonomy);
    try std.testing.expectEqual(Storage.long, Core.find_kind("richtext").?.storage);
    try std.testing.expectEqual(Storage.bool, Core.find_kind("boolean").?.storage);
    try std.testing.expect(Core.find_kind("nope") == null);
    try std.testing.expectEqualStrings("Unknown kind", lookup(&core, "nope").label);
    try std.testing.expectEqual(field.Column.int, column_of(.bool));
    try std.testing.expectEqual(field.Column.ref, column_of(.ref));
    try std.testing.expect(convertible(&core, "string", "text"));
    try std.testing.expect(convertible(&core, "string", "integer"));
    try std.testing.expect(convertible(&core, "datetime", "integer"));
    try std.testing.expect(convertible(&core, "slug", "slug"));
    try std.testing.expect(!convertible(&core, "text", "string"));
    try std.testing.expect(!convertible(&core, "reference", "string"));
    try std.testing.expect(!convertible(&core, "repeater", "group"));
    try std.testing.expect(Core.find_kind("media").?.has.media);
    try std.testing.expect(Core.find_kind("datetime").?.has.dates);
    try std.testing.expect(Core.find_kind("email").?.unique_allowed);
    try std.testing.expect(Core.find_kind("integer").?.unique_allowed);
    try std.testing.expect(!Core.find_kind("number").?.unique_allowed);
    try std.testing.expect(Core.find_kind("text").?.has.words);
    try std.testing.expect(!Core.find_kind("reference").?.default_allowed);
}

test "a plugin kind joins the registry with the core's" {
    const extended = core ++ [_]Kind{.{
        .id = "geo.point",
        .label = "Point",
        .description = "A latitude and a longitude",
        .icon = "globe",
        .storage = .long,
        .convert_from = &.{"string"},
    }};
    const Extended = Registry(&extended);

    try std.testing.expectEqual(@as(usize, core.len + 1), Extended.all.len);
    try std.testing.expectEqual(Control.json, Extended.find_kind("geo.point").?.control);
    try std.testing.expect(convertible(Extended.all, "string", "geo.point"));
    try std.testing.expect(!convertible(Extended.all, "geo.point", "string"));
}
