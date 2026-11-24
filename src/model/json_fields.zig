//! A JSON object cut to some of its fields, read where the text lies: each field kept is
//! copied as it was written, and nothing is built in between. A page of two hundred records
//! read for three of their fields takes those fields' bytes, never every record as a tree.
const std = @import("std");

pub const Error = error{ Invalid, OutOfMemory };

/// How deep a value kept or passed over may nest.
const nesting_bytes: u32 = 512;

/// `document`, a JSON object, with only its fields named in `fields`, in the order the
/// document holds them. A field written twice is kept as its first.
pub fn only(
    arena: std.mem.Allocator,
    document: []const u8,
    fields: []const []const u8,
) Error![]const u8 {
    std.debug.assert(fields.len > 0);
    std.debug.assert(fields.len <= 64);

    var nesting: [nesting_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&nesting);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), document);
    var kept: std.ArrayList(u8) = .empty;
    var taken: u64 = 0;

    if ((scanner.next() catch return error.Invalid) != .object_begin) {
        return error.Invalid;
    }

    kept.append(arena, '{') catch return error.OutOfMemory;

    while (true) {
        const token = scanner.nextAlloc(arena, .alloc_if_needed) catch return error.Invalid;
        const name = switch (token) {
            .object_end => break,
            .string, .allocated_string => |text| text,
            else => return error.Invalid,
        };
        const from = scanner.cursor;

        scanner.skipValue() catch return error.Invalid;

        const index = index_of(fields, name) orelse continue;

        if (taken & (@as(u64, 1) << @intCast(index)) != 0) {
            continue;
        }

        taken |= @as(u64, 1) << @intCast(index);

        try field(arena, &kept, name, document[from..scanner.cursor]);
    }

    if ((scanner.next() catch return error.Invalid) != .end_of_document) {
        return error.Invalid;
    }

    kept.append(arena, '}') catch return error.OutOfMemory;

    return kept.items;
}

/// `"name":value` appended, a comma before it when it is not the first; `rest` is the text
/// from the name's end to the value's: the colon and the value as written.
fn field(
    arena: std.mem.Allocator,
    kept: *std.ArrayList(u8),
    name: []const u8,
    rest: []const u8,
) Error!void {
    std.debug.assert(kept.items.len > 0);
    std.debug.assert(rest.len >= 2);

    if (kept.items.len > 1) {
        kept.append(arena, ',') catch return error.OutOfMemory;
    }

    const quoted = std.json.Stringify.valueAlloc(arena, name, .{}) catch {
        return error.OutOfMemory;
    };

    kept.appendSlice(arena, quoted) catch return error.OutOfMemory;
    kept.appendSlice(arena, std.mem.trim(u8, rest, " \t\r\n")) catch return error.OutOfMemory;
}

/// The text field `name` at the top of `document`, a JSON object, read where it lies: null
/// when it has none, when the field is not text, or when the text is written with escapes
/// (an id, a type's handle and a name are written plain).
pub fn text_of(document: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    var nesting: [nesting_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&nesting);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), document);

    if ((scanner.next() catch return null) != .object_begin) {
        return null;
    }

    while (true) {
        const field_name = switch (scanner.next() catch return null) {
            .string => |text| text,
            // A name written with escapes is none an operation's input has.
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2 => "",
            .partial_string_escaped_3, .partial_string_escaped_4 => "",
            else => return null,
        };

        if (field_name.len == 0) {
            skip_rest(&scanner) catch return null;
            scanner.skipValue() catch return null;
            continue;
        }

        if (!std.mem.eql(u8, field_name, name)) {
            scanner.skipValue() catch return null;
            continue;
        }

        return switch (scanner.next() catch return null) {
            .string => |text| text,
            else => null,
        };
    }
}

/// The rest of a text the scanner hands over in parts.
fn skip_rest(scanner: *std.json.Scanner) !void {
    std.debug.assert(scanner.cursor <= scanner.input.len);

    while (true) {
        switch (try scanner.next()) {
            .string => return,
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2 => {},
            .partial_string_escaped_3, .partial_string_escaped_4 => {},
            else => return error.SyntaxError,
        }
    }
}

fn index_of(fields: []const []const u8, name: []const u8) ?u32 {
    std.debug.assert(fields.len <= 64);

    for (fields, 0..) |wanted, index| {
        if (std.mem.eql(u8, wanted, name)) {
            return @intCast(index);
        }
    }

    return null;
}

test "an object is cut to the fields named, each as it was written" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document =
        \\{"title":"Tea","lines":[{"a":1},{"a":[2,3]}], "price" :{"PLN":500},"note":"a \"b\""}
    ;

    try std.testing.expectEqualStrings(
        "{\"title\":\"Tea\",\"price\":{\"PLN\":500}}",
        try only(arena, document, &.{ "price", "title", "missing" }),
    );
    try std.testing.expectEqualStrings(
        "{\"note\":\"a \\\"b\\\"\"}",
        try only(arena, document, &.{"note"}),
    );
    try std.testing.expectEqualStrings("{}", try only(arena, "{}", &.{"title"}));
    try std.testing.expectEqualStrings(
        "{\"a\":1}",
        try only(arena, "{\"a\":1,\"a\":2}", &.{"a"}),
    );

    for ([_][]const u8{ "", "[1]", "{\"a\":", "{\"a\":1}x", "{\"a\" 1}", "7" }) |broken| {
        try std.testing.expectError(error.Invalid, only(arena, broken, &.{"a"}));
    }
}

test "a top-level text field is read where it lies" {
    const input = "{\"document\":{\"kind\":\"inner\"},\"kind\":\"visit\",\"plugin\":null}";

    try std.testing.expectEqualStrings("visit", text_of(input, "kind").?);
    try std.testing.expectEqual(@as(?[]const u8, null), text_of(input, "plugin"));
    try std.testing.expectEqual(@as(?[]const u8, null), text_of(input, "type"));
    try std.testing.expectEqual(@as(?[]const u8, null), text_of("[1]", "kind"));
    try std.testing.expectEqual(@as(?[]const u8, null), text_of("{\"kind\":", "kind"));
    try std.testing.expectEqualStrings("b", text_of("{\"a\\n\":1,\"kind\":\"b\"}", "kind").?);
}
