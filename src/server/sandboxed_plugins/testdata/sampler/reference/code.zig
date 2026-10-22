//! The code an entry of the reference shows, cut from the sampler's own source as it runs:
//! one declaration whole, with the `///` above it.
const std = @import("std");

/// The declaration `name` in `source` (`pub const operation`, `fn run`, `const hooks`), from
/// its first `///` line to its end: the first `;` outside brackets, strings and comments, or a
/// function's closing `}`. Null when there is none.
pub fn cut(source: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(source.len < 1 << 24);

    const start = declaration_start(source, name) orelse return null;
    const end = declaration_end(source, start) orelse return null;

    return source[comments_above(source, start)..end];
}

/// Just past the declaration starting at `start`: a `;` at depth 0, or the `}` that closes a
/// function's body.
fn declaration_end(source: []const u8, start: u32) ?u32 {
    std.debug.assert(start < source.len);

    const head = source[start..@min(source.len, start + 8)];
    const function = std.mem.startsWith(u8, head, "fn ") or std.mem.startsWith(u8, head, "pub fn ");
    var depth: i32 = 0;
    var at = start;

    while (at < source.len) : (at += 1) {
        const byte = source[at];

        if (byte == '/' and at + 1 < source.len and source[at + 1] == '/') {
            at = line_end(source, at);
        } else if (byte == '\\' and at + 1 < source.len and source[at + 1] == '\\') {
            at = line_end(source, at);
        } else if (byte == '"' or byte == '\'') {
            at = quoted_end(source, at);
        } else if (byte == '(' or byte == '[' or byte == '{') {
            depth += 1;
        } else if (byte == ')' or byte == ']' or byte == '}') {
            depth -= 1;

            if (function and byte == '}' and depth == 0) {
                return at + 1;
            }
        } else if (byte == ';' and depth == 0) {
            return at + 1;
        }
    }

    return null;
}

/// The last byte of the line holding `at`.
fn line_end(source: []const u8, at: u32) u32 {
    std.debug.assert(at < source.len);

    const found = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;

    return @intCast(found - 1);
}

/// The closing quote of the string or character starting at `at`.
fn quoted_end(source: []const u8, at: u32) u32 {
    std.debug.assert(at < source.len);

    const quote = source[at];
    var next = at + 1;

    while (next < source.len and source[next] != quote and source[next] != '\n') : (next += 1) {
        if (source[next] == '\\') {
            next += 1;
        }
    }

    return @intCast(@min(next, source.len - 1));
}

/// Where the line declaring `name` starts.
fn declaration_start(source: []const u8, name: []const u8) ?u32 {
    std.debug.assert(name.len > 0);

    const shapes = [_][]const u8{ "pub const ", "const ", "pub fn ", "fn " };
    var line_start: u32 = 0;

    while (line_start < source.len) {
        const stop = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..stop];

        for (shapes) |shape| {
            if (!std.mem.startsWith(u8, line, shape)) {
                continue;
            }

            const rest = line[shape.len..];
            const named = std.mem.startsWith(u8, rest, name) and rest.len > name.len;
            const after = if (named) rest[name.len] else 0;

            if (after == ' ' or after == '(' or after == ':') {
                return line_start;
            }
        }

        line_start = @intCast(stop + 1);
    }

    return null;
}

/// The start of the `///` lines right above `start`, or `start` itself.
fn comments_above(source: []const u8, start: u32) u32 {
    std.debug.assert(start <= source.len);

    var begin = start;

    while (begin > 0) {
        const previous_end = begin - 1;
        const newline = std.mem.lastIndexOfScalar(u8, source[0..previous_end], '\n');
        const previous_start: u32 = if (newline) |at| @intCast(at + 1) else 0;

        if (!std.mem.startsWith(u8, source[previous_start..previous_end], "///")) {
            break;
        }

        begin = previous_start;
    }

    return begin;
}

test "a declaration is cut whole, its words with it" {
    const source =
        \\const std = @import("std");
        \\
        \\/// A name of 1 to 40 characters.
        \\fn check(in: In) void {
        \\    if (in.who.len == 0) {
        \\        return;
        \\    }
        \\}
        \\
        \\pub const operation = publr.operation.define(In, Out, .{
        \\    .name = "wave",
        \\});
        \\const tiny = 1;
        \\pub const plugin = if (native)
        \\    define(.{ .a = "};" })
        \\else
        \\    define(.{});
        \\const after = 2;
    ;

    const check = "/// A name of 1 to 40 characters.\nfn check(in: In) void {\n" ++
        "    if (in.who.len == 0) {\n        return;\n    }\n}";
    const operation = "pub const operation = publr.operation.define(In, Out, .{\n" ++
        "    .name = \"wave\",\n});";
    const plugin = "pub const plugin = if (native)\n    define(.{ .a = \"};\" })\n" ++
        "else\n    define(.{});";

    try std.testing.expectEqualStrings(check, cut(source, "check").?);
    try std.testing.expectEqualStrings(operation, cut(source, "operation").?);
    try std.testing.expectEqualStrings("const tiny = 1;", cut(source, "tiny").?);
    try std.testing.expectEqualStrings(plugin, cut(source, "plugin").?);
    try std.testing.expect(cut(source, "nope") == null);
    try std.testing.expect(cut(source, "che") == null);
}
