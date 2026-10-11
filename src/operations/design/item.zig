//! One moodboard card as JSON, the way the block editor's board and the card's record both
//! write it: its id, kind, place and size, and what its kind shows, the rest left out.

const std = @import("std");

/// The card's own text fields, by their JSON names, the same as the record's fields.
const texts = [_][]const u8{
    "note", "text",   "url",  "src",       "value",  "title",
    "alt",  "family", "file", "thumbnail", "status", "error",
};

const lists = [_][]const u8{ "colors", "fonts" };

/// A font card's own numbers: its weight, and a variable font's heaviest.
const numbers = [_][]const u8{ "weight", "weight_max" };
const flags = [_][]const u8{"italic"};

pub const Item = struct {
    /// The card's record id; a new card carries the editor's own until it is saved.
    id: []const u8 = "",
    kind: []const u8,
    /// Where it sits on the board and how wide it is (`x`, `y`, `w`), and its height (`h`)
    /// when it has one of its own.
    across: f64 = 0,
    down: f64 = 0,
    width: f64 = 0,
    height: ?f64 = null,
    note: ?[]const u8 = null,
    text: ?[]const u8 = null,
    url: ?[]const u8 = null,
    src: ?[]const u8 = null,
    value: ?[]const u8 = null,
    title: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    family: ?[]const u8 = null,
    file: ?[]const u8 = null,
    thumbnail: ?[]const u8 = null,
    status: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    colors: ?[]const []const u8 = null,
    fonts: ?[]const []const u8 = null,
    weight: ?f64 = null,
    weight_max: ?f64 = null,
    italic: ?bool = null,

    pub fn jsonStringify(item: Item, json: anytype) !void {
        std.debug.assert(item.kind.len > 0);

        try json.beginObject();

        if (item.id.len > 0) {
            try json.objectField("id");
            try json.write(item.id);
        }

        try json.objectField("kind");
        try json.write(item.kind);
        try json.objectField("x");
        try json.write(item.across);
        try json.objectField("y");
        try json.write(item.down);
        try json.objectField("w");
        try json.write(item.width);

        if (item.height) |height| {
            try json.objectField("h");
            try json.write(height);
        }

        inline for (texts ++ lists ++ numbers ++ flags) |name| {
            if (@field(item, name)) |held| {
                try json.objectField(name);
                try json.write(held);
            }
        }

        try json.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Item {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);

        return jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Item {
        _ = options;

        if (source != .object) {
            return error.UnexpectedToken;
        }

        var item: Item = .{
            .kind = "",
        };
        var entries = source.object.iterator();

        while (entries.next()) |entry| {
            try read_entry(allocator, &item, entry.key_ptr.*, entry.value_ptr.*);
        }

        if (item.kind.len == 0) {
            return error.MissingField;
        }

        std.debug.assert(item.kind.len > 0);

        return item;
    }
};

fn read_entry(
    allocator: std.mem.Allocator,
    item: *Item,
    key: []const u8,
    value: std.json.Value,
) std.json.ParseFromValueError!void {
    std.debug.assert(key.len <= 1 << 20);

    if (std.mem.eql(u8, key, "id")) {
        item.id = try text_of(value);
    } else if (std.mem.eql(u8, key, "kind")) {
        item.kind = try text_of(value);
    } else if (std.mem.eql(u8, key, "x")) {
        item.across = try number_of(value);
    } else if (std.mem.eql(u8, key, "y")) {
        item.down = try number_of(value);
    } else if (std.mem.eql(u8, key, "w")) {
        item.width = try number_of(value);
    } else if (std.mem.eql(u8, key, "h")) {
        item.height = if (value == .null) null else try number_of(value);
    } else {
        try read_named(allocator, item, key, value);
    }
}

/// A text or a list field by its name; null and a name the card does not know are nothing.
fn read_named(
    allocator: std.mem.Allocator,
    item: *Item,
    key: []const u8,
    value: std.json.Value,
) std.json.ParseFromValueError!void {
    std.debug.assert(key.len <= 1 << 20);

    if (value == .null) {
        return;
    }

    inline for (texts) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(item, name) = try text_of(value);
        }
    }

    inline for (lists) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(item, name) = try list_of(allocator, value);
        }
    }

    inline for (numbers) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(item, name) = try number_of(value);
        }
    }

    if (std.mem.eql(u8, key, "italic")) {
        item.italic = try flag_of(value);
    }
}

fn flag_of(value: std.json.Value) error{UnexpectedToken}!bool {
    if (value != .bool) {
        return error.UnexpectedToken;
    }

    std.debug.assert(value != .null);

    return value.bool;
}

fn text_of(value: std.json.Value) error{UnexpectedToken}![]const u8 {
    if (value != .string) {
        return error.UnexpectedToken;
    }

    std.debug.assert(value.string.len < 1 << 31);

    return value.string;
}

fn number_of(value: std.json.Value) error{ UnexpectedToken, InvalidNumber }!f64 {
    const number: f64 = switch (value) {
        .integer => |whole| @floatFromInt(whole),
        .float => |fraction| fraction,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return error.InvalidNumber,
        else => return error.UnexpectedToken,
    };

    std.debug.assert(value != .string);

    return number;
}

fn list_of(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) std.json.ParseFromValueError![]const []const u8 {
    std.debug.assert(value != .null);

    if (value != .array) {
        return error.UnexpectedToken;
    }

    const out = try allocator.alloc([]const u8, value.array.items.len);

    for (value.array.items, out) |entry, *text| {
        text.* = try text_of(entry);
    }

    return out;
}

test "a card reads and writes the editor's JSON, what it lacks left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"id":"m_1","kind":"figma","x":32,"y":40.5,"w":280,"h":null,
        \\ "url":"https://figma.com/design/a","colors":["#000","#fff"],"error":null,"extra":1}
    ;
    const item = try std.json.parseFromSliceLeaky(Item, arena, text, .{});

    try std.testing.expectEqual(@as(f64, 40.5), item.down);
    try std.testing.expect(item.height == null and item.@"error" == null);
    try std.testing.expectEqualStrings("#fff", item.colors.?[1]);

    const written = try std.json.Stringify.valueAlloc(arena, item, .{});

    try std.testing.expect(std.mem.indexOf(u8, written, "\"x\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "null") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "extra") == null);
    try std.testing.expectError(error.MissingField, std.json.parseFromSliceLeaky(
        Item,
        arena,
        "{\"x\":1}",
        .{},
    ));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(
        Item,
        arena,
        "{\"kind\":\"note\",\"x\":\"far\"}",
        .{},
    ));
}

test "a font card keeps its weight, a variable font's range and its italic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"kind":"font","x":0,"y":0,"w":300,"src":"/media/a.woff2","family":"Inter",
        \\ "weight":100,"weight_max":900,"italic":true}
    ;
    const item = try std.json.parseFromSliceLeaky(Item, arena, text, .{});

    try std.testing.expectEqual(@as(f64, 900), item.weight_max.?);
    try std.testing.expect(item.italic.?);

    const written = try std.json.Stringify.valueAlloc(arena, item, .{});

    try std.testing.expect(std.mem.indexOf(u8, written, "\"weight\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"italic\":true") != null);
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(
        Item,
        arena,
        "{\"kind\":\"font\",\"italic\":\"yes\"}",
        .{},
    ));
}
