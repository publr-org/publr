//! A field's default value: kept as text on the definition, read as the value its kind
//! stores, and put into a new document wherever the field was left out.
const std = @import("std");
const field = @import("field.zig");
const kinds = @import("kinds.zig");
const time = @import("../lib/time.zig");

const Def = field.Def;
const Kind = kinds.Kind;
const Value = std.json.Value;

pub const default_len_max: u32 = 64 << 10;

/// A date and time default of `now` is the moment the record is created.
pub const now_text = "now";

/// The default as a document value, or null when the field has none or its text does
/// not read as a value of the kind. `now_ms` is what a `now` default reads as.
pub fn value_of(kind: Kind, def: Def, now_ms: i64) ?Value {
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind));
    std.debug.assert(def.default.len <= default_len_max);

    const text = def.default;

    if (text.len == 0 or !kind.default_allowed) {
        return null;
    }

    if (kind.control == .datetime and std.mem.eql(u8, text, now_text)) {
        return .{ .integer = now_ms };
    }

    return switch (kind.storage) {
        .text, .long => .{ .string = text },
        .bool => parse_bool(text),
        .int => if (kind.control == .datetime) parse_datetime(text) else parse_integer(text),
        .real => parse_number(text),
        .ref, .none => null,
    };
}

/// Whether the default text reads as a value of the kind; an empty default always does.
pub fn fits(kind: Kind, def: Def) bool {
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind));
    std.debug.assert(def.default.len <= default_len_max);

    return def.default.len == 0 or value_of(kind, def, 0) != null;
}

/// Every top-level field the document leaves out takes its default, when it has one.
pub fn apply(
    known: []const Kind,
    defs: []const Def,
    arena: std.mem.Allocator,
    object: *std.json.ObjectMap,
    now_ms: i64,
) error{OutOfMemory}!void {
    std.debug.assert(defs.len <= field.fields_max);
    std.debug.assert(known.len <= kinds.kinds_max);

    for (defs) |def| {
        if (object.get(def.name) != null) {
            continue;
        }

        const kind = kinds.find(known, def.kind) orelse continue;
        const value = value_of(kind, def, now_ms) orelse continue;
        const key = try arena.dupe(u8, def.name);

        if (def.many) {
            var list = std.json.Array.init(arena);

            try list.append(value);
            try object.put(arena, key, .{ .array = list });
        } else {
            try object.put(arena, key, value);
        }
    }
}

fn parse_bool(text: []const u8) ?Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= default_len_max);

    if (std.mem.eql(u8, text, "1") or std.mem.eql(u8, text, "true")) {
        return .{ .bool = true };
    }

    if (std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "false")) {
        return .{ .bool = false };
    }

    return null;
}

fn parse_integer(text: []const u8) ?Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= default_len_max);

    const number = std.fmt.parseInt(i64, text, 10) catch return null;

    return .{ .integer = number };
}

fn parse_number(text: []const u8) ?Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= default_len_max);

    const number = std.fmt.parseFloat(f64, text) catch return null;

    if (std.math.isNan(number) or std.math.isInf(number)) {
        return null;
    }

    return .{ .float = number };
}

/// A date and time default is a `datetime-local` text or a day, whichever the control
/// posted (the format can change on the same form); either way milliseconds.
fn parse_datetime(text: []const u8) ?Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= default_len_max);

    const ms = time.parse_datetime_local(text) orelse time.parse_date(text) orelse return null;

    return .{ .integer = ms };
}

test "defaults read as their kind's value, or not at all" {
    const string = kinds.find(&kinds.core, "string").?;
    const titled: Def = .{ .name = "title", .label = "Title", .kind = "string", .default = "Hi" };
    try std.testing.expectEqualStrings("Hi", value_of(string, titled, 0).?.string);
    try std.testing.expect(fits(string, titled));

    const integer = kinds.find(&kinds.core, "integer").?;
    const count: Def = .{ .name = "count", .label = "Count", .kind = "integer", .default = "3" };
    try std.testing.expectEqual(@as(i64, 3), value_of(integer, count, 0).?.integer);
    const wrong: Def = .{ .name = "count", .label = "Count", .kind = "integer", .default = "x" };
    try std.testing.expect(value_of(integer, wrong, 0) == null);
    try std.testing.expect(!fits(integer, wrong));

    const number = kinds.find(&kinds.core, "number").?;
    const price: Def = .{ .name = "price", .label = "Price", .kind = "number", .default = "1.5" };
    try std.testing.expectEqual(@as(f64, 1.5), value_of(number, price, 0).?.float);

    const boolean = kinds.find(&kinds.core, "boolean").?;
    const shown: Def = .{ .name = "shown", .label = "Shown", .kind = "boolean", .default = "1" };
    try std.testing.expect(value_of(boolean, shown, 0).?.bool);
    const hidden: Def = .{ .name = "shown", .label = "Shown", .kind = "boolean", .default = "no" };
    try std.testing.expect(value_of(boolean, hidden, 0) == null);

    const datetime = kinds.find(&kinds.core, "datetime").?;
    const at: Def = .{
        .name = "at",
        .label = "At",
        .kind = "datetime",
        .default = "1970-01-02T00:00",
    };
    try std.testing.expectEqual(@as(i64, 86_400_000), value_of(datetime, at, 0).?.integer);
    const day: Def = .{
        .name = "at",
        .label = "At",
        .kind = "datetime",
        .default = "1970-01-02",
        .options = .{ .date = .{ .format = .date } },
    };
    try std.testing.expectEqual(@as(i64, 86_400_000), value_of(datetime, day, 0).?.integer);

    const media = kinds.find(&kinds.core, "media").?;
    const cover: Def = .{ .name = "cover", .label = "Cover", .kind = "media", .default = "m1" };
    try std.testing.expect(value_of(media, cover, 0) == null);
    try std.testing.expect(!fits(media, cover));
    const none: Def = .{ .name = "cover", .label = "Cover", .kind = "media" };
    try std.testing.expect(fits(media, none));

    const stamp: Def = .{ .name = "at", .label = "At", .kind = "datetime", .default = "now" };
    try std.testing.expectEqual(@as(i64, 4242), value_of(datetime, stamp, 4242).?.integer);
    try std.testing.expect(fits(datetime, stamp));
}

test "a new document takes the defaults of the fields it leaves out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const defs = [_]Def{
        .{ .name = "title", .label = "Title", .kind = "string", .default = "Untitled" },
        .{ .name = "tags", .label = "Tags", .kind = "string", .many = true, .default = "new" },
        .{ .name = "views", .label = "Views", .kind = "integer", .default = "0" },
        .{ .name = "body", .label = "Body", .kind = "richtext", .default = "ignored" },
    };
    var object: std.json.ObjectMap = .empty;

    try object.put(arena, "title", .{ .string = "Given" });
    try apply(&kinds.core, &defs, arena, &object, 0);
    try std.testing.expectEqualStrings("Given", object.get("title").?.string);
    try std.testing.expectEqualStrings("new", object.get("tags").?.array.items[0].string);
    try std.testing.expectEqual(@as(i64, 0), object.get("views").?.integer);
    try std.testing.expect(object.get("body") == null);
}
