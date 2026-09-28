const std = @import("std");
const field = @import("field.zig");
const kinds = @import("kinds.zig");

const Def = field.Def;
const Kind = kinds.Kind;
const Problems = field.Problems;
const Value = std.json.Value;

pub const string_len_max: u32 = kinds.string_len_max;
pub const text_len_max: u32 = 4 << 20;
pub const id_len_max: u32 = 64;
pub const repeater_items_max: u32 = 1000;
pub const day_ms: i64 = 86_400_000;

/// `now_ms` is the moment of the write, for the rules that are relative to it.
pub fn validate_document(
    known: []const Kind,
    defs: []const Def,
    document: Value,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(defs.len <= field.fields_max);
    std.debug.assert(problems.len <= field.problems_max);

    const object = switch (document) {
        .object => |object| object,
        else => {
            problems.add("", "document must be a JSON object");

            return;
        },
    };

    for (defs) |def| {
        const value = object.get(def.name);
        if (field.is_layout(def.kind)) {
            if (value != null) {
                problems.add(def.name, "layout elements do not store values");
            }
            continue;
        }
        validate_field(known, conditional(def, object), value, def.name, now_ms, problems);
    }

    var keys = object.iterator();

    while (keys.next()) |entry| {
        if (find(defs, entry.key_ptr.*) == null) {
            problems.add(entry.key_ptr.*, "unknown field");
        }
    }
}

fn conditional(def: Def, object: std.json.ObjectMap) Def {
    std.debug.assert(def.conditions.len <= field.conditions.groups_max);
    var effective = def;

    if (!field.conditions.matches(def.conditions, object)) {
        effective.required = false;
        effective.options.items_min = null;
    }

    return effective;
}

fn find(defs: []const Def, name: []const u8) ?*const Def {
    std.debug.assert(name.len <= string_len_max);
    std.debug.assert(defs.len <= field.fields_max);

    for (defs) |*def| {
        if (std.mem.eql(u8, def.name, name)) {
            return def;
        }
    }

    return null;
}

fn validate_field(
    known: []const Kind,
    def: Def,
    value: ?Value,
    path: []const u8,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(problems.len <= field.problems_max);

    const present = value != null and value.? != .null;

    if (!present) {
        if (def.required or (def.options.items_min orelse 0) > 0) {
            problems.add(path, "required");
        }

        return;
    }

    if (def.many) {
        validate_many(known, def, value.?, path, now_ms, problems);

        return;
    }

    validate_one(known, def, value.?, path, now_ms, problems);
}

fn validate_many(
    known: []const Kind,
    def: Def,
    value: Value,
    path: []const u8,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(def.many);
    std.debug.assert(path.len > 0);

    const items = switch (value) {
        .array => |array| array.items,
        else => {
            problems.add(path, "expected a list");

            return;
        },
    };

    if (items.len > repeater_items_max) {
        problems.add(path, "too many items");

        return;
    }

    if (def.required and items.len == 0) {
        problems.add(path, "required");
    }

    check_items(def, items, path, problems);

    for (items) |item| {
        validate_one(known, def, item, path, now_ms, problems);
    }
}

/// How many items a list holds, and whether any two are the same.
fn check_items(def: Def, items: []const Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(items.len <= repeater_items_max);

    const message = def.options.messages.items;

    if (def.options.items_min) |least| {
        if (items.len < least) {
            problems.add(path, if (message.len > 0) message else "too few items");
        }
    }

    if (def.options.items_max) |most| {
        if (items.len > most) {
            problems.add(path, if (message.len > 0) message else "too many items");
        }
    }

    if (!def.options.distinct) {
        return;
    }

    for (items, 0..) |item, index| {
        for (items[0..index]) |earlier| {
            if (same(item, earlier)) {
                problems.add(path, if (message.len > 0) message else "the same value twice");

                return;
            }
        }
    }
}

/// Whether two scalar values are the same; objects and lists never are here.
fn same(left: Value, right: Value) bool {
    std.debug.assert(repeater_items_max > 0);
    std.debug.assert(text_len_max > 0);

    return switch (left) {
        .string => |text| right == .string and std.mem.eql(u8, text, right.string),
        .integer => |number| right == .integer and number == right.integer,
        .float => |number| right == .float and number == right.float,
        .bool => |flag| right == .bool and flag == right.bool,
        else => false,
    };
}

/// The storage class says what shape the value must have; the kind's own check runs
/// after that, so it can trust the shape.
fn validate_one(
    known: []const Kind,
    def: Def,
    value: Value,
    path: []const u8,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(problems.len <= field.problems_max);

    const kind = kinds.find(known, def.kind) orelse {
        problems.add(path, "unknown kind");

        return;
    };
    const before = problems.len;

    switch (kind.storage) {
        .text, .long => validate_text(kind, def, value, path, problems),
        .bool => {
            if (value != .bool) {
                problems.add(path, "expected true or false");
            }
        },
        .int => validate_integer(kind, def, value, path, now_ms, problems),
        .real => validate_number(def, value, path, problems),
        .ref => validate_id(value, path, problems),
        .none => validate_container(known, def, value, path, now_ms, problems),
    }

    if (problems.len == before) {
        if (kind.check) |check| {
            check(def, value, path, problems);
        }
    }
}

fn validate_text(kind: Kind, def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(kind.storage == .text or kind.storage == .long);
    std.debug.assert(path.len > 0);

    const text = switch (value) {
        .string => |text| text,
        else => {
            problems.add(path, "expected text");

            return;
        },
    };
    const len_max = if (kind.storage == .long) text_len_max else string_len_max;

    if (text.len > len_max) {
        problems.add(path, "too long");

        return;
    }

    const message = def.options.messages.length;

    if (def.options.min_len) |min_len| {
        if (text.len < min_len) {
            problems.add(path, if (message.len > 0) message else "too short");
        }
    }

    if (def.options.max_len) |max_len| {
        if (text.len > max_len) {
            problems.add(path, if (message.len > 0) message else "too long");
        }
    }

    if (kind.has.words) {
        check_words(def, text, path, problems);
    }

    if (kind.has.pattern) {
        check_pattern(def, text, path, problems);
    }
}

fn check_words(def: Def, text: []const u8, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(text.len <= text_len_max);

    const words = field.pattern.word_count(text[0..@min(text.len, field.pattern.text_len_max)]);
    const message = def.options.messages.words;

    if (def.options.words_min) |least| {
        if (words < least) {
            problems.add(path, if (message.len > 0) message else "too few words");
        }
    }

    if (def.options.words_max) |most| {
        if (words > most) {
            problems.add(path, if (message.len > 0) message else "too many words");
        }
    }
}

fn check_pattern(def: Def, text: []const u8, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(text.len <= text_len_max);

    const shape = def.options;
    const message = shape.messages.pattern;

    const too_long = shape.pattern.len > field.options.pattern_len_max;

    if (text.len > field.pattern.text_len_max or too_long) {
        return;
    }

    const preset_ok = field.pattern.matches_preset(shape.preset, text);
    const pattern_ok = field.pattern.matches(shape.pattern, text);

    if (!preset_ok or !pattern_ok) {
        problems.add(path, if (message.len > 0) message else "does not match the required shape");
    }
}

fn validate_integer(
    kind: Kind,
    def: Def,
    value: Value,
    path: []const u8,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    const number = switch (value) {
        .integer => |number| number,
        else => {
            problems.add(path, "expected a whole number");

            return;
        },
    };
    const as_float: f64 = @floatFromInt(number);

    check_range(def, as_float, path, problems);
    check_choices(def, as_float, path, problems);

    if (kind.control == .datetime and def.options.date.from_now and now_ms >= 0) {
        const today = now_ms - @mod(now_ms, day_ms);

        if (number < today) {
            const message = def.options.messages.range;

            problems.add(path, if (message.len > 0) message else "before today");
        }
    }
}

fn validate_number(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    const number: f64 = switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => {
            problems.add(path, "expected a number");

            return;
        },
    };

    if (!std.math.isFinite(number)) {
        problems.add(path, "expected a finite number");
        return;
    }

    check_range(def, number, path, problems);
    check_choices(def, number, path, problems);
}

/// A number field with listed values takes one of them and nothing else.
fn check_choices(def: Def, number: f64, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(!std.math.isNan(number));

    if (def.options.choices.len == 0) {
        return;
    }

    for (def.options.choices) |choice| {
        const listed = std.fmt.parseFloat(f64, choice) catch continue;

        if (listed == number) {
            return;
        }
    }

    const message = def.options.messages.choices;

    problems.add(path, if (message.len > 0) message else "not one of the listed values");
}

fn check_range(def: Def, number: f64, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(!std.math.isNan(number));

    const message = def.options.messages.range;

    if (def.options.min) |min| {
        if (number < min) {
            problems.add(path, if (message.len > 0) message else "below the minimum");
        }
    }

    if (def.options.max) |max| {
        if (number > max) {
            problems.add(path, if (message.len > 0) message else "above the maximum");
        }
    }
}

fn validate_id(value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(id_len_max > 0);

    switch (value) {
        .string => |text| {
            if (text.len == 0 or text.len > id_len_max) {
                problems.add(path, "expected an id");
            }
        },
        else => problems.add(path, "expected an id"),
    }
}

fn validate_container(
    known: []const Kind,
    def: Def,
    value: Value,
    path: []const u8,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(field.is_container(def.kind));
    std.debug.assert(path.len > 0);

    if (field.is_group(def.kind)) {
        validate_group(known, def, value, path, now_ms, problems);
    } else {
        validate_repeater(known, def, value, path, now_ms, problems);
    }
}

fn validate_group(
    known: []const Kind,
    def: Def,
    value: Value,
    path: []const u8,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(field.is_container(def.kind));
    std.debug.assert(path.len > 0);

    const object = switch (value) {
        .object => |object| object,
        else => {
            problems.add(path, "expected an object");

            return;
        },
    };

    for (def.fields) |child| {
        var path_buffer: [field.path_len_max]u8 = undefined;
        const child_path = std.fmt.bufPrint(
            &path_buffer,
            "{s}.{s}",
            .{ path, child.name },
        ) catch path;

        validate_field(
            known,
            conditional(
                child,
                object,
            ),
            object.get(child.name),
            child_path,
            now_ms,
            problems,
        );
    }
}

fn validate_repeater(
    known: []const Kind,
    def: Def,
    value: Value,
    path: []const u8,
    now_ms: i64,
    problems: *Problems,
) void {
    std.debug.assert(field.is_repeater(def.kind));
    std.debug.assert(path.len > 0);

    const items = switch (value) {
        .array => |array| array.items,
        else => {
            problems.add(path, "expected a list");

            return;
        },
    };

    if (items.len > repeater_items_max) {
        problems.add(path, "too many items");

        return;
    }

    check_items(def, items, path, problems);

    for (items, 0..) |item, index| {
        var path_buffer: [field.path_len_max]u8 = undefined;
        const item_path = std.fmt.bufPrint(&path_buffer, "{s}[{d}]", .{ path, index }) catch path;

        validate_group(known, def, item, item_path, now_ms, problems);
    }
}

pub const valid_slug = kinds.valid_slug;

const test_defs = [_]Def{
    .{
        .name = "title",
        .label = "Title",
        .kind = "string",
        .required = true,
        .options = .{ .max_len = 10 },
    },
    .{ .name = "slug", .label = "Slug", .kind = "slug" },
    .{ .name = "count", .label = "Count", .kind = "integer", .options = .{ .min = 0, .max = 5 } },
    .{
        .name = "kind",
        .label = "Kind",
        .kind = "select",
        .options = .{ .choices = &.{ "a", "b" } },
    },
    .{
        .name = "tags",
        .label = "Tags",
        .kind = "reference",
        .many = true,
        .options = .{ .to = &.{"tag"} },
    },
    .{ .name = "gallery", .label = "Gallery", .kind = "repeater", .fields = &.{
        .{ .name = "image", .label = "Image", .kind = "media", .required = true },
    } },
    .{ .name = "seo", .label = "SEO", .kind = "group", .fields = &.{
        .{ .name = "description", .label = "Description", .kind = "text" },
    } },
};

fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text[0] == '{');

    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "a valid document passes; every kind of mistake is reported at its path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ok: Problems = .{};
    const good = try parse(arena,
        \\{"title":"Hello","slug":"hello-1","count":3,"kind":"a","tags":["t1","t2"],
        \\ "gallery":[{"image":"m1"}],"seo":{"description":"x"}}
    );
    validate_document(&kinds.core, &test_defs, good, 0, &ok);
    try std.testing.expect(ok.is_empty());

    var bad: Problems = .{};
    const wrong = try parse(arena,
        \\{"title":"way too long title","slug":"Bad Slug","count":9,"kind":"z","tags":"t1",
        \\ "gallery":[{}],"seo":{"description":5},"extra":1}
    );
    validate_document(&kinds.core, &test_defs, wrong, 0, &bad);
    try std.testing.expectEqual(@as(u32, 8), bad.len);
    try std.testing.expectEqualStrings("gallery[0].image", bad.items[5].path);
    try std.testing.expectEqualStrings("required", bad.items[5].message);
    try std.testing.expectEqualStrings("seo.description", bad.items[6].path);
    try std.testing.expectEqualStrings("extra", bad.items[7].path);

    var missing: Problems = .{};
    validate_document(&kinds.core, &test_defs, try parse(arena, "{}"), 0, &missing);
    try std.testing.expectEqual(@as(u32, 1), missing.len);
    try std.testing.expectEqualStrings("title", missing.items[0].path);

    var custom: Problems = .{};
    const worded = [_]Def{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
        .options = .{ .max_len = 3, .messages = .{ .length = "Keep it short" } },
    }};
    validate_document(&kinds.core, &worded, try parse(arena, "{\"title\":\"long\"}"), 0, &custom);
    try std.testing.expectEqualStrings("Keep it short", custom.items[0].message);

    var unknown: Problems = .{};
    const point = [_]Def{.{ .name = "at", .label = "At", .kind = "geo.point" }};
    validate_document(&kinds.core, &point, try parse(arena, "{\"at\":\"x\"}"), 0, &unknown);
    try std.testing.expectEqualStrings("unknown kind", unknown.items[0].message);
}

test "lists, shapes, listed numbers and days from now" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const defs = [_]Def{
        .{ .name = "tags", .label = "Tags", .kind = "string", .many = true, .options = .{
            .items_min = 1,
            .items_max = 2,
            .distinct = true,
            .messages = .{ .items = "One or two different tags" },
        } },
        .{ .name = "code", .label = "Code", .kind = "string", .options = .{ .pattern = "@@-###" } },
        .{ .name = "bio", .label = "Bio", .kind = "text", .options = .{
            .words_max = 3,
            .preset = .lowercase,
        } },
        .{ .name = "size", .label = "Size", .kind = "integer", .options = .{
            .choices = &.{ "1", "2" },
        } },
        .{ .name = "when", .label = "When", .kind = "datetime", .options = .{
            .date = .{ .from_now = true },
        } },
    };
    const today: i64 = 5 * day_ms + 1000;

    var ok: Problems = .{};
    const good = try parse(arena,
        \\{"tags":["a","b"],"code":"AB-123","bio":"two words","size":2,"when":432000000}
    );
    validate_document(&kinds.core, &defs, good, today, &ok);
    try std.testing.expect(ok.is_empty());

    var bad: Problems = .{};
    const wrong = try parse(arena,
        \\{"tags":["a","a"],"code":"AB-12","bio":"One two three four","size":3,"when":1000}
    );
    validate_document(&kinds.core, &defs, wrong, today, &bad);
    try std.testing.expectEqual(@as(u32, 6), bad.len);
    try std.testing.expectEqualStrings("One or two different tags", bad.items[0].message);
    try std.testing.expectEqualStrings("does not match the required shape", bad.items[1].message);
    try std.testing.expectEqualStrings("before today", bad.items[5].message);

    var few: Problems = .{};
    const three = try parse(arena, "{\"tags\":[\"a\",\"b\",\"c\"]}");
    validate_document(&kinds.core, &defs, three, today, &few);
    try std.testing.expectEqualStrings("One or two different tags", few.items[0].message);
}

test "conditional requiredness is evaluated on the server and hidden values remain validated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const defs = [_]Def{
        .{ .name = "enabled", .label = "Enabled", .kind = "boolean" },
        .{
            .name = "caption",
            .label = "Caption",
            .kind = "string",
            .required = true,
            .options = .{
                .max_len = 5,
            },
            .conditions = &.{
                .{
                    .rules = &.{
                        .{
                            .field = "enabled",
                            .value = "true",
                        },
                    },
                },
            },
        },
    };
    const cases = [_]struct { text: []const u8, valid: bool }{
        .{ .text = "{\"enabled\":false}", .valid = true },
        .{ .text = "{\"enabled\":true}", .valid = false },
        .{ .text = "{\"enabled\":true,\"caption\":\"Hello\"}", .valid = true },
        .{ .text = "{\"enabled\":false,\"caption\":\"Too long\"}", .valid = false },
    };

    for (cases) |case| {
        const value = try std.json.parseFromSliceLeaky(Value, arena, case.text, .{});
        var problems: Problems = .{};
        validate_document(&kinds.core, &defs, value, 0, &problems);
        try std.testing.expectEqual(case.valid, problems.is_empty());
    }

    var invalid = defs;
    invalid[0].conditions = &.{.{ .rules = &.{.{ .field = "caption", .value = "Hello" }} }};
    var problems: Problems = .{};
    field.validate_defs(&kinds.core, &invalid, 0, &problems);
    try std.testing.expect(!problems.is_empty());
}

test "extended fields reject malformed values and layout elements cannot store data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const defs = [_]Def{
        .{ .name = "color", .label = "Color", .kind = "color" },
        .{ .name = "time", .label = "Time", .kind = "time" },
        .{ .name = "section", .label = "Section", .kind = "tab" },
    };
    const cases = [_]struct { text: []const u8, valid: bool }{
        .{ .text = "{}", .valid = true },
        .{ .text = "{\"color\":\"#aBc012\",\"time\":\"23:59\"}", .valid = true },
        .{ .text = "{\"color\":\"#12345g\"}", .valid = false },
        .{ .text = "{\"time\":\"24:00\"}", .valid = false },
        .{ .text = "{\"time\":\"+1:00\"}", .valid = false },
        .{ .text = "{\"section\":\"injected\"}", .valid = false },
    };

    for (cases) |case| {
        var problems: Problems = .{};
        validate_document(&kinds.core, &defs, try parse(arena, case.text), 0, &problems);
        try std.testing.expectEqual(case.valid, problems.is_empty());
    }
}
