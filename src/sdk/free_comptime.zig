//! JSON read into a value whose shape comes with the data (`free_value.zig`) at build time:
//! an operation's example, written as JSON in its doc comment, as an installed plugin's
//! module holds a `Json`. Nothing here runs in a plugin's module.
const std = @import("std");
const free_value = @import("../publr/free_value.zig");

const Kind = free_value.Kind;

/// The JSON `text` as one value's bytes.
pub fn of(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(text.len * 400 + 10_000);

        var reader: Reader = .{
            .text = text,
        };
        const bytes = reader.value(0);

        reader.skip_space();

        if (reader.at != text.len) {
            @compileError("example: unexpected text after the JSON value: " ++ text[reader.at..]);
        }

        std.debug.assert(free_value.valid(bytes));

        return bytes;
    }
}

fn word(comptime value: u32) []const u8 {
    comptime {
        var raw: [4]u8 = undefined;

        std.debug.assert(value <= std.math.maxInt(u32));
        std.mem.writeInt(u32, &raw, value, .little);

        const kept = raw;

        return &kept;
    }
}

const Reader = struct {
    text: []const u8,
    at: u32 = 0,

    fn skip_space(comptime reader: *Reader) void {
        std.debug.assert(reader.at <= reader.text.len);

        while (reader.at < reader.text.len and std.ascii.isWhitespace(reader.text[reader.at])) {
            reader.at += 1;
        }
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

    fn word_taken(comptime reader: *Reader, comptime name: []const u8) bool {
        std.debug.assert(name.len > 0);

        if (std.mem.startsWith(u8, reader.text[reader.at..], name)) {
            reader.at += name.len;
            return true;
        }

        return false;
    }

    fn value(comptime reader: *Reader, comptime depth: u32) []const u8 {
        if (depth > free_value.depth_max) {
            @compileError("example: nested too deep");
        }

        reader.skip_space();

        if (reader.word_taken("null")) {
            return &.{@backingInt(Kind.null)};
        }

        if (reader.word_taken("true")) {
            return &.{@backingInt(Kind.true)};
        }

        if (reader.word_taken("false")) {
            return &.{@backingInt(Kind.false)};
        }

        if (reader.take('"')) {
            const held = reader.string();

            return &[_]u8{@backingInt(Kind.text)} ++ word(held.len) ++ held;
        }

        if (reader.take('[')) {
            return reader.holder(.list, depth);
        }

        if (reader.take('{')) {
            return reader.holder(.map, depth);
        }

        return reader.number();
    }

    /// A list's items or a map's entries, up to its closing bracket.
    fn holder(comptime reader: *Reader, comptime kind: Kind, comptime depth: u32) []const u8 {
        const close: u8 = if (kind == .map) '}' else ']';
        var body: []const u8 = "";
        var count: u32 = 0;

        if (!reader.take(close)) {
            while (true) {
                if (kind == .map) {
                    if (!reader.take('"')) {
                        @compileError("example: expected a key in " ++ reader.text);
                    }

                    const key = reader.string();

                    if (!reader.take(':')) {
                        @compileError("example: expected `:` in " ++ reader.text);
                    }

                    body = body ++ word(key.len) ++ key;
                }

                body = body ++ reader.value(depth + 1);
                count += 1;

                if (reader.take(close)) {
                    break;
                }

                if (!reader.take(',')) {
                    @compileError("example: expected `,` in " ++ reader.text);
                }
            }
        }

        return &[_]u8{@backingInt(kind)} ++ word(body.len) ++ word(count) ++ body;
    }

    /// A text after its opening quote, its escapes read.
    fn string(comptime reader: *Reader) []const u8 {
        var out: []const u8 = "";

        while (reader.at < reader.text.len) {
            const char = reader.text[reader.at];

            reader.at += 1;

            if (char == '"') {
                return out;
            }

            if (char != '\\') {
                out = out ++ &[_]u8{char};
                continue;
            }

            const escaped = reader.text[reader.at];

            reader.at += 1;
            out = out ++ switch (escaped) {
                'n' => "\n",
                't' => "\t",
                'r' => "\r",
                'b' => "\x08",
                'f' => "\x0c",
                'u' => reader.unicode(),
                else => &[_]u8{escaped},
            };
        }

        @compileError("example: a text never ends in " ++ reader.text);
    }

    fn unicode(comptime reader: *Reader) []const u8 {
        const digits = reader.text[reader.at..][0..4];
        const point = std.fmt.parseInt(u21, digits, 16) catch
            @compileError("example: not a \\u escape in " ++ reader.text);
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(point, &buffer) catch
            @compileError("example: not a character in " ++ reader.text);
        const kept = buffer;

        reader.at += 4;

        return kept[0..len];
    }

    fn number(comptime reader: *Reader) []const u8 {
        const start = reader.at;
        var raw: [8]u8 = undefined;

        const digits = "+-.eE0123456789";

        while (reader.at < reader.text.len) : (reader.at += 1) {
            if (std.mem.indexOfScalar(u8, digits, reader.text[reader.at]) == null) {
                break;
            }
        }

        const written = reader.text[start..reader.at];

        if (std.fmt.parseInt(i64, written, 10)) |whole| {
            std.mem.writeInt(i64, &raw, whole, .little);

            const kept = raw;

            return &[_]u8{@backingInt(Kind.int)} ++ &kept;
        } else |_| {}

        const real = std.fmt.parseFloat(f64, written) catch
            @compileError("example: not JSON at `" ++ reader.text[start..] ++ "`");

        std.mem.writeInt(u64, &raw, @bitCast(real), .little);

        const kept = raw;

        return &[_]u8{@backingInt(Kind.float)} ++ &kept;
    }
};

test "an example's JSON is the same value at build time as when it is read while running" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const free_json = @import("free_json.zig");
    const text = "{ \"PLN\": 12300, \"tags\": [\"a\\\"b\", true, null, 1.5, [], {}], \"n\": -2 }";
    const built = comptime of(text);
    const read = try free_json.from_text(arena_state.allocator(), text);

    try std.testing.expectEqualSlices(u8, read.bytes, built);
}
