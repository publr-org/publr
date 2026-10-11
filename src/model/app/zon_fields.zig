//! One top-level field of an `app.zon` given a new value, the rest of the file kept byte
//! for byte: comments, order, spacing. A field the file lacks is added after the last one.
//! Strings, character literals, multiline strings and comments are stepped over, so a brace
//! or a field name inside them never counts. Pure.

const std = @import("std");

pub const fields_max: u32 = 64;

pub const Error = error{ Malformed, TooManyFields, OutOfMemory };

const Range = struct {
    start: u32,
    end: u32,
};
const Field = struct {
    name: []const u8,
    value: Range,
};

/// Where the top-level struct's fields are, and where it closes.
const Layout = struct {
    fields: [fields_max]Field = undefined,
    len: u32 = 0,
    /// The top-level struct's closing `}`.
    close: u32 = 0,
};

/// `source` with field `name` set to `value`, the field's own text, as written.
pub fn replace(
    arena: std.mem.Allocator,
    source: []const u8,
    name: []const u8,
    value: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(value.len > 0);

    var layout: Layout = .{};

    try read_layout(source, &layout);

    for (layout.fields[0..layout.len]) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            const parts = [_][]const u8{
                source[0..field.value.start],
                value,
                source[field.value.end..],
            };

            return std.mem.concat(arena, u8, &parts);
        }
    }

    var last = layout.close;

    while (last > 0 and std.ascii.isWhitespace(source[last - 1])) {
        last -= 1;
    }

    const separator = if (source[last - 1] == ',' or source[last - 1] == '{') "" else ",";
    const added = try std.fmt.allocPrint(arena, "{s}\n    .{s} = {s},", .{
        separator,
        name,
        value,
    });
    const parts = [_][]const u8{ source[0..last], added, source[last..] };

    std.debug.assert(last <= layout.close);

    return std.mem.concat(arena, u8, &parts);
}

/// The text after `at` that is not code (whitespace, a comment, a string), stepped over;
/// where the next character of code is.
fn skip_quiet(source: []const u8, from: u32) u32 {
    std.debug.assert(from <= source.len);

    var at = from;

    while (at < source.len) {
        if (std.ascii.isWhitespace(source[at])) {
            at += 1;
        } else if (std.mem.startsWith(u8, source[at..], "//") or
            std.mem.startsWith(u8, source[at..], "\\\\"))
        {
            at = line_end(source, at);
        } else {
            break;
        }
    }

    return at;
}

fn line_end(source: []const u8, from: u32) u32 {
    std.debug.assert(from <= source.len);

    const found = std.mem.indexOfScalarPos(u8, source, from, '\n') orelse source.len;

    return @intCast(found);
}

/// Past a string or character literal starting at `from`; the end of the source when it
/// never closes.
fn skip_quoted(source: []const u8, from: u32) u32 {
    std.debug.assert(source[from] == '"' or source[from] == '\'');

    const quote = source[from];
    var at = from + 1;

    while (at < source.len) : (at += 1) {
        if (source[at] == '\\') {
            at += 1;
        } else if (source[at] == quote or source[at] == '\n') {
            return at + 1;
        }
    }

    return @intCast(source.len);
}

fn read_layout(source: []const u8, layout: *Layout) Error!void {
    std.debug.assert(source.len < 1 << 31);
    std.debug.assert(layout.len == 0);

    const open = skip_quiet(source, 0);

    if (!std.mem.startsWith(u8, source[open..], ".{")) {
        return error.Malformed;
    }

    var at = skip_quiet(source, open + 2);

    while (at < source.len) : (at = skip_quiet(source, at)) {
        if (source[at] == '}') {
            layout.close = at;
            return;
        }

        at = try read_field(source, at, layout);
    }

    return error.Malformed;
}

fn is_name_char(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

/// One `.name = value,` at the top level, added to the layout; where the next one starts.
fn read_field(source: []const u8, from: u32, layout: *Layout) Error!u32 {
    std.debug.assert(from < source.len);

    if (source[from] != '.') {
        return error.Malformed;
    }

    var name_end = from + 1;

    while (name_end < source.len and is_name_char(source[name_end])) {
        name_end += 1;
    }

    const equals = skip_quiet(source, name_end);

    if (name_end == from + 1 or equals >= source.len or source[equals] != '=') {
        return error.Malformed;
    }

    const value_start = skip_quiet(source, equals + 1);
    const value_end = try value_end_of(source, value_start);

    if (layout.len == fields_max) {
        return error.TooManyFields;
    }

    layout.fields[layout.len] = .{
        .name = source[from + 1 .. name_end],
        .value = .{
            .start = value_start,
            .end = value_end,
        },
    };
    layout.len += 1;

    return if (value_end < source.len and source[value_end] == ',') value_end + 1 else value_end;
}

/// Where a value ends: at the `,` or the `}` that closes the struct holding it, its own
/// nested braces, brackets and parentheses counted.
fn value_end_of(source: []const u8, from: u32) Error!u32 {
    std.debug.assert(from <= source.len);

    var at = from;
    var depth: u32 = 0;
    var end = from;

    while (at < source.len) {
        const quiet = skip_quiet(source, at);

        if (quiet != at) {
            at = quiet;
            continue;
        }

        const char = source[at];

        if (char == '"' or char == '\'') {
            at = skip_quoted(source, at);
            end = at;
            continue;
        }

        if (depth == 0 and (char == ',' or char == '}')) {
            return end;
        }

        if (char == '{' or char == '[' or char == '(') {
            depth += 1;
        } else if (char == '}' or char == ']' or char == ')') {
            if (depth == 0) {
                return error.Malformed;
            }

            depth -= 1;
        }

        at += 1;
        end = at;
    }

    return error.Malformed;
}

const testing = std.testing;

const sample =
    \\// The app at the root. {not a brace}
    \\.{
    \\    .name = "www",
    \\    .label = "Web, \"site\" }",
    \\    .mount = .{ .path = "/" }, // root
    \\    .tokens = .{
    \\        .{ .name = "color-ink", .value = "#111" },
    \\    },
    \\    .roles = .{"member"}
    \\}
    \\
;

test "replace: a field's value, the rest kept byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replaced = try replace(arena, sample, "tokens", ".{}");

    try testing.expectEqualStrings(
        \\// The app at the root. {not a brace}
        \\.{
        \\    .name = "www",
        \\    .label = "Web, \"site\" }",
        \\    .mount = .{ .path = "/" }, // root
        \\    .tokens = .{},
        \\    .roles = .{"member"}
        \\}
        \\
    , replaced);

    const last = try replace(arena, sample, "roles", ".{}");

    try testing.expect(std.mem.endsWith(u8, last, "    .roles = .{}\n}\n"));
}

test "replace: a field the file lacks is added after the last one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const added = try replace(arena, sample, "fonts", ".{}");

    const tail = ".roles = .{\"member\"},\n    .fonts = .{},\n}\n";

    try testing.expect(std.mem.endsWith(u8, added, tail));

    const bare = try replace(arena, ".{ .name = \"a\", }", "fonts", ".{}");

    try testing.expectEqualStrings(".{ .name = \"a\",\n    .fonts = .{}, }", bare);
}

test "replace: what is not an app.zon is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const broken = [_][]const u8{
        "",
        "{ .name = 1 }",
        ".{ .name = \"open",
        ".{ name = 1 }",
        ".{ .name 1 }",
        ".{ .name = .{ .x = 1 }",
    };

    for (broken) |source| {
        try testing.expectError(error.Malformed, replace(arena, source, "tokens", ".{}"));
    }
}
