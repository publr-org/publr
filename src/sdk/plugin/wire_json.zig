//! JSON across the sandbox's boundary, read and written in the guest at a cost close to its
//! bytes: the same text `std.json` writes and the same values it reads (unknown fields
//! skipped, defaults filled, nesting bounded), without its token-by-token scanner. A module
//! runs metered, so every instruction a call spends on its wire is budget the plugin loses;
//! strings are scanned eight bytes at a time. A type with its own `jsonParse` or
//! `jsonStringify`, a union, a tuple or an array goes through `std.json` for that value alone.
const std = @import("std");
const operation = @import("../operation.zig");
const words = @import("words.zig");

/// How deep objects and arrays may nest, as `lib/json.zig` bounds them.
pub const depth_max: u32 = 64;

pub const ParseError = error{ Invalid, OutOfMemory };

pub const ParseOptions = struct {
    /// Fields the type does not have are skipped; otherwise they refuse the text.
    ignore_unknown_fields: bool = true,
};

/// `text` read as a `Shape`, as `std.json.parseFromSliceLeaky` reads it with `.allocate =
/// .alloc_always`; strings without escapes point into `text`, which must outlive the value.
pub fn parse(
    comptime Shape: type,
    arena: std.mem.Allocator,
    text: []const u8,
    comptime options: ParseOptions,
) ParseError!Shape {
    var parser: Parser(options) = .{
        .text = text,
        .at = 0,
        .arena = arena,
        .depth = 0,
    };

    const value = try parser.value(Shape);

    parser.space();

    if (parser.at != text.len) {
        return error.Invalid;
    }

    std.debug.assert(parser.depth == 0);

    return value;
}

/// `value` written as `std.json.Stringify.valueAlloc(allocator, value, .{})` writes it.
pub fn stringify(allocator: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    write(&output.writer, value) catch return error.OutOfMemory;

    std.debug.assert(output.written().len > 0);

    return output.toOwnedSlice() catch error.OutOfMemory;
}

/// `value` written to `writer` as JSON, as `std.json.Stringify` writes it minified.
pub fn write(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const Shape = @TypeOf(value);

    std.debug.assert(writer.end <= writer.buffer.len);

    if (comptime Shape == std.json.Value) {
        return write_dynamic(writer, value);
    }

    switch (@typeInfo(Shape)) {
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .int => try writer.print("{}", .{value}),
        .null => try writer.writeAll("null"),
        .optional => if (value) |payload| {
            try write(writer, payload);
        } else {
            try writer.writeAll("null");
        },
        .@"enum" => |info| {
            if (comptime std.meta.hasFn(Shape, "jsonStringify") or info.mode == .nonexhaustive) {
                return delegate(writer, value);
            }

            try writer.writeByte('"');
            try string_chars(writer, @tagName(value));
            try writer.writeByte('"');
        },
        .enum_literal => {
            try writer.writeByte('"');
            try string_chars(writer, @tagName(value));
            try writer.writeByte('"');
        },
        .@"struct" => try write_struct(writer, value),
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => try write(writer, @as([]const std.meta.Elem(info.child), value)),
                else => try write(writer, value.*),
            },
            .slice => {
                if (info.child == u8) {
                    if (valid_utf8(value)) {
                        try writer.writeByte('"');
                        try string_chars(writer, value);
                        return writer.writeByte('"');
                    }
                }

                try writer.writeByte('[');

                for (value, 0..) |item, index| {
                    if (index > 0) {
                        try writer.writeByte(',');
                    }

                    try write(writer, item);
                }

                try writer.writeByte(']');
            },
            else => try delegate(writer, value),
        },
        else => try delegate(writer, value),
    }
}

/// A struct as an object, its fields in order; a few the SDK writes in their own way.
fn write_struct(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const Shape = @TypeOf(value);
    const info = @typeInfo(Shape).@"struct";

    if (comptime Shape == operation.Json) {
        std.debug.assert(value.text.len > 0);
        return writer.writeAll(value.text);
    }

    if (comptime Shape == words.Time) {
        std.debug.assert(value.ms >= 0);
        return writer.print("{}", .{value.ms});
    }

    if (comptime is_string_map(Shape)) {
        return write_map(writer, value.map);
    }

    if (comptime info.is_tuple or std.meta.hasFn(Shape, "jsonStringify")) {
        return delegate(writer, value);
    }

    try writer.writeByte('{');

    comptime var first = true;

    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (field_type == void) {
            continue;
        }

        const key = comptime (if (first) "" else ",") ++ quoted(field_name) ++ ":";

        first = false;
        try writer.writeAll(key);
        try write(writer, @field(value, field_name));
    }

    try writer.writeByte('}');
}

/// Whether `Shape` is `std.json.ArrayHashMap` of some value: an object keyed by text.
fn is_string_map(comptime Shape: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Shape) == .@"struct");

        if (!@hasField(Shape, "map")) {
            return false;
        }

        const Map = @FieldType(Shape, "map");

        if (@typeInfo(Map) != .@"struct" or !@hasDecl(Map, "KV")) {
            return false;
        }

        return Shape == std.json.ArrayHashMap(@FieldType(Map.KV, "value"));
    }
}

/// A map keyed by text as an object, as `std.json.ArrayHashMap` writes it.
fn write_map(writer: *std.Io.Writer, map: anytype) std.Io.Writer.Error!void {
    std.debug.assert(map.keys().len == map.values().len);

    try writer.writeByte('{');

    for (map.keys(), map.values(), 0..) |key, item, index| {
        if (index > 0) {
            try writer.writeByte(',');
        }

        try write(writer, key);
        try writer.writeByte(':');
        try write(writer, item);
    }

    try writer.writeByte('}');
}

/// A `std.json.Value` as its own `jsonStringify` writes it. Nesting is bounded by what read it.
fn write_dynamic(writer: *std.Io.Writer, value: std.json.Value) std.Io.Writer.Error!void {
    std.debug.assert(value != .array or value.array.items.len <= std.math.maxInt(u32));

    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |inner| try writer.writeAll(if (inner) "true" else "false"),
        .integer => |inner| try writer.print("{}", .{inner}),
        .float => |inner| try delegate(writer, inner),
        .number_string => |inner| try writer.writeAll(inner),
        .string => |inner| try write(writer, inner),
        .array => |inner| try write(writer, inner.items),
        .object => |inner| {
            try writer.writeByte('{');

            for (inner.keys(), inner.values(), 0..) |key, item, index| {
                if (index > 0) {
                    try writer.writeByte(',');
                }

                try write(writer, key);
                try writer.writeByte(':');
                try write_dynamic(writer, item);
            }

            try writer.writeByte('}');
        },
    }
}

/// One value through `std.json`: a fresh writer at a value's place writes no separator.
fn delegate(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var stringify_state: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    return stringify_state.write(value);
}

/// A field's name as a JSON string, at build time.
fn quoted(comptime name: []const u8) []const u8 {
    comptime std.debug.assert(name.len > 0);

    comptime {
        var out: []const u8 = "\"";

        for (name) |byte| {
            out = out ++ switch (byte) {
                '"' => "\\\"",
                '\\' => "\\\\",
                else => &[_]u8{byte},
            };
        }

        return out ++ "\"";
    }
}

const ones: u64 = 0x0101010101010101;
const highs: u64 = 0x8080808080808080;

/// The high bit of each byte of `word` below `limit` (at most 0x80) set.
inline fn below(word: u64, comptime limit: u8) u64 {
    return (word -% ones *% limit) & ~word & highs;
}

/// The high bit of each byte of `word` equal to `byte` set.
inline fn equal(word: u64, comptime byte: u8) u64 {
    return below(word ^ (ones *% byte), 1);
}

/// Bytes a JSON string must escape: control characters, `"` and `\`.
inline fn special(word: u64) u64 {
    return below(word, 0x20) | equal(word, '"') | equal(word, '\\');
}

inline fn load(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

/// Whether `bytes` is UTF-8, ASCII runs checked eight bytes at a time.
fn valid_utf8(bytes: []const u8) bool {
    std.debug.assert(bytes.len <= std.math.maxInt(u32));

    var at: usize = 0;

    while (at < bytes.len) {
        if (at + 8 <= bytes.len and load(bytes[at..]) & highs == 0) {
            at += 8;
            continue;
        }

        if (bytes[at] < 0x80) {
            at += 1;
            continue;
        }

        const length = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return false;

        if (at + length > bytes.len) {
            return false;
        }

        _ = std.unicode.utf8Decode(bytes[at..][0..length]) catch return false;
        at += length;
    }

    return at == bytes.len;
}

/// A string's characters escaped as `std.json` escapes them, into the writer's own buffer a
/// piece at a time: runs without escapes are copied whole.
fn string_chars(writer: *std.Io.Writer, chars: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;

    while (start < chars.len) {
        const piece = chars[start..@min(chars.len, start + piece_bytes)];
        const into = try writer.writableSliceGreedy(piece.len * escape_bytes_max);
        const written = escape_piece(into, piece);

        std.debug.assert(written >= piece.len);

        writer.advance(written);
        start += piece.len;
    }
}

const piece_bytes: u32 = 1024;
/// The most one byte becomes: `\u001f`.
const escape_bytes_max: u32 = 6;

/// `piece` escaped into `into`, which holds six bytes for each: how many it wrote.
fn escape_piece(into: []u8, piece: []const u8) u32 {
    std.debug.assert(into.len >= piece.len * escape_bytes_max);

    var at: usize = 0;
    var run: usize = 0;
    var written: usize = 0;

    while (at < piece.len) {
        if (at + 8 <= piece.len) {
            const found = special(load(piece[at..]));

            if (found == 0) {
                at += 8;
                continue;
            }

            at += @ctz(found) / 8;
        } else if (!needs_escape(piece[at])) {
            at += 1;
            continue;
        }

        @memcpy(into[written..][0 .. at - run], piece[run..at]);
        written += at - run;
        written += escape_into(into[written..], piece[at]);
        at += 1;
        run = at;
    }

    @memcpy(into[written..][0 .. piece.len - run], piece[run..]);

    return @intCast(written + piece.len - run);
}

/// How many times `needle` is in `text`, its first byte looked for eight at a time.
pub fn occurrences(text: []const u8, comptime needle: []const u8) u32 {
    comptime std.debug.assert(needle.len > 0);

    var count: u32 = 0;
    var at: usize = 0;

    while (at < text.len) {
        if (at + 8 <= text.len and equal(load(text[at..]), needle[0]) == 0) {
            at += 8;
            continue;
        }

        if (std.mem.startsWith(u8, text[at..], needle)) {
            count += 1;
            at += needle.len;
            continue;
        }

        at += 1;
    }

    std.debug.assert(count <= text.len);

    return count;
}

/// Whether `text` holds white space anywhere, strings included.
fn has_space(text: []const u8) bool {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    var at: usize = 0;

    while (at + 8 <= text.len) : (at += 8) {
        const word = load(text[at..]);

        if (equal(word, ' ') | below(word, 0x0e) != 0) {
            return true;
        }
    }

    while (at < text.len) : (at += 1) {
        if (text[at] == ' ' or text[at] < 0x0e) {
            return true;
        }
    }

    return false;
}

inline fn needs_escape(byte: u8) bool {
    return byte < 0x20 or byte == '"' or byte == '\\';
}

/// One byte JSON must escape, written at the start of `into`: how many bytes it took.
fn escape_into(into: []u8, byte: u8) u32 {
    std.debug.assert(needs_escape(byte));
    std.debug.assert(into.len >= escape_bytes_max);

    const short: u8 = switch (byte) {
        '\\' => '\\',
        '"' => '"',
        0x08 => 'b',
        0x0C => 'f',
        '\n' => 'n',
        '\r' => 'r',
        '\t' => 't',
        else => {
            const hex = "0123456789abcdef";

            into[0..6].* = .{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf] };
            return 6;
        },
    };

    into[0..2].* = .{ '\\', short };
    return 2;
}

/// Whether `text` is a JSON number: `-`, digits without a leading zero, a fraction, an exponent.
fn valid_number(text: []const u8) bool {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    var at: usize = 0;

    if (at < text.len and text[at] == '-') {
        at += 1;
    }

    const whole = at + digits_in(text[at..]);

    if (whole == at or (text[at] == '0' and whole > at + 1)) {
        return false;
    }

    at = whole;

    if (at < text.len and text[at] == '.') {
        const fraction = at + 1 + digits_in(text[at + 1 ..]);

        if (fraction == at + 1) {
            return false;
        }

        at = fraction;
    }

    if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
        at += 1;

        if (at < text.len and (text[at] == '+' or text[at] == '-')) {
            at += 1;
        }

        const exponent = at + digits_in(text[at..]);

        if (exponent == at) {
            return false;
        }

        at = exponent;
    }

    return at == text.len;
}

/// How many digits `text` starts with.
fn digits_in(text: []const u8) u32 {
    var count: u32 = 0;

    while (count < text.len and std.ascii.isDigit(text[count])) {
        count += 1;
    }

    std.debug.assert(count <= text.len);

    return count;
}

fn Parser(comptime options: ParseOptions) type {
    return struct {
        text: []const u8,
        at: u32,
        arena: std.mem.Allocator,
        depth: u32,

        const Self = @This();

        fn space(self: *Self) void {
            std.debug.assert(self.at <= self.text.len);

            while (self.at < self.text.len) : (self.at += 1) {
                switch (self.text[self.at]) {
                    ' ', '\t', '\n', '\r' => {},
                    else => return,
                }
            }
        }

        /// The next byte that is not white space, not taken.
        fn peek(self: *Self) ParseError!u8 {
            std.debug.assert(self.depth <= depth_max);

            self.space();

            if (self.at >= self.text.len) {
                return error.Invalid;
            }

            return self.text[self.at];
        }

        fn expect(self: *Self, byte: u8) ParseError!void {
            if (try self.peek() != byte) {
                return error.Invalid;
            }

            self.at += 1;
        }

        fn literal(self: *Self, comptime word: []const u8) ParseError!void {
            if (!std.mem.startsWith(u8, self.text[self.at..], word)) {
                return error.Invalid;
            }

            self.at += word.len;
        }

        fn enter(self: *Self) ParseError!void {
            if (self.depth == depth_max) {
                return error.Invalid;
            }

            self.depth += 1;
        }

        fn leave(self: *Self) void {
            std.debug.assert(self.depth > 0);

            self.depth -= 1;
        }

        fn value(self: *Self, comptime Shape: type) ParseError!Shape {
            std.debug.assert(self.depth <= depth_max);

            if (comptime Shape == std.json.Value) {
                return self.dynamic();
            }

            switch (@typeInfo(Shape)) {
                .bool => {
                    const byte = try self.peek();

                    if (byte == 't') {
                        try self.literal("true");
                        return true;
                    }

                    try self.literal("false");
                    return false;
                },
                .int => return self.int(Shape),
                .float => {
                    const slice = try self.number_or_string();

                    return std.fmt.parseFloat(Shape, slice) catch error.Invalid;
                },
                .optional => |info| {
                    if (try self.peek() == 'n') {
                        try self.literal("null");
                        return null;
                    }

                    return try self.value(info.child);
                },
                .@"enum" => {
                    if (comptime std.meta.hasFn(Shape, "jsonParse")) {
                        return self.delegated(Shape);
                    }

                    const slice = try self.number_or_string();

                    if (std.meta.stringToEnum(Shape, slice)) |tag| {
                        return tag;
                    }

                    const Tag = @typeInfo(Shape).@"enum".tag_type;
                    const number = std.fmt.parseInt(Tag, slice, 10) catch {
                        return error.Invalid;
                    };

                    return std.enums.fromInt(Shape, number) orelse error.Invalid;
                },
                .@"struct" => |info| {
                    if (comptime Shape == operation.Json) {
                        return self.raw();
                    }

                    if (comptime Shape == words.Time) {
                        return .{
                            .ms = try self.int(i64),
                        };
                    }

                    if (comptime is_string_map(Shape)) {
                        return .{
                            .map = try self.map(@FieldType(Shape, "map")),
                        };
                    }

                    if (comptime info.is_tuple or std.meta.hasFn(Shape, "jsonParse")) {
                        return self.delegated(Shape);
                    }

                    return self.object(Shape);
                },
                .pointer => return self.pointer_value(Shape),
                else => return self.delegated(Shape),
            }
        }

        /// Any value, as `std.json.Value` reads it: an integer when written as one and it fits,
        /// a float otherwise, the text of a number neither holds.
        fn dynamic(self: *Self) ParseError!std.json.Value {
            std.debug.assert(self.depth <= depth_max);

            switch (try self.peek()) {
                '"' => return .{
                    .string = try self.string(),
                },
                '{' => return self.dynamic_object(),
                '[' => {
                    self.at += 1;
                    try self.enter();

                    var items: std.json.Array = .init(self.arena);

                    if (try self.peek() == ']') {
                        self.at += 1;
                    } else {
                        while (true) {
                            items.append(try self.dynamic()) catch return error.OutOfMemory;

                            if (try self.closes(']')) {
                                break;
                            }
                        }
                    }

                    self.leave();

                    return .{
                        .array = items,
                    };
                },
                't' => {
                    try self.literal("true");
                    return .{
                        .bool = true,
                    };
                },
                'f' => {
                    try self.literal("false");
                    return .{
                        .bool = false,
                    };
                },
                'n' => {
                    try self.literal("null");
                    return .null;
                },
                else => {
                    const slice = try self.number_or_string();

                    if (!valid_number(slice)) {
                        return error.Invalid;
                    }

                    return std.json.Value.parseFromNumberSlice(slice);
                },
            }
        }

        fn dynamic_object(self: *Self) ParseError!std.json.Value {
            std.debug.assert(self.text[self.at] == '{');

            var fields: std.json.ObjectMap = .empty;

            self.at += 1;
            try self.enter();

            if (try self.peek() == '}') {
                self.at += 1;
            } else {
                while (true) {
                    if (try self.peek() != '"') {
                        return error.Invalid;
                    }

                    const key = try self.string();

                    try self.expect(':');

                    const entry = fields.getOrPut(self.arena, key) catch return error.OutOfMemory;

                    // As `std.json` reads it: a field twice refuses the text.
                    if (entry.found_existing) {
                        return error.Invalid;
                    }

                    entry.value_ptr.* = try self.dynamic();

                    if (try self.closes('}')) {
                        break;
                    }
                }
            }

            self.leave();

            return .{
                .object = fields,
            };
        }

        /// After an item: true at the closing byte, false at a comma, both taken.
        fn closes(self: *Self, close: u8) ParseError!bool {
            std.debug.assert(close == ']' or close == '}');

            const next = try self.peek();

            self.at += 1;

            if (next == close) {
                return true;
            }

            if (next != ',') {
                return error.Invalid;
            }

            return false;
        }

        /// An object keyed by text into `Map`, as `std.json.ArrayHashMap` reads it.
        fn map(self: *Self, comptime Map: type) ParseError!Map {
            const Item = @FieldType(Map.KV, "value");
            var fields: Map = .empty;

            std.debug.assert(self.depth <= depth_max);

            try self.expect('{');
            try self.enter();

            if (try self.peek() == '}') {
                self.at += 1;
            } else {
                while (true) {
                    if (try self.peek() != '"') {
                        return error.Invalid;
                    }

                    const key = try self.string();

                    try self.expect(':');

                    const entry = fields.getOrPut(self.arena, key) catch return error.OutOfMemory;

                    if (entry.found_existing) {
                        return error.Invalid;
                    }

                    entry.value_ptr.* = try self.value(Item);

                    if (try self.closes('}')) {
                        break;
                    }
                }
            }

            self.leave();

            return fields;
        }

        fn pointer_value(self: *Self, comptime Shape: type) ParseError!Shape {
            const info = @typeInfo(Shape).pointer;

            std.debug.assert(self.depth <= depth_max);

            if (info.size == .one) {
                const one = try self.arena.create(info.child);

                one.* = try self.value(info.child);
                return one;
            }

            if (info.size != .slice or info.sentinel() != null) {
                return self.delegated(Shape);
            }

            if (info.child == u8 and try self.peek() == '"') {
                const slice = try self.string();

                if (info.attrs.@"const") {
                    return slice;
                }

                return self.arena.dupe(u8, slice) catch error.OutOfMemory;
            }

            return self.array(info.child);
        }

        fn int(self: *Self, comptime Shape: type) ParseError!Shape {
            comptime std.debug.assert(@typeInfo(Shape) == .int);

            const slice = try self.number_or_string();

            if (std.fmt.parseInt(Shape, slice, 10)) |number| {
                return number;
            } else |_| {}

            // A number written as a float holds an integer only when it is a whole one.
            const float = std.fmt.parseFloat(f128, slice) catch return error.Invalid;

            if (@round(float) != float) {
                return error.Invalid;
            }

            const too_big = float > @as(f128, @floatFromInt(std.math.maxInt(Shape)));
            const too_small = float < @as(f128, @floatFromInt(std.math.minInt(Shape)));

            if (too_big or too_small) {
                return error.Invalid;
            }

            return @intFromFloat(float);
        }

        /// A number's text, or a string's, as `std.json` reads either into a number.
        fn number_or_string(self: *Self) ParseError![]const u8 {
            std.debug.assert(self.at <= self.text.len);

            const byte = try self.peek();

            if (byte == '"') {
                return self.string();
            }

            const start = self.at;

            while (self.at < self.text.len) : (self.at += 1) {
                switch (self.text[self.at]) {
                    '0'...'9', '-', '+', '.', 'e', 'E' => {},
                    else => break,
                }
            }

            if (self.at == start) {
                return error.Invalid;
            }

            return self.text[start..self.at];
        }

        /// A string's characters, unescaped: a slice of the text when it has no escapes.
        fn string(self: *Self) ParseError![]const u8 {
            std.debug.assert(self.text[self.at] == '"');

            self.at += 1;

            const start = self.at;
            const text = self.text;
            var high: u64 = 0;

            while (true) {
                if (self.at + 8 <= text.len) {
                    const word = load(text[self.at..]);
                    const found = special(word);

                    if (found == 0) {
                        high |= word & highs;
                        self.at += 8;
                        continue;
                    }

                    const skipped = @ctz(found) / 8;

                    high |= word & highs & ((@as(u64, 1) << @intCast(skipped * 8)) -% 1);
                    self.at += skipped;
                }

                if (self.at >= text.len) {
                    return error.Invalid;
                }

                const byte = text[self.at];

                if (byte == '"') {
                    const slice = text[start..self.at];

                    self.at += 1;

                    if (high != 0 and !valid_utf8(slice)) {
                        return error.Invalid;
                    }

                    return slice;
                }

                if (byte == '\\') {
                    return self.escaped(start);
                }

                if (byte < 0x20) {
                    return error.Invalid;
                }

                high |= byte & 0x80;
                self.at += 1;
            }
        }

        /// The rest of a string that has escapes, from `start`: its end found first, then
        /// unescaped into exactly as many bytes, runs between escapes copied whole.
        fn escaped(self: *Self, start: u32) ParseError![]const u8 {
            std.debug.assert(start > 0);

            const text = self.text;
            const first = self.at;

            self.at = start - 1;
            try self.skip_string();

            const end = self.at - 1;
            const out = self.arena.alloc(u8, end - start) catch return error.OutOfMemory;
            var written = first - start;

            @memcpy(out[0..written], text[start..first]);
            self.at = first;

            while (self.at < end) {
                const run = self.at;

                while (self.at + 8 <= end and equal(load(text[self.at..]), '\\') == 0) {
                    self.at += 8;
                }

                while (self.at < end and text[self.at] != '\\') {
                    self.at += 1;
                }

                @memcpy(out[written..][0 .. self.at - run], text[run..self.at]);
                written += self.at - run;

                if (self.at < end) {
                    self.at += 1;
                    written += try self.unescape_one(out[written..]);
                }
            }

            if (self.at != end) {
                return error.Invalid;
            }

            self.at = end + 1;

            if (!valid_utf8(out[0..written])) {
                return error.Invalid;
            }

            return out[0..written];
        }

        /// The escape after a `\`, written at the start of `out`: how many bytes it took.
        fn unescape_one(self: *Self, out: []u8) ParseError!u32 {
            std.debug.assert(self.at > 0 and self.text[self.at - 1] == '\\');

            const text = self.text;

            if (self.at >= text.len or out.len == 0) {
                return error.Invalid;
            }

            const kind = text[self.at];

            self.at += 1;

            out[0] = switch (kind) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0C,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => return self.unescape_code(out),
                else => return error.Invalid,
            };

            return 1;
        }

        /// A `\u` escape, a surrogate pair's two included, as UTF-8 at the start of `out`.
        fn unescape_code(self: *Self, out: []u8) ParseError!u32 {
            std.debug.assert(out.len > 0);

            var codepoint: u21 = try self.hex4();

            if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                try self.literal("\\u");

                const low = try self.hex4();

                if (low < 0xDC00 or low > 0xDFFF) {
                    return error.Invalid;
                }

                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
            } else if (codepoint >= 0xDC00 and codepoint <= 0xDFFF) {
                return error.Invalid;
            }

            const length = std.unicode.utf8CodepointSequenceLength(codepoint) catch {
                return error.Invalid;
            };

            if (length > out.len) {
                return error.Invalid;
            }

            return std.unicode.utf8Encode(codepoint, out) catch error.Invalid;
        }

        fn hex4(self: *Self) ParseError!u21 {
            std.debug.assert(self.at <= self.text.len);

            if (self.at + 4 > self.text.len) {
                return error.Invalid;
            }

            const digits = self.text[self.at..][0..4];

            self.at += 4;

            return std.fmt.parseInt(u16, digits, 16) catch error.Invalid;
        }

        fn object(self: *Self, comptime Shape: type) ParseError!Shape {
            std.debug.assert(self.depth <= depth_max);

            const info = @typeInfo(Shape).@"struct";
            var result: Shape = undefined;
            var seen: [info.field_names.len]bool = @splat(false);

            try self.expect('{');
            try self.enter();

            if (try self.peek() == '}') {
                self.at += 1;
            } else {
                while (true) {
                    if (try self.peek() != '"') {
                        return error.Invalid;
                    }

                    const key = try self.string();

                    try self.expect(':');

                    const names = info.field_names;
                    const matched = inline for (names, info.field_types, 0..) |name, Field, index| {
                        if (key.len == name.len and std.mem.eql(u8, key, name)) {
                            @field(result, name) = try self.value(Field);
                            seen[index] = true;
                            break true;
                        }
                    } else false;

                    if (!matched) {
                        if (!options.ignore_unknown_fields) {
                            return error.Invalid;
                        }

                        self.space();
                        try self.skip();
                    }

                    const next = try self.peek();

                    self.at += 1;

                    if (next == '}') {
                        break;
                    }

                    if (next != ',') {
                        return error.Invalid;
                    }
                }
            }

            self.leave();

            const attributes = info.field_attrs;

            const types = info.field_types;

            inline for (info.field_names, types, attributes, 0..) |name, Field, attrs, index| {
                if (!seen[index]) {
                    @field(result, name) = attrs.defaultValue(Field) orelse return error.Invalid;
                }
            }

            return result;
        }

        fn array(self: *Self, comptime Item: type) ParseError![]Item {
            std.debug.assert(self.depth <= depth_max);

            var items: std.ArrayList(Item) = .empty;

            try self.expect('[');
            try self.enter();

            if (try self.peek() == ']') {
                self.at += 1;
            } else {
                while (true) {
                    const item = try self.value(Item);

                    items.append(self.arena, item) catch return error.OutOfMemory;

                    const next = try self.peek();

                    self.at += 1;

                    if (next == ']') {
                        break;
                    }

                    if (next != ',') {
                        return error.Invalid;
                    }
                }
            }

            self.leave();

            return items.toOwnedSlice(self.arena) catch error.OutOfMemory;
        }

        /// JSON kept as it came (`operation.Json`): the text itself when it is minified, as
        /// the host writes it; otherwise written again as `std.json` writes it.
        fn raw(self: *Self) ParseError!operation.Json {
            self.space();

            const start = self.at;

            try self.skip();

            const text = self.text[start..self.at];

            std.debug.assert(text.len > 0);

            if (has_space(text)) {
                const reread = try Self.parse_slice(std.json.Value, self.arena, text);

                return .{
                    .text = stringify(self.arena, reread) catch return error.OutOfMemory,
                };
            }

            return .{
                .text = text,
            };
        }

        /// One value read by `std.json`, its text found first, nesting bounded as here.
        fn delegated(self: *Self, comptime Shape: type) ParseError!Shape {
            std.debug.assert(self.depth <= depth_max);

            self.space();

            const start = self.at;

            try self.skip();

            return Self.parse_slice(Shape, self.arena, self.text[start..self.at]);
        }

        fn parse_slice(
            comptime Shape: type,
            arena: std.mem.Allocator,
            text: []const u8,
        ) ParseError!Shape {
            std.debug.assert(text.len > 0);

            return std.json.parseFromSliceLeaky(Shape, arena, text, .{
                .ignore_unknown_fields = options.ignore_unknown_fields,
                .allocate = .alloc_always,
            }) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Invalid,
            };
        }

        /// Steps over one value, checking its form loosely: what reads it checks the rest.
        fn skip(self: *Self) ParseError!void {
            std.debug.assert(self.depth <= depth_max);

            const byte = try self.peek();

            switch (byte) {
                '"' => _ = try self.skip_string(),
                '{', '[' => {
                    const close: u8 = if (byte == '{') '}' else ']';

                    self.at += 1;
                    try self.enter();

                    if (try self.peek() == close) {
                        self.at += 1;
                    } else {
                        while (true) {
                            if (byte == '{') {
                                if (try self.peek() != '"') {
                                    return error.Invalid;
                                }

                                try self.skip_string();
                                try self.expect(':');
                            }

                            try self.skip();

                            const next = try self.peek();

                            self.at += 1;

                            if (next == close) {
                                break;
                            }

                            if (next != ',') {
                                return error.Invalid;
                            }
                        }
                    }

                    self.leave();
                },
                't' => try self.literal("true"),
                'f' => try self.literal("false"),
                'n' => try self.literal("null"),
                else => _ = try self.number_or_string(),
            }
        }

        fn skip_string(self: *Self) ParseError!void {
            const text = self.text;

            std.debug.assert(text[self.at] == '"');

            self.at += 1;

            while (true) {
                while (self.at + 8 <= text.len and special(load(text[self.at..])) == 0) {
                    self.at += 8;
                }

                if (self.at >= text.len) {
                    return error.Invalid;
                }

                const byte = text[self.at];

                self.at += 1;

                switch (byte) {
                    '"' => return,
                    '\\' => self.at += 1,
                    else => if (byte < 0x20) return error.Invalid,
                }
            }
        }
    };
}

const testing = std.testing;

const Sample = struct {
    name: []const u8,
    count: i64 = 7,
    ratio: f64 = 0.5,
    on: bool = false,
    maybe: ?[]const u8 = null,
    kind: enum { one, two } = .one,
    tags: []const []const u8 = &.{},
    nested: ?*const Sample = null,
    money: operation.Json = .{
        .text = "{}",
    },
    prices: std.json.ArrayHashMap(i64) = .{},
    at: words.Time = .{
        .ms = 0,
    },
    choice: union(enum) {
        amount: u32,
        blank: void,
    } = .{
        .blank = {},
    },
    pair: struct {
        u8,
        bool,
    } = .{ 1, true },
};

fn same_as_std(comptime Shape: type, text: []const u8) !void {
    std.debug.assert(text.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fast = try parse(Shape, arena, text, .{});
    const slow = try std.json.parseFromSliceLeaky(Shape, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const fast_text = try stringify(arena, fast);
    const slow_text = try std.json.Stringify.valueAlloc(arena, slow, .{});

    try testing.expectEqualStrings(slow_text, fast_text);
}

test "reads what std.json reads and writes what it writes" {
    try same_as_std(Sample, "{\"name\":\"plain\"}");
    try same_as_std(Sample,
        \\ { "name" : "esc \" \\ \/ \b\f\n\r\t é 😀 zł and more than eight",
        \\   "count": "12", "ratio": 1.25e2, "on": true, "maybe": null, "kind": "two",
        \\   "tags": ["a", "b\u0001c", ""], "unknown": {"deep": [1, 2, {"x": null}]},
        \\   "nested": {"name": "inner", "count": 3.0}, "money": {"PLN": 12300},
        \\   "prices": {"PLN": 5, "EUR": -1},
        \\   "at": 1700000000000, "choice": {"amount": 4}, "pair": [9, false] }
    );
    try same_as_std([]const Sample, "[{\"name\":\"a\"},{\"name\":\"b\",\"count\":-3}]");
    try same_as_std(?u32, "null");
    try same_as_std(std.json.Value, "{\"a\":[1,2.5,\"x\",true,null]}");
}

test "refuses what std.json refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = [_][]const u8{
        "{}",
        "{\"name\":\"x\"",
        "{\"name\":\"x\"} trailing",
        "{\"name\":\"bad \x01 byte\"}",
        "{\"name\":\"\xff\"}",
        "{\"name\":\"x\",\"count\":1.5}",
        "{\"name\":\"x\",\"kind\":\"three\"}",
        "{\"name\":\"x\",\"on\":tru}",
    };

    for (bad) |text| {
        try testing.expectError(error.Invalid, parse(Sample, arena, text, .{}));
    }

    try testing.expectError(error.Invalid, parse(Sample, arena, "{\"name\":\"x\",\"y\":1}", .{
        .ignore_unknown_fields = false,
    }));

    const opening: [depth_max + 1]u8 = @splat('[');
    const closing: [depth_max + 1]u8 = @splat(']');
    const deep = opening ++ closing;

    try testing.expectError(error.Invalid, parse([]const std.json.Value, arena, &deep, .{}));
}

test "strings of every length escape as std.json escapes them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = "ab\"c\\d\ne\x01fghijklmnopqrstuvwxyzź\"\"0123456789";

    for (0..source.len) |start| {
        for (start..source.len + 1) |end| {
            const piece = source[start..end];

            try testing.expectEqual(std.unicode.utf8ValidateSlice(piece), valid_utf8(piece));
            const fast = try stringify(arena, piece);
            const slow = try std.json.Stringify.valueAlloc(arena, piece, .{});

            try testing.expectEqualStrings(slow, fast);

            if (std.unicode.utf8ValidateSlice(piece)) {
                try testing.expectEqualStrings(piece, try parse([]const u8, arena, fast, .{}));
            }
        }
    }
}

test "UTF-8 is checked as std.unicode checks it" {
    const samples = [_][]const u8{
        "plain ascii, long enough for words",
        "\xed\xa0\x80 surrogate half",
        "\xc0\xaf overlong",
        "\xf4\x90\x80\x80 past the last code point",
        "żółć \xf0\x9f\x98\x80 and \xe2\x82\xac",
        "cut \xe2\x82",
        "\x80 lone continuation",
    };

    for (samples) |sample| {
        try testing.expectEqual(std.unicode.utf8ValidateSlice(sample), valid_utf8(sample));
    }
}

test "occurrences counts a needle anywhere" {
    try testing.expectEqual(@as(u32, 0), occurrences("", "\\u001b"));
    try testing.expectEqual(@as(u32, 2), occurrences("a\\u001b0\\u001b and more text", "\\u001b"));
    try testing.expectEqual(@as(u32, 1), occurrences("0123456789abcdef\\u001b", "\\u001b"));
    try testing.expectEqual(@as(u32, 0), occurrences("\\u001 \\\\", "\\u001b"));
}

test "any value reads and writes as std.json.Value does" {
    try same_as_std(std.json.Value,
        \\{"a":[1,-2.5,"x\n",true,null,{"b":{}}],"big":123456789012345678901234567890,
        \\ "e":1e3,"neg":-0,"z":0.1,"s":"zł \u00e9"}
    );
    try same_as_std([]const std.json.Value, "[[],{},\"\",0]");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = [_][]const u8{ "01", "1.", "-", "1e", "+1", "{\"a\":1,\"a\":2}", "[1,]" };

    for (bad) |text| {
        try testing.expectError(error.Invalid, parse(std.json.Value, arena, text, .{}));
    }
}
