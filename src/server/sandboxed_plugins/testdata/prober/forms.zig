//! The values a description can say beyond numbers and texts, handed over wrong: a list and
//! an enum inside a real call, a value whose shape comes with the data, a pointer, a union,
//! a tree that is its own child, and a message asked of the catalogues. Each goes to
//! `mod.apply`, which any plugin may call and which reads every part of what it is given.
const std = @import("std");

const Call = extern struct {
    name: u32,
    name_len: u32,
    root: u32,
    asked: u32,
    asked_len: u32,
    table: u32,
    table_len: u32,
    answer: u32,
    answer_len: u32,
};

const Slice = extern struct {
    ptr: u32,
    len: u32,
};

const Entry = extern struct {
    ptr: u32,
    len: u32,
};

const Message = extern struct {
    context: u32,
    context_len: u32,
    id: u32,
    id_len: u32,
    plural: u32,
    plural_len: u32,
    counted: u32,
    count: f64,
};

extern "env" fn publr_call_shaped(call: *const Call, sizes: *[2]u32) u32;
extern "env" fn publr_translate(asked: *const Message, result: *Slice) u32;

const outside: u32 = 0xffff_fff0;

/// One value `mod.apply` is handed: an enum, a free-form value, a pointer to another, a
/// list of texts; its union lies beside the block.
const Item = extern struct {
    kind: u32,
    note: Slice,
    next: u32,
    tags: Slice,
};

const Apply = extern struct {
    name: Slice,
    values: Slice,
};

fn word(comptime value: u32) *const [4]u8 {
    comptime {
        var bytes: [4]u8 = undefined;

        std.debug.assert(value <= std.math.maxInt(u32));
        std.mem.writeInt(u32, &bytes, value, .little);

        const kept = bytes;

        return &kept;
    }
}

fn field(comptime name: []const u8, comptime offset: u32) []const u8 {
    comptime {
        std.debug.assert(name.len > 0 and name.len < 256);

        return &[_]u8{name.len} ++ name ++ word(offset) ++ word(0);
    }
}

const item_room = word(@sizeOf(Item)) ++ word(4);
const choice_shape = "u" ++ word(2) ++ "\x04none" ++ word(0) ++ word(1) ++ "o\x00" ++ word(0) ++
    word(0) ++ "\x05count" ++ word(4) ++ word(4) ++ "i\x04\x00";
const item_shape = "o\x00" ++ word(@sizeOf(Item)) ++ word(5) ++
    field("kind", 0) ++ "e\x04" ++ word(1) ++ "\x03one" ++ word(16) ++ word(0) ++
    field("note", 4) ++ "v" ++
    field("next", 12) ++ "n" ++ word(4) ++ "\x01p" ++ item_room ++ "r\x01" ++
    field("tags", 16) ++ "l\x00" ++ word(8) ++ word(4) ++ "s" ++
    field("choice", @sizeOf(Item)) ++ choice_shape;
const apply_shape = "o\x00" ++ word(16) ++ word(2) ++ field("name", 0) ++ "s" ++
    field("values", 8) ++ "l\x00" ++ item_room ++ item_shape;
const answer_shape = "o\x00" ++ word(8) ++ word(1) ++ field("values", 0) ++ "v";

// A tree whose node holds its children: a value may be handed over as its own child.
const tree_shape = "o\x00" ++ word(16) ++ word(2) ++ field("name", 0) ++ "s" ++
    field("values", 8) ++ "l\x00" ++ word(8) ++ word(4) ++
    "o\x00" ++ word(8) ++ word(1) ++ field("children", 0) ++ "l\x00" ++ word(8) ++ word(4) ++
    "r\x01";

// Descriptions that are not ones: a struct that is its own field, a keyed list of texts.
const own_shape = "o\x00" ++ word(16) ++ word(2) ++ field("name", 0) ++ "s" ++
    field("values", 8) ++ "r\x01";
const keyed_shape = "o\x00" ++ word(16) ++ word(2) ++ field("name", 0) ++ "s" ++
    field("values", 8) ++ "l\x01" ++ word(8) ++ word(4) ++ "s";

const apply_name = "mod.apply";
const applied_name = "prober.things";
const tag = "tea";
const nothing = [_]u8{0};

fn address(pointer: anytype) u32 {
    const at = @intFromPtr(pointer);

    std.debug.assert(at != 0);

    return @intCast(at);
}

/// Everything one call points at, kept together so each case changes one part of it.
const Parts = struct {
    tags: [1]Slice,
    items: [1]Item,
    table: [1]Entry,
    apply: Apply,
    count: u32 = 7,

    fn init(parts: *Parts) void {
        parts.tags = .{.{
            .ptr = address(tag.ptr),
            .len = tag.len,
        }};
        parts.items = .{.{
            .kind = 16,
            .note = .{
                .ptr = address(&nothing),
                .len = nothing.len,
            },
            .next = 0,
            .tags = .{
                .ptr = address(&parts.tags),
                .len = 1,
            },
        }};
        parts.table = .{.{
            .ptr = 0,
            .len = 0,
        }};
        parts.apply = .{
            .name = .{
                .ptr = address(applied_name.ptr),
                .len = applied_name.len,
            },
            .values = .{
                .ptr = address(&parts.items),
                .len = 1,
            },
        };

        std.debug.assert(parts.apply.values.len == 1);
    }

    fn call(parts: *const Parts, shape: []const u8, table_len: u32) u32 {
        var sizes: [2]u32 = .{ 0, 0 };

        std.debug.assert(shape.len > 0);

        return publr_call_shaped(&.{
            .name = address(apply_name.ptr),
            .name_len = apply_name.len,
            .root = address(&parts.apply),
            .asked = address(shape.ptr),
            .asked_len = @intCast(shape.len),
            .table = address(&parts.table),
            .table_len = table_len,
            .answer = address(answer_shape.ptr),
            .answer_len = answer_shape.len,
        }, &sizes);
    }

    fn sent(parts: *const Parts) u32 {
        return parts.call(apply_shape, 1);
    }
};

/// The same call made honestly: 0.
pub fn honest() u32 {
    var parts: Parts = undefined;

    parts.init();

    return parts.sent();
}

/// A free-form value that is not well made: of no kind, a count that lies, a size past its
/// bytes, a text that is not UTF-8, lists nested deeper than a value may go.
const no_kind = [_]u8{9};
const count_lies = [_]u8{ 6, 1, 0, 0, 0, 5, 0, 0, 0, 0 };
const size_lies = [_]u8{ 6, 100, 0, 0, 0, 1, 0, 0, 0, 0 };
const not_text = [_]u8{ 5, 2, 0, 0, 0, 0xff, 0xfe };
const too_deep = deep(70);

fn deep(comptime levels: u32) [levels * 9 + 1]u8 {
    comptime {
        var bytes: [levels * 9 + 1]u8 = undefined;

        std.debug.assert(levels > 0);

        for (0..levels) |level| {
            bytes[level * 9] = 6;
            const inside: u32 = bytes.len - (level + 1) * 9;

            std.mem.writeInt(u32, bytes[level * 9 + 1 ..][0..4], inside, .little);
            std.mem.writeInt(u32, bytes[level * 9 + 5 ..][0..4], 1, .little);
        }

        bytes[bytes.len - 1] = 0;

        return bytes;
    }
}

pub const wrong_count: u32 = 29;

/// How each wrong call ended: every one must be `Invalid`.
pub fn wrong() [wrong_count]u32 {
    const codes = wrong_lists() ++ wrong_free() ++ wrong_addresses() ++ wrong_shapes() ++
        wrong_messages() ++ wrong_applies();

    std.debug.assert(codes.len == wrong_count);

    return codes;
}

/// A list whose items are outside the memory, or more than it could hold; an enum holding
/// a number that is none of its tags.
fn wrong_lists() [4]u32 {
    var codes: [4]u32 = undefined;
    var parts: Parts = undefined;
    const lists = [_]Slice{
        .{
            .ptr = outside,
            .len = 1,
        },
        .{
            .ptr = 64,
            .len = 0x2000_0001,
        },
        .{
            .ptr = 64,
            .len = 0xffff_ffff,
        },
    };

    for (lists, codes[0..3]) |values, *code| {
        parts.init();
        parts.apply.values = values;
        code.* = parts.sent();
    }

    parts.init();
    parts.items[0].kind = 4;
    codes[3] = parts.sent();

    std.debug.assert(lists.len == 3);

    return codes;
}

/// A free-form value outside the memory, longer than it, not well made, or of no bytes.
fn wrong_free() [8]u32 {
    var codes: [8]u32 = undefined;
    var parts: Parts = undefined;
    const notes = [_]Slice{
        .{
            .ptr = outside,
            .len = 1,
        },
        .{
            .ptr = address(&nothing),
            .len = 0xffff_ffff,
        },
        .{
            .ptr = address(&no_kind),
            .len = no_kind.len,
        },
        .{
            .ptr = address(&count_lies),
            .len = count_lies.len,
        },
        .{
            .ptr = address(&size_lies),
            .len = size_lies.len,
        },
        .{
            .ptr = address(&not_text),
            .len = not_text.len,
        },
        .{
            .ptr = address(&too_deep),
            .len = too_deep.len,
        },
        .{
            .ptr = address(&nothing),
            .len = 0,
        },
    };

    for (notes, &codes) |note, *code| {
        parts.init();
        parts.items[0].note = note;
        code.* = parts.sent();
    }

    std.debug.assert(notes.len == codes.len);

    return codes;
}

/// A pointer outside the memory and a value that points at itself; a text of the inner
/// list outside; a union of an alternative it does not have, with its payload outside, and
/// with no entry beside the block.
fn wrong_addresses() [6]u32 {
    var codes: [6]u32 = undefined;
    var parts: Parts = undefined;

    parts.init();
    parts.items[0].next = outside;
    codes[0] = parts.sent();
    parts.items[0].next = address(&parts.items);
    codes[1] = parts.sent();

    parts.init();
    parts.tags[0].ptr = outside;
    codes[2] = parts.sent();

    parts.init();
    parts.table[0].len = 7;
    codes[3] = parts.sent();
    parts.table[0] = .{
        .ptr = outside,
        .len = 1,
    };
    codes[4] = parts.sent();
    parts.init();
    codes[5] = parts.call(apply_shape, 0);

    std.debug.assert(parts.apply.values.len == 1);

    return codes;
}

/// A tree handed over as its own child; descriptions that are not ones.
fn wrong_shapes() [3]u32 {
    var codes: [3]u32 = undefined;
    var parts: Parts = undefined;
    var node: Slice = undefined;

    node = .{
        .ptr = address(&node),
        .len = 1,
    };
    parts.init();
    parts.apply.values = node;
    codes[0] = parts.call(tree_shape, 0);
    parts.init();
    codes[1] = parts.call(own_shape, 0);
    codes[2] = parts.call(keyed_shape, 0);

    std.debug.assert(node.len == 1);

    return codes;
}

/// A message asked of the catalogues from outside the memory.
fn wrong_messages() [3]u32 {
    var codes: [3]u32 = undefined;
    var result: Slice = .{
        .ptr = 0,
        .len = 0,
    };
    var message: Message = .{
        .context = 0,
        .context_len = 0,
        .id = outside,
        .id_len = 4,
        .plural = 0,
        .plural_len = 0,
        .counted = 0,
        .count = 0,
    };

    codes[0] = publr_translate(&message, &result);
    message.id = address(tag.ptr);
    message.id_len = 0xffff_ffff;
    codes[1] = publr_translate(&message, &result);
    codes[2] = publr_translate(@ptrFromInt(outside), &result);

    std.debug.assert(result.len == 0);

    return codes;
}

// Values that are plain numbers, and applies that are not ones: the values a text, the
// name a number, an answer whose `values` is a number.
const numbers_shape = "o\x00" ++ word(16) ++ word(2) ++ field("name", 0) ++ "s" ++
    field("values", 8) ++ "l\x00" ++ word(4) ++ word(4) ++ "i\x04\x00";
const values_text_shape = "o\x00" ++ word(16) ++ word(2) ++ field("name", 0) ++ "s" ++
    field("values", 8) ++ "s";
const name_number_shape = "o\x00" ++ word(16) ++ word(2) ++ field("name", 0) ++ "i\x04\x00" ++
    field("values", 8) ++ "l\x00" ++ word(4) ++ word(4) ++ "i\x04\x00";
const number_answer_shape = "o\x00" ++ word(8) ++ word(1) ++ field("values", 0) ++ "i\x04\x00";
const bad_name = "Not A Name";
const many_max: u32 = 200;

/// What `ctx.mod` sends, wrong as a whole: more values than one apply takes, values that
/// are no list, a name that is no text or no mod's name, and an answer the values cannot
/// be laid back into. As many values as an apply takes, sent honestly, must answer first:
/// when that call fails the last code is 0, which is not `Invalid`.
fn wrong_applies() [5]u32 {
    var codes: [5]u32 = undefined;
    var sizes: [2]u32 = .{ 0, 0 };
    const numbers: [many_max + 1]u32 = @splat(7);
    var apply: Apply = .{
        .name = .{
            .ptr = address(applied_name.ptr),
            .len = applied_name.len,
        },
        .values = .{
            .ptr = address(&numbers),
            .len = many_max + 1,
        },
    };
    var call: Call = .{
        .name = address(apply_name.ptr),
        .name_len = apply_name.len,
        .root = address(&apply),
        .asked = address(numbers_shape.ptr),
        .asked_len = numbers_shape.len,
        .table = 0,
        .table_len = 0,
        .answer = address(answer_shape.ptr),
        .answer_len = answer_shape.len,
    };

    codes[0] = publr_call_shaped(&call, &sizes);
    apply.values.len = many_max;

    // As many as an apply takes, sent honestly, answer: only then do the others count.
    const fine = publr_call_shaped(&call, &sizes);

    call.asked = address(values_text_shape.ptr);
    call.asked_len = values_text_shape.len;
    codes[1] = publr_call_shaped(&call, &sizes);
    call.asked = address(name_number_shape.ptr);
    call.asked_len = name_number_shape.len;
    codes[2] = publr_call_shaped(&call, &sizes);
    call.asked = address(numbers_shape.ptr);
    call.asked_len = numbers_shape.len;
    apply.name = .{
        .ptr = address(bad_name.ptr),
        .len = bad_name.len,
    };
    codes[3] = publr_call_shaped(&call, &sizes);
    apply.name = .{
        .ptr = address(applied_name.ptr),
        .len = applied_name.len,
    };
    call.answer = address(number_answer_shape.ptr);
    call.answer_len = number_answer_shape.len;
    codes[4] = if (fine == 0) publr_call_shaped(&call, &sizes) else 0;

    std.debug.assert(apply.values.len == many_max);

    return codes;
}
