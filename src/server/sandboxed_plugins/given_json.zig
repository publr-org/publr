//! A value a plugin handed over (`given.zig`), written as JSON for what core keeps as JSON
//! (a record's document, an event's payload, the log) and for the outer edge: an object of
//! its fields, a keyed list as an object of its pairs, a union as `{ "alternative": payload }`,
//! a decimal as its exact text.
const std = @import("std");
const free_value = @import("../../publr/free_value.zig");
const free_json = @import("../../sdk/free_json.zig");
const model_decimal = @import("../../model/decimal.zig");
const given_module = @import("given.zig");

const Given = given_module.Given;
const Absent = given_module.Absent;

pub const WriteError = given_module.Error || error{WriteFailed};

/// One text or number as JSON writes it.
pub fn encoded(writer: *std.Io.Writer, value: anytype) error{WriteFailed}!void {
    var encoder: std.json.Stringify = .{
        .writer = writer,
    };

    try encoder.write(value);
}

pub fn write(
    given: *Given,
    writer: *std.Io.Writer,
    node: u32,
    bytes: []const u8,
    absent: Absent,
) WriteError!void {
    const said = given.described.nodes[node];

    std.debug.assert(bytes.len >= given.described.span(node));

    switch (said.kind) {
        .int => if (said.decimal) {
            try write_decimal(given, writer, node, bytes);
        } else {
            try writer.print("{d}", .{given.int(node, bytes)});
        },
        .float => try encoded(writer, given.float(node, bytes)),
        .bool => try writer.writeAll(if (bytes[0] != 0) "true" else "false"),
        .text => try encoded(writer, try given.text(bytes)),
        .free => free_json.write(writer, .{
            .bytes = try given.free(bytes),
        }) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => return error.Invalid,
        },
        .enumeration => try encoded(writer, try given.tag(node, bytes)),
        .optional => if (given.present(node, bytes)) {
            try write(given, writer, said.child, bytes, absent);
        } else {
            try writer.writeAll("null");
        },
        .pointer => {
            try given.enter();
            defer given.leave();

            try write(given, writer, said.child, try given.pointee(node, bytes), absent);
        },
        .choice => {
            const held = try given.chosen(node);

            try given.enter();
            defer given.leave();

            try writer.writeByte('{');
            try encoded(writer, given.described.alternatives_of(node)[held.index].name);
            try writer.writeByte(':');
            try write(given, writer, held.node, held.bytes, absent);
            try writer.writeByte('}');
        },
        .list => try write_list(given, writer, node, bytes, absent),
        .object => try write_object(given, writer, node, bytes, absent),
    }
}

fn write_decimal(
    given: *Given,
    writer: *std.Io.Writer,
    node: u32,
    bytes: []const u8,
) WriteError!void {
    const said = given.described.nodes[node];
    var buffer: [model_decimal.text_len_max]u8 = undefined;

    std.debug.assert(said.decimal);

    if (said.places > model_decimal.places_max) {
        return error.Invalid;
    }

    const units: i64 = @intCast(given.int(node, bytes));

    try encoded(writer, model_decimal.text_of(units, said.places, &buffer));
}

/// A list as an array; a keyed one as an object, each pair's first field its key.
fn write_list(
    given: *Given,
    writer: *std.Io.Writer,
    node: u32,
    bytes: []const u8,
    absent: Absent,
) WriteError!void {
    const said = given.described.nodes[node];
    const list = try given.items(node, bytes);

    std.debug.assert(said.kind == .list);

    try given.enter();
    defer given.leave();

    try writer.writeByte(if (said.keyed) '{' else '[');

    for (0..list.count) |index| {
        const item = list.at(@intCast(index));

        if (index > 0) {
            try writer.writeByte(',');
        }

        if (said.keyed) {
            const pair = given.described.fields_of(said.child);

            try encoded(writer, try given.text(item[pair[0].offset..]));
            try writer.writeByte(':');
            try write(given, writer, pair[1].node, item[pair[1].offset..], absent);
        } else {
            try write(given, writer, said.child, item, absent);
        }
    }

    try writer.writeByte(if (said.keyed) '}' else ']');
}

fn write_object(
    given: *Given,
    writer: *std.Io.Writer,
    node: u32,
    bytes: []const u8,
    absent: Absent,
) WriteError!void {
    const said = given.described.nodes[node];
    const fields = given.described.fields_of(node);
    var written: u32 = 0;

    std.debug.assert(said.kind == .object);

    if (said.lone) {
        // What the other fields' unions wrote beside the block is passed all the same.
        try write(given, writer, fields[0].node, bytes[fields[0].offset..], absent);

        for (fields[1..]) |field| {
            try given.skip(field.node, bytes[field.offset..]);
        }

        return;
    }

    try writer.writeByte(if (said.tuple) '[' else '{');

    for (fields) |field| {
        const inside = bytes[field.offset..];
        const optional = given.described.nodes[field.node].kind == .optional;
        const none = optional and !given.present(field.node, inside);

        if (absent == .left_out and none and !said.tuple) {
            continue;
        }

        if (written > 0) {
            try writer.writeByte(',');
        }

        written += 1;

        if (!said.tuple) {
            try encoded(writer, field.name);
            try writer.writeByte(':');
        }

        try write(given, writer, field.node, inside, absent);
    }

    try writer.writeByte(if (said.tuple) ']' else '}');
}

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");

const Described = described_module.Described;

test "a signed int of any size reads with its sign; a tag outside its enum is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Shape = struct {
        small: i8,
        wide: i64,
        plain: u16,
        kind: enum(u8) { low = 1, high = 200 },
    };
    const described = try described_module.parse(arena, comptime shape_wire.describe(Shape));
    const value: Shape = .{
        .small = -3,
        .wide = std.math.minInt(i64),
        .plain = 0xfffe,
        .kind = .high,
    };
    var bytes: [@sizeOf(Shape)]u8 = undefined;

    @memcpy(&bytes, std.mem.asBytes(&value));

    var given: Given = .{
        .described = &described,
        .memory = .{
            .block = .{
                .base = 16,
                .bytes = &bytes,
            },
        },
        .arena = arena,
    };
    const window = try given.window(Described.root, 16);
    const text = try given.json_of(Described.root, window, .null);

    try std.testing.expectEqualStrings(
        "{\"small\":-3,\"wide\":-9223372036854775808,\"plain\":65534,\"kind\":\"high\"}",
        text,
    );

    bytes[@offsetOf(Shape, "kind")] = 7;
    try std.testing.expectError(error.Invalid, given.json_of(
        Described.root,
        try given.window(Described.root, 16),
        .null,
    ));

    // A value that begins before the memory, or runs past its end.
    try std.testing.expectError(error.Invalid, given.window(Described.root, 8));
    try std.testing.expectError(error.Invalid, given.window(Described.root, 17));
    try std.testing.expectError(error.Invalid, given.window(Described.root, 0xffff_fff0));
}

test "a text or a list that lies about where it is, or how long, is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const description = "o\x00\x10\x00\x00\x00\x02\x00\x00\x00" ++
        "\x04name\x00\x00\x00\x00\x00\x00\x00\x00s" ++
        "\x05items\x08\x00\x00\x00\x00\x00\x00\x00" ++
        "l\x00\x08\x00\x00\x00\x04\x00\x00\x00s";
    const described = try described_module.parse(arena, description);
    const base: u32 = 1024;
    // The struct's two slices, then a text of three bytes they may point at.
    var memory: [32]u8 = @splat(0);
    const cases = [_]struct {
        name: [2]u32,
        items: [2]u32,
        fine: bool,
    }{
        .{
            .name = .{ base + 16, 3 },
            .items = .{ base, 1 },
            .fine = true,
        },
        // Outside the memory: before it, past its end, at the top of the address space.
        .{
            .name = .{ base - 1, 3 },
            .items = .{ 0, 0 },
            .fine = false,
        },
        .{
            .name = .{ base + 30, 3 },
            .items = .{ 0, 0 },
            .fine = false,
        },
        .{
            .name = .{ 0xffff_fffe, 3 },
            .items = .{ 0, 0 },
            .fine = false,
        },
        // A length, and a count times its item's size, that overflow 32 bits.
        .{
            .name = .{ base + 16, 0xffff_ffff },
            .items = .{ 0, 0 },
            .fine = false,
        },
        .{
            .name = .{ base + 16, 3 },
            .items = .{ base, 0x2000_0001 },
            .fine = false,
        },
        .{
            .name = .{ base + 16, 3 },
            .items = .{ base, 0xffff_ffff },
            .fine = false,
        },
        // A text that is not UTF-8.
        .{
            .name = .{ base + 20, 2 },
            .items = .{ 0, 0 },
            .fine = false,
        },
    };

    @memcpy(memory[16..19], "Tea");
    @memcpy(memory[20..22], "\xff\xfe");

    for (cases) |case| {
        std.mem.writeInt(u32, memory[0..4], case.name[0], .little);
        std.mem.writeInt(u32, memory[4..8], case.name[1], .little);
        std.mem.writeInt(u32, memory[8..12], case.items[0], .little);
        std.mem.writeInt(u32, memory[12..16], case.items[1], .little);

        var given: Given = .{
            .described = &described,
            .memory = .{
                .block = .{
                    .base = base,
                    .bytes = &memory,
                },
            },
            .arena = arena,
        };
        const window = try given.window(Described.root, base);
        const written = given.json_of(Described.root, window, .null);

        if (case.fine) {
            const text = try written;

            try std.testing.expectEqualStrings("{\"name\":\"Tea\",\"items\":[\"Tea\"]}", text);
        } else {
            try std.testing.expectError(error.Invalid, written);
        }
    }
}

test "a value that points at the same bytes over and over is cut off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A list of lists of texts, every level pointing back at the same eight bytes.
    const description = "l\x00\x08\x00\x00\x00\x04\x00\x00\x00" ++
        "l\x00\x08\x00\x00\x00\x04\x00\x00\x00" ++ "l\x00\x08\x00\x00\x00\x04\x00\x00\x00s";
    const described = try described_module.parse(arena, description);
    const base: u32 = 1024;
    var memory: [64]u8 = undefined;

    for (0..8) |index| {
        std.mem.writeInt(u32, memory[index * 8 ..][0..4], base, .little);
        std.mem.writeInt(u32, memory[index * 8 + 4 ..][0..4], 8, .little);
    }

    var given: Given = .{
        .described = &described,
        .memory = .{
            .block = .{
                .base = base,
                .bytes = &memory,
            },
        },
        .arena = arena,
        .left = 200,
    };
    const window = try given.window(Described.root, base);

    // Each step is inside the memory; together they are more than a value may read.
    try std.testing.expectError(error.Invalid, given.json_of(Described.root, window, .null));
    try std.testing.expect(given.left < 8);
}
