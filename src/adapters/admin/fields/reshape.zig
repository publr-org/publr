//! Adding, removing and moving values in a record form without saving it: the posted
//! form as a document, one list changed, the form drawn again. An action is
//! `add:tags`, `remove:tags[1]`, `up:faq[2]` or `down:faq[0]`; a single reference is
//! `set:hotel` or `clear:hotel`. The record to add or set comes from the form's
//! `pick:<field>` select.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");

const Form = admin.Form;
const Def = model.field.Def;
const Value = std.json.Value;

pub const Error = error{ Invalid, OutOfMemory };
pub const items_max: u32 = model.document.items_max;
pub const action_len_max: u32 = 128;

pub fn apply(
    arena: std.mem.Allocator,
    fields: []const Def,
    document: Value,
    action: []const u8,
    form: *const Form,
) Error!Value {
    std.debug.assert(document == .object);
    std.debug.assert(fields.len <= model.field.fields_max);

    if (action.len == 0 or action.len > action_len_max) {
        return error.Invalid;
    }

    const colon = std.mem.indexOfScalar(u8, action, ':') orelse return error.Invalid;
    const verb = action[0..colon];
    const target = action[colon + 1 ..];
    const bracket = std.mem.lastIndexOfScalar(u8, target, '[');
    const base = if (bracket) |at| target[0..at] else target;
    const index: ?u32 = if (bracket) |at|
        index_of(target[at..]) orelse return error.Invalid
    else
        null;
    const def = model.content_type.find_field(fields, base) orelse return error.Invalid;
    var object = document.object;

    if (std.mem.eql(u8, verb, "set") or std.mem.eql(u8, verb, "clear")) {
        return single_change(arena, &object, verb, def.*, form);
    }

    var array = std.json.Array.init(arena);

    if (object.get(base)) |current| {
        if (current == .array) {
            array.appendSlice(current.array.items) catch return error.OutOfMemory;
        }
    }

    try change(arena, &array, verb, index, def.*, form);

    const key = arena.dupe(u8, base) catch return error.OutOfMemory;

    object.put(arena, key, .{ .array = array }) catch return error.OutOfMemory;

    return .{ .object = object };
}

fn change(
    arena: std.mem.Allocator,
    array: *std.json.Array,
    verb: []const u8,
    index: ?u32,
    def: Def,
    form: *const Form,
) Error!void {
    std.debug.assert(verb.len <= action_len_max);
    std.debug.assert(array.items.len <= items_max);

    const count = array.items.len;

    if (std.mem.eql(u8, verb, "add")) {
        if (count == items_max) {
            return error.Invalid;
        }

        const blank = (try blank_of(arena, def, form)) orelse return;

        array.append(blank) catch return error.OutOfMemory;

        return;
    }

    const at = index orelse return error.Invalid;

    if (at >= count) {
        return error.Invalid;
    }

    if (std.mem.eql(u8, verb, "remove")) {
        _ = array.orderedRemove(at);
    } else if (std.mem.eql(u8, verb, "up")) {
        if (at > 0) {
            std.mem.swap(Value, &array.items[at - 1], &array.items[at]);
        }
    } else if (std.mem.eql(u8, verb, "down")) {
        if (at + 1 < count) {
            std.mem.swap(Value, &array.items[at], &array.items[at + 1]);
        }
    } else {
        return error.Invalid;
    }
}

/// A single reference pointed at the picked record, or at nothing.
fn single_change(
    arena: std.mem.Allocator,
    object: *std.json.ObjectMap,
    verb: []const u8,
    def: Def,
    form: *const Form,
) Error!Value {
    std.debug.assert(verb.len <= action_len_max);
    std.debug.assert(def.name.len > 0);

    const kind = model.kinds.lookup(registry.Kinds.all, def.kind);

    if (def.many or !kind.has.target) {
        return error.Invalid;
    }

    const value: Value = if (std.mem.eql(u8, verb, "set"))
        (try blank_of(arena, def, form)) orelse return .{ .object = object.* }
    else
        .null;
    const key = arena.dupe(u8, def.name) catch return error.OutOfMemory;

    object.put(arena, key, value) catch return error.OutOfMemory;

    return .{ .object = object.* };
}

/// What a new value starts as: an empty item for a repeater, the picked record for a
/// reference (nothing picked, nothing added), an empty text otherwise.
fn blank_of(arena: std.mem.Allocator, def: Def, form: *const Form) Error!?Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    if (model.field.is_repeater(def.kind)) {
        return .{ .object = .empty };
    }

    const kind = model.kinds.lookup(registry.Kinds.all, def.kind);

    if (!def.many and !kind.has.target) {
        return error.Invalid;
    }

    if (kind.has.target) {
        const pick_name = std.fmt.allocPrint(arena, "pick:{s}", .{def.name}) catch {
            return error.OutOfMemory;
        };
        const picked = form.text(pick_name) orelse return null;

        return .{ .string = picked };
    }

    return switch (kind.storage) {
        .text, .long, .ref => .{ .string = "" },
        else => .null,
    };
}

fn index_of(text: []const u8) ?u32 {
    std.debug.assert(text.len > 0);
    std.debug.assert(text[0] == '[');

    if (text.len < 3 or text[text.len - 1] != ']') {
        return null;
    }

    const parsed = std.fmt.parseInt(u32, text[1 .. text.len - 1], 10) catch return null;

    return if (parsed < items_max) parsed else null;
}

const test_fields = [_]Def{
    .{
        .name = "tags",
        .label = "Tags",
        .kind = "reference",
        .many = true,
        .options = .{ .to = &.{"tag"} },
    },
    .{ .name = "names", .label = "Names", .kind = "string", .many = true },
    .{ .name = "faq", .label = "FAQ", .kind = "repeater", .fields = &.{
        .{ .name = "question", .label = "Q", .kind = "string" },
    } },
    .{ .name = "title", .label = "Title", .kind = "string" },
    .{ .name = "hotel", .label = "Hotel", .kind = "reference", .options = .{ .to = &.{"hotel"} } },
};

fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text[0] == '{');

    return @import("../../../lib/json.zig").parse(Value, arena, text, .{});
}

fn text_of(arena: std.mem.Allocator, value: Value) ![]const u8 {
    std.debug.assert(value == .object);
    std.debug.assert(items_max > 0);

    return std.json.Stringify.valueAlloc(arena, value, .{});
}

test "add, remove and move change one list and leave the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const picked = Form.parse(arena, "pick%3Atags=t9").?;
    const nothing = Form.parse(arena, "title=x").?;
    const start = try parse(
        arena,
        "{\"title\":\"T\",\"tags\":[\"t1\",\"t2\"],\"faq\":[{\"question\":\"a\"}]}",
    );

    const added = try apply(arena, &test_fields, start, "add:tags", &picked);
    try std.testing.expectEqualStrings(
        "{\"title\":\"T\",\"tags\":[\"t1\",\"t2\",\"t9\"],\"faq\":[{\"question\":\"a\"}]}",
        try text_of(arena, added),
    );

    const unpicked = try apply(arena, &test_fields, added, "add:tags", &nothing);
    try std.testing.expectEqual(@as(usize, 3), unpicked.object.get("tags").?.array.items.len);

    const moved = try apply(arena, &test_fields, unpicked, "up:tags[2]", &nothing);
    try std.testing.expectEqualStrings("t9", moved.object.get("tags").?.array.items[1].string);

    const removed = try apply(arena, &test_fields, moved, "remove:tags[0]", &nothing);
    try std.testing.expectEqual(@as(usize, 2), removed.object.get("tags").?.array.items.len);

    const item = try apply(arena, &test_fields, removed, "add:faq", &nothing);
    try std.testing.expectEqual(@as(usize, 2), item.object.get("faq").?.array.items.len);

    const named = try apply(arena, &test_fields, item, "add:names", &nothing);
    try std.testing.expectEqualStrings("", named.object.get("names").?.array.items[0].string);

    const single = apply(arena, &test_fields, named, "add:title", &nothing);
    try std.testing.expectError(error.Invalid, single);
    const beyond = apply(arena, &test_fields, named, "remove:tags[7]", &nothing);
    try std.testing.expectError(error.Invalid, beyond);
    try std.testing.expectError(error.Invalid, apply(arena, &test_fields, named, "nope", &nothing));
    const unindexed = apply(arena, &test_fields, named, "up:tags[x]", &nothing);
    try std.testing.expectError(error.Invalid, unindexed);

    const hotel_picked = Form.parse(arena, "pick%3Ahotel=h1").?;
    const pointed = try apply(arena, &test_fields, named, "set:hotel", &hotel_picked);
    try std.testing.expectEqualStrings("h1", pointed.object.get("hotel").?.string);
    const cleared = try apply(arena, &test_fields, pointed, "clear:hotel", &nothing);
    try std.testing.expect(cleared.object.get("hotel").? == .null);
    const listed = apply(arena, &test_fields, cleared, "set:tags", &nothing);
    try std.testing.expectError(error.Invalid, listed);
}
