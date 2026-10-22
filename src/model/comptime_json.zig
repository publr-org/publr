//! An operation's example is written in its doc comment as JSON (`Example:`), and the
//! operation needs it as a typed value when it compiles: this reads plain JSON into plain
//! data (text, numbers, bools, enums, optionals, slices, structs) at comptime.
const std = @import("std");

pub const depth_max: u32 = 8;

pub fn parse(comptime Target: type, comptime text: []const u8) Target {
    comptime {
        @setEvalBranchQuota(text.len * 200 + 10_000);

        var reader: Reader = .{
            .text = text,
        };
        const value = reader.value(Target, 0);

        reader.skip_space();

        if (reader.at != text.len) {
            @compileError("example: unexpected text after the JSON value: " ++ text[reader.at..]);
        }

        return value;
    }
}

const Reader = struct {
    text: []const u8,
    at: u32 = 0,

    fn value(comptime reader: *Reader, comptime Target: type, comptime depth: u32) Target {
        if (depth > depth_max) {
            @compileError("example: nested deeper than 8");
        }

        reader.skip_space();

        // Raw JSON kept as its text (`{ text }` writing itself out as-is).
        if (comptime is_raw(Target)) {
            return .{
                .text = reader.raw(),
            };
        }

        return switch (@typeInfo(Target)) {
            .bool => reader.boolean(),
            .int => reader.number(Target),
            .float => reader.number(Target),
            .optional => |optional| if (reader.take_word("null"))
                null
            else
                reader.value(optional.child, depth),
            .@"enum" => std.meta.stringToEnum(Target, reader.string()) orelse
                @compileError("example: not one of " ++ @typeName(Target) ++ "'s values"),
            .pointer => |pointer| if (pointer.child == u8)
                reader.string()
            else
                reader.list(pointer.child, depth),
            .@"struct" => reader.object(Target, depth),
            else => @compileError("example: " ++ @typeName(Target) ++ " is not plain data"),
        };
    }

    fn object(comptime reader: *Reader, comptime Target: type, comptime depth: u32) Target {
        reader.expect('{');

        var result: Target = undefined;
        var seen = [_]bool{false} ** @typeInfo(Target).@"struct".fields.len;

        reader.skip_space();

        if (!reader.take('}')) {
            while (true) {
                const key = reader.string();

                reader.expect(':');

                const index = field_index(Target, key) orelse @compileError("example: " ++
                    @typeName(Target) ++ " has no field `" ++ key ++ "`");

                inline for (@typeInfo(Target).@"struct".fields, 0..) |field, position| {
                    if (position == index) {
                        @field(result, field.name) = reader.value(field.type, depth + 1);
                    }
                }

                seen[index] = true;
                reader.skip_space();

                if (reader.take('}')) {
                    break;
                }

                reader.expect(',');
            }
        }

        inline for (@typeInfo(Target).@"struct".fields, 0..) |field, position| {
            if (!seen[position]) {
                const default = field.defaultValue() orelse @compileError("example: " ++
                    @typeName(Target) ++ " needs `" ++ field.name ++ "`");

                @field(result, field.name) = default;
            }
        }

        const done = result;

        return done;
    }

    fn list(comptime reader: *Reader, comptime Child: type, comptime depth: u32) []const Child {
        std.debug.assert(depth <= depth_max);
        reader.expect('[');

        var items: []const Child = &.{};

        reader.skip_space();

        if (!reader.take(']')) {
            while (true) {
                items = items ++ [_]Child{reader.value(Child, depth + 1)};
                reader.skip_space();

                if (reader.take(']')) {
                    break;
                }

                reader.expect(',');
            }
        }

        return items;
    }

    /// One whole JSON value, skipped and answered as its text.
    fn raw(comptime reader: *Reader) []const u8 {
        std.debug.assert(reader.at <= reader.text.len);

        const start = reader.at;
        var depth: u32 = 0;
        var quoted = false;

        while (reader.at < reader.text.len) : (reader.at += 1) {
            const char = reader.text[reader.at];

            if (quoted) {
                if (char == '\\') {
                    reader.at += 1;
                } else if (char == '"') {
                    quoted = false;
                }

                continue;
            }

            switch (char) {
                '"' => quoted = true,
                '{', '[' => depth += 1,
                '}', ']' => {
                    if (depth == 0) {
                        break;
                    }

                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    break;
                },
                else => {},
            }

            if (depth == 0 and (char == '}' or char == ']')) {
                reader.at += 1;
                break;
            }
        }

        return std.mem.trim(u8, reader.text[start..reader.at], " \n\t");
    }

    fn string(comptime reader: *Reader) []const u8 {
        reader.skip_space();
        reader.expect('"');

        var out: []const u8 = "";

        while (reader.at < reader.text.len and reader.text[reader.at] != '"') {
            const char = reader.text[reader.at];

            reader.at += 1;

            if (char != '\\') {
                out = out ++ [_]u8{char};
                continue;
            }

            const escaped = reader.text[reader.at];

            reader.at += 1;
            out = out ++ switch (escaped) {
                'n' => "\n",
                't' => "\t",
                'r' => "\r",
                '"' => "\"",
                '\\' => "\\",
                '/' => "/",
                else => @compileError("example: unsupported escape in a string"),
            };
        }

        reader.expect('"');

        const done = out;

        return done;
    }

    fn number(comptime reader: *Reader, comptime Target: type) Target {
        reader.skip_space();

        const start = reader.at;

        while (reader.at < reader.text.len and is_number_char(reader.text[reader.at])) {
            reader.at += 1;
        }

        const digits = reader.text[start..reader.at];

        return switch (@typeInfo(Target)) {
            .int => std.fmt.parseInt(Target, digits, 10) catch
                @compileError("example: `" ++ digits ++ "` is not a whole number"),
            else => std.fmt.parseFloat(Target, digits) catch
                @compileError("example: `" ++ digits ++ "` is not a number"),
        };
    }

    fn boolean(comptime reader: *Reader) bool {
        if (reader.take_word("true")) {
            return true;
        }

        if (reader.take_word("false")) {
            return false;
        }

        @compileError("example: expected true or false");
    }

    fn take_word(comptime reader: *Reader, comptime word: []const u8) bool {
        std.debug.assert(word.len > 0);
        reader.skip_space();

        if (std.mem.startsWith(u8, reader.text[reader.at..], word)) {
            reader.at += @intCast(word.len);
            return true;
        }

        return false;
    }

    fn take(comptime reader: *Reader, comptime char: u8) bool {
        std.debug.assert(!std.ascii.isWhitespace(char));
        reader.skip_space();

        if (reader.at < reader.text.len and reader.text[reader.at] == char) {
            reader.at += 1;
            return true;
        }

        return false;
    }

    fn expect(comptime reader: *Reader, comptime char: u8) void {
        if (!reader.take(char)) {
            @compileError("example: expected `" ++ [_]u8{char} ++ "` in " ++ reader.text);
        }
    }

    fn skip_space(comptime reader: *Reader) void {
        std.debug.assert(reader.at <= reader.text.len);

        while (reader.at < reader.text.len and std.ascii.isWhitespace(reader.text[reader.at])) {
            reader.at += 1;
        }
    }
};

fn is_raw(comptime Target: type) bool {
    comptime {
        if (@typeInfo(Target) != .@"struct" or !@hasDecl(Target, "jsonStringify")) {
            return false;
        }

        const fields = @typeInfo(Target).@"struct".fields;
        const raw = fields.len == 1 and std.mem.eql(u8, fields[0].name, "text");

        std.debug.assert(!raw or fields[0].type == []const u8);

        return raw;
    }
}

fn field_index(comptime Target: type, comptime key: []const u8) ?u32 {
    comptime std.debug.assert(key.len > 0);

    inline for (@typeInfo(Target).@"struct".fields, 0..) |field, index| {
        if (comptime std.mem.eql(u8, field.name, key)) {
            return index;
        }
    }

    return null;
}

fn is_number_char(char: u8) bool {
    std.debug.assert(char != 0);

    return std.ascii.isDigit(char) or char == '-' or char == '+' or char == '.' or
        char == 'e' or char == 'E';
}

test "an example read into plain data" {
    const Kind = enum { yes, no };
    const In = struct {
        page: []const u8,
        count: u32,
        ratio: f64 = 0.5,
        kind: Kind,
        note: ?[]const u8 = null,
        tags: []const []const u8 = &.{},
        inner: struct {
            ok: bool,
        },
    };
    const value = comptime parse(In,
        \\{ "page": "/docs/\"a\"", "count": 3, "kind": "no",
        \\  "tags": ["x", "y"], "inner": { "ok": true }, "note": null }
    );

    try std.testing.expectEqualStrings("/docs/\"a\"", value.page);
    try std.testing.expectEqual(3, value.count);
    try std.testing.expectEqual(0.5, value.ratio);
    try std.testing.expectEqual(Kind.no, value.kind);
    try std.testing.expectEqual(null, value.note);
    try std.testing.expectEqual(2, value.tags.len);
    try std.testing.expect(value.inner.ok);
}
