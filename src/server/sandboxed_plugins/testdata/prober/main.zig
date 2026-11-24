//! Pokes the host with requests that are wrong.
//!
//! A plugin the sandbox is tested with. `prober poke` calls into Publr the way no plugin
//! built on the SDK does: with addresses outside its own memory, lengths that overflow, and
//! descriptions of its values that lie or are cut short. It answers how each call ended.
//! None of them may read or write past the plugin's memory, or stop the server.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "prober",
    .version = "0.1.0",
};

/// Where each part of a call is, as the host reads it.
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

extern "env" fn publr_call_shaped(call: *const Call, sizes: *[2]u32) u32;
extern "env" fn publr_shaped_take(block: u32, table: u32) u32;
extern "env" fn publr_answer(description: u32, len: u32, root: u32, table: u32, count: u32) u32;

/// Past the end of anything a plugin may hold.
const outside: u32 = 0xffff_fff0;

/// What `project.random` takes and answers, as an honest plugin describes it.
const Asked = extern struct {
    bytes: u32,
};
const object = "o\x00";
const list = "l\x00";
const asked_shape = object ++ word(4) ++ word(1) ++ "\x05bytes" ++ word(0) ++ word(0) ++
    "i\x04\x00";
const answer_shape = object ++ word(8) ++ word(1) ++ "\x03hex" ++ word(0) ++ word(0) ++ "s";
const operation_name = "project.random";

fn word(comptime value: u32) *const [4]u8 {
    comptime {
        var bytes: [4]u8 = undefined;

        std.debug.assert(value <= std.math.maxInt(u32));
        std.mem.writeInt(u32, &bytes, value, .little);

        const kept = bytes;

        return &kept;
    }
}

fn address(pointer: anytype) u32 {
    const at = @intFromPtr(pointer);

    std.debug.assert(at != 0);

    return @intCast(at);
}

/// An honest call: every case below changes one part of it.
fn honest(asked: *const Asked) Call {
    std.debug.assert(asked.bytes > 0);

    return .{
        .name = address(operation_name.ptr),
        .name_len = operation_name.len,
        .root = address(asked),
        .asked = address(asked_shape.ptr),
        .asked_len = asked_shape.len,
        .table = 0,
        .table_len = 0,
        .answer = address(answer_shape.ptr),
        .answer_len = answer_shape.len,
    };
}

/// A description of the request used in place of the honest one.
fn described(asked: *const Asked, shape: []const u8) Call {
    var call = honest(asked);

    std.debug.assert(shape.len > 0);

    call.asked = address(shape.ptr);
    call.asked_len = @intCast(shape.len);

    return call;
}

/// A slice that lies about where its bytes are.
const Slice = extern struct {
    ptr: u32,
    len: u32,
};

// A field said to lie past its struct's end; a text and a list in place of the number; an
// enum; a list nested deeper than any description may go.
const past_shape = object ++ word(4) ++ word(1) ++ "\x05bytes" ++ word(64) ++ word(0) ++
    "i\x04\x00";
const text_shape = object ++ word(8) ++ word(1) ++ "\x05bytes" ++ word(0) ++ word(0) ++ "s";
const list_shape = object ++ word(8) ++ word(1) ++ "\x05bytes" ++ word(0) ++ word(0) ++ list ++
    word(4) ++ word(4) ++ "i\x04\x00";
const enum_shape = object ++ word(4) ++ word(1) ++ "\x05bytes" ++ word(0) ++ word(0) ++
    "e\x04" ++ word(1) ++ "\x03one" ++ word(16) ++ word(0);
const deep_shape = nested(80);

/// A text inside `levels` lists.
fn nested(comptime levels: u32) []const u8 {
    comptime {
        var shape: []const u8 = "s";

        std.debug.assert(levels > 0);

        for (0..levels) |_| {
            shape = list ++ word(8) ++ word(4) ++ shape;
        }

        return shape;
    }
}

pub const PokeIn = struct {};

pub const PokeOut = struct {
    /// How the honest call ended: 0
    honest: u32,
    /// How each wrong call ended, in the order they were made
    refused: []const u32,
    /// How many random bytes the honest call made after all of them answered, as hex
    after: u32,
    /// How a call handing over every kind of value honestly ended: 0
    forms: u32,
    /// How a page of markup alone, handed over to be drawn, ended: 0
    page: u32,
    /// How each page that is wrong ended
    pages_refused: []const u32,
    /// How a page naming a component a plugin may not draw ended
    page_unknown: u32,
};

/// Call Publr in ways that are wrong
///
/// Anyone may call it. It changes nothing.
///
/// Example:
///   in: {}
///   out: { "honest": 0, "refused": [2], "after": 8, "forms": 0, "page": 0,
///     "pages_refused": [2], "page_unknown": 3 }
pub const Poke = publr.operation.define(PokeIn, PokeOut, .{
    .name = "poke",
    .kind = .read,
    .run = poke,
});

fn poke(ctx: *publr.Ctx, _: PokeIn) publr.Error!PokeOut {
    std.debug.assert(ctx.now().ms >= 0);

    const asked: Asked = .{
        .bytes = 4,
    };
    var codes: std.ArrayList(u32) = .empty;
    var sizes: [2]u32 = .{ 0, 0 };
    const first = publr_call_shaped(&honest(&asked), &sizes);

    for (try wrong_calls(ctx, &asked)) |call| {
        try codes.append(ctx.arena(), publr_call_shaped(&call, &sizes));
    }

    try codes.appendSlice(ctx.arena(), &wrong_values());
    try codes.appendSlice(ctx.arena(), &@import("forms.zig").wrong());
    try codes.appendSlice(ctx.arena(), &.{
        // Where the answer's sizes go, and where the answer itself goes: outside.
        publr_call_shaped(&honest(&asked), @ptrFromInt(outside)),
        publr_shaped_take(outside, 0),
        // Nothing waits to be taken any more.
        publr_shaped_take(address(&sizes), 0),
        // An answer described and lying outside the memory.
        publr_answer(outside, 8, address(&asked), 0, 0),
        publr_answer(address(asked_shape.ptr), asked_shape.len, outside, 0, 0),
        publr_answer(address(asked_shape.ptr), asked_shape.len, address(&asked), outside, 9),
        publr_answer(address(asked_shape.ptr), 0xffff_ffff, address(&asked), 0, 0),
    });

    const pages = @import("pages.zig").drawn();

    return .{
        .honest = first,
        .refused = codes.items,
        .after = try after(ctx, &asked),
        .forms = @import("forms.zig").honest(),
        .page = pages.honest,
        .pages_refused = ctx.arena().dupe(u32, &pages.refused) catch return error.OutOfMemory,
        .page_unknown = pages.unknown,
    };
}

/// Calls whose parts are outside the memory, too long, or not what they say.
fn wrong_calls(ctx: *publr.Ctx, asked: *const Asked) publr.Error![]const Call {
    var calls: std.ArrayList(Call) = .empty;
    var call = honest(asked);

    std.debug.assert(asked.bytes > 0);

    call.root = outside;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.name = outside;
    try calls.append(ctx.arena(), call);
    call.name_len = 0;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.name_len = 0xffff_ffff;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.asked = outside;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.asked_len = 0xffff_ffff;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.answer = outside;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.answer_len = 0xffff_ffff;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.table = outside;
    call.table_len = 4;
    try calls.append(ctx.arena(), call);
    call = honest(asked);
    call.table_len = 0xffff_ffff;
    try calls.append(ctx.arena(), call);

    // A description cut short, one whose field lies past its struct, one nested too deep,
    // and an answer described as something that is not a struct.
    try calls.append(ctx.arena(), described(asked, asked_shape[0 .. asked_shape.len - 2]));
    try calls.append(ctx.arena(), described(asked, past_shape));
    try calls.append(ctx.arena(), described(asked, deep_shape));
    call = honest(asked);
    call.answer = address(deep_shape.ptr);
    call.answer_len = deep_shape.len;
    try calls.append(ctx.arena(), call);

    return calls.items;
}

/// Values that lie: a text and a list whose bytes are outside the memory or longer than
/// it, a text that is not UTF-8, an enum holding a number that is none of its tags.
fn wrong_values() [6]u32 {
    const bad_text = "\xff\xfe";
    const values = [_]Slice{
        .{
            .ptr = outside,
            .len = 4,
        },
        .{
            .ptr = 64,
            .len = 0xffff_ffff,
        },
        .{
            .ptr = address(bad_text.ptr),
            .len = bad_text.len,
        },
    };
    var codes: [6]u32 = undefined;
    var sizes: [2]u32 = .{ 0, 0 };
    const none: Asked = .{
        .bytes = 4,
    };

    std.debug.assert(values.len == 3);

    for (&values, 0..) |*value, index| {
        var call = described(&none, text_shape);

        call.root = address(value);
        codes[index] = publr_call_shaped(&call, &sizes);
    }

    var listed = described(&none, list_shape);

    listed.root = address(&values[0]);
    codes[3] = publr_call_shaped(&listed, &sizes);
    listed.root = address(&values[1]);
    codes[4] = publr_call_shaped(&listed, &sizes);

    // Four is none of the enum's tags: its only one is 16.
    codes[5] = publr_call_shaped(&described(&none, enum_shape), &sizes);

    return codes;
}

/// The honest call once more, its answer taken: the host still answers as it should.
fn after(ctx: *publr.Ctx, asked: *const Asked) publr.Error!u32 {
    var sizes: [2]u32 = .{ 0, 0 };

    if (publr_call_shaped(&honest(asked), &sizes) != 0 or sizes[0] < @sizeOf(Slice)) {
        return error.Unavailable;
    }

    const block = ctx.arena().alignedAlloc(u8, .@"16", sizes[0]) catch return error.OutOfMemory;

    if (publr_shaped_take(address(block.ptr), 0) != 0) {
        return error.Unavailable;
    }

    const hex: *const Slice = @ptrCast(@alignCast(block.ptr));

    std.debug.assert(hex.ptr >= address(block.ptr));

    return hex.len;
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{Poke},
});
