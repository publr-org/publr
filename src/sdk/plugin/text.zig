//! `publr.text`: the text helpers plugins need every day, so none writes `std.mem`. Tests
//! and slices come straight from `publr_text`; what makes new text takes `ctx` first and
//! lives until the call ends, like `ctx.print`.

const std = @import("std");
const library = @import("publr_text");

pub const length = library.length;
pub const slice = library.slice;

pub const equals = library.equals;
pub const equals_ignore_case = library.equals_ignore_case;
pub const contains = library.contains;
pub const starts_with = library.starts_with;
pub const ends_with = library.ends_with;
pub const index_of = library.index_of;
pub const last_index_of = library.last_index_of;
pub const is_empty = library.is_empty;
pub const is_blank = library.is_blank;

pub const trim = library.trim;
pub const trim_start = library.trim_start;
pub const trim_end = library.trim_end;

pub const parse_int = library.parse_int;
pub const parse_float = library.parse_float;
pub const is_email = library.is_email;
pub const is_url = library.is_url;

pub const Error = error{OutOfMemory};

/// `text` with A to Z lowered; other letters as they are. JS's `toLowerCase`.
pub fn lower(ctx: anytype, text: []const u8) Error![]const u8 {
    return library.lower(ctx.arena(), text);
}

/// `text` with a to z raised; other letters as they are. JS's `toUpperCase`.
pub fn upper(ctx: anytype, text: []const u8) Error![]const u8 {
    return library.upper(ctx.arena(), text);
}

/// The pieces between each `separator`. JS's `split` with text.
pub fn split(ctx: anytype, text: []const u8, separator: []const u8) Error![]const []const u8 {
    return library.split(ctx.arena(), text, separator);
}

/// The first `part` replaced by `with`. JS's `replace` with text.
pub fn replace(
    ctx: anytype,
    text: []const u8,
    part: []const u8,
    with: []const u8,
) Error![]const u8 {
    return library.replace(ctx.arena(), text, part, with);
}

/// Every `part` replaced by `with`. JS's `replaceAll` with text.
pub fn replace_all(
    ctx: anytype,
    text: []const u8,
    part: []const u8,
    with: []const u8,
) Error![]const u8 {
    return library.replace_all(ctx.arena(), text, part, with);
}

/// JS's `encodeURIComponent`.
pub fn encode_uri_component(
    ctx: anytype,
    text: []const u8,
) error{ OutOfMemory, Malformed }![]const u8 {
    return library.encode_uri_component(ctx.arena(), text);
}

/// JS's `decodeURIComponent`.
pub fn decode_uri_component(
    ctx: anytype,
    text: []const u8,
) error{ OutOfMemory, Malformed }![]const u8 {
    return library.decode_uri_component(ctx.arena(), text);
}

test "publr.text takes ctx where it makes text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Fake = struct {
        allocator: std.mem.Allocator,

        pub fn arena(self: *const @This()) std.mem.Allocator {
            return self.allocator;
        }
    };
    const ctx: Fake = .{
        .allocator = arena_state.allocator(),
    };

    try std.testing.expectEqualStrings("ada@example.com", try lower(&ctx, "Ada@Example.com"));
    try std.testing.expect(starts_with("admin-ada", "admin"));
    try std.testing.expect(!equals("a", "b"));

    const pieces = try split(&ctx, "tea, coffee, milk", ", ");

    try std.testing.expectEqual(@as(usize, 3), pieces.len);
    try std.testing.expectEqualStrings("a#b#c", try replace_all(&ctx, "a-b-c", "-", "#"));
}
