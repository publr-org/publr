//! A value core keeps between two plugins: copied whole out of the plugin that handed it over
//! (its memory may change or be given back before the other runs), in the layout that plugin
//! described, as one piece of bytes that can be copied and moved like any text. The piece is
//! the description, then the value's block placed at `base`, then its side table.
//!
//! A piece is only ever made here, from a value read with every check (`given.zig`); it is
//! read back with the same checks all the same.
const std = @import("std");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const laid_module = @import("laid.zig");
const transfer = @import("transfer.zig");

const Described = described_module.Described;
const Given = given_module.Given;

pub const Error = error{ Invalid, OutOfMemory };

/// Where a piece's block is placed: its addresses are never zero, which says none.
const base: u32 = 16;

const Header = extern struct {
    description_len: u32,
    block_len: u32,
    table_len: u32,
};

/// The value `given` describes, at `root` in its memory, copied whole: one piece in `arena`.
/// `scratch` holds what building it takes for a moment.
pub fn keep(
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    given: *Given,
    root: u32,
) Error![]u8 {
    var laid: laid_module.Laid = .{};
    var layout: laid_module.Layout = .{
        .gpa = scratch,
        .scratch = scratch,
        .described = given.described,
        .laid = &laid,
    };
    const window = try given.window(Described.root, root);

    try layout.begin();
    try transfer.move(&layout, Described.root, 0, given, Described.root, window);

    return pieced(arena, given.described.text, &laid);
}

/// `laid`, a value built by the description `text`, placed and made one piece in `arena`.
pub fn pieced(arena: std.mem.Allocator, text: []const u8, laid: *laid_module.Laid) Error![]u8 {
    std.debug.assert(text.len > 0);
    std.debug.assert(laid.block.items.len > 0);

    laid.place(base);

    const table = std.mem.sliceAsBytes(laid.table.items);
    const header: Header = .{
        .description_len = @intCast(text.len),
        .block_len = @intCast(laid.block.items.len),
        .table_len = @intCast(laid.table.items.len),
    };

    return std.mem.concat(arena, u8, &.{
        std.mem.asBytes(&header),
        text,
        laid.block.items,
        table,
    }) catch error.OutOfMemory;
}

/// A piece opened to be read: its description, and where its value lies.
pub const Held = struct {
    described: Described,
    block: []const u8,
    table: []const shape_wire.Entry,

    /// The piece's value, to read with `window`.
    pub fn given(held: *const Held, arena: std.mem.Allocator) Given {
        std.debug.assert(held.block.len > 0);

        return .{
            .described = &held.described,
            .memory = .{
                .block = .{
                    .base = base,
                    .bytes = held.block,
                },
            },
            .arena = arena,
            .table = held.table,
        };
    }

    /// The bytes of the piece's root value.
    pub fn window(held: *const Held, reading: *Given) Error![]const u8 {
        std.debug.assert(reading.described == &held.described);

        return reading.window(Described.root, base);
    }
};

/// `piece` opened; its description's parts and its side table are in `arena`, its block
/// stays where the piece is.
pub fn open(arena: std.mem.Allocator, piece: []const u8) Error!Held {
    var header: Header = undefined;

    if (piece.len < @sizeOf(Header)) {
        return error.Invalid;
    }

    std.debug.assert(piece.len >= @sizeOf(Header));

    @memcpy(std.mem.asBytes(&header), piece[0..@sizeOf(Header)]);

    const table_bytes = @as(u64, header.table_len) * @sizeOf(shape_wire.Entry);
    const total = @sizeOf(Header) + @as(u64, header.description_len) + header.block_len +
        table_bytes;

    if (total != piece.len or header.block_len == 0) {
        return error.Invalid;
    }

    const text = piece[@sizeOf(Header)..][0..header.description_len];
    const block = piece[@sizeOf(Header) + text.len ..][0..header.block_len];
    const table = arena.alloc(shape_wire.Entry, header.table_len) catch return error.OutOfMemory;

    @memcpy(std.mem.sliceAsBytes(table), piece[piece.len - @as(usize, @intCast(table_bytes)) ..]);

    return .{
        .described = try described_module.parse(arena, text),
        .block = block,
        .table = table,
    };
}

/// How many bytes of `piece` are the value itself: what a plugin's answer is measured by.
pub fn value_bytes(piece: []const u8) u32 {
    var header: Header = undefined;

    std.debug.assert(piece.len >= @sizeOf(Header));

    @memcpy(std.mem.asBytes(&header), piece[0..@sizeOf(Header)]);

    return header.block_len;
}

/// How a piece is written as JSON for what core keeps as JSON (the log, a queued event) and
/// for the outer edge.
pub const Form = enum {
    /// What a plugin sent: the call's own fields always written, an optional holding nothing
    /// as `null`; inside its values (a record's document) one that is not there is left
    /// out, as the plugin's own JSON writer leaves it out.
    request,
    /// What a plugin answered: a field that is not there is `null`.
    answer,
};

/// `piece` as JSON text, in `arena`.
pub fn json_of(arena: std.mem.Allocator, piece: []const u8, form: Form) Error![]const u8 {
    const held = try open(arena, piece);
    var reading = held.given(arena);
    const window = try held.window(&reading);

    std.debug.assert(piece.len > @sizeOf(Header));

    return switch (form) {
        .request => request_json(&reading, window),
        .answer => reading.json_of(Described.root, window, .null),
    };
}

/// The value at `window` as a request's JSON (`Form.request`).
pub fn request_json(reading: *Given, window: []const u8) Error![]const u8 {
    const described = reading.described;

    if (described.nodes[Described.root].kind != .object) {
        return reading.json_of(Described.root, window, .left_out);
    }

    var output: std.Io.Writer.Allocating = .init(reading.arena);

    request_fields(reading, &output.writer, window) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };

    std.debug.assert(output.written().len >= 2);

    return output.written();
}

fn request_fields(
    reading: *Given,
    writer: *std.Io.Writer,
    window: []const u8,
) Given.WriteError!void {
    const fields = reading.described.fields_of(Described.root);

    std.debug.assert(fields.len <= described_module.nodes_max);

    try writer.writeByte('{');

    for (fields, 0..) |field, index| {
        if (index > 0) {
            try writer.writeByte(',');
        }

        try given_module.encoded(writer, field.name);
        try writer.writeByte(':');
        try reading.write_json(writer, field.node, window[field.offset..], .left_out);
    }

    try writer.writeByte('}');
}

/// The text of the root's field `name` in `piece`: the content type a call names. Null when
/// the piece has no such text.
pub fn text_field(arena: std.mem.Allocator, piece: []const u8, name: []const u8) ?[]const u8 {
    const held = open(arena, piece) catch return null;
    var reading = held.given(arena);
    const described = &held.described;

    std.debug.assert(name.len > 0);

    if (described.nodes[Described.root].kind != .object) {
        return null;
    }

    const window = held.window(&reading) catch return null;
    const index = described.field_named(Described.root, name, 0) orelse return null;
    const field = described.fields_of(Described.root)[index];
    var node = field.node;
    const inside = window[field.offset..];

    if (described.nodes[node].kind == .optional) {
        if (!reading.present(node, inside)) {
            return null;
        }

        node = described.nodes[node].child;
    }

    if (described.nodes[node].kind != .text) {
        return null;
    }

    return reading.text(inside) catch null;
}

test "a value is kept whole in one piece and read back as it was" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Line = struct {
        count: u16,
        kind: enum { item, step },
        weight: ?f32,
        inner: struct {
            on: bool,
            level: ?i8,
        },
    };
    const line: Line = .{
        .count = 7,
        .kind = .step,
        .weight = null,
        .inner = .{
            .on = true,
            .level = -1,
        },
    };
    const described = try described_module.parse(arena, comptime shape_wire.describe(Line));
    var given: Given = .{
        .described = &described,
        .memory = .{
            .block = .{
                .base = 4096,
                .bytes = std.mem.asBytes(&line),
            },
        },
        .arena = arena,
    };
    const piece = try keep(arena, arena, &given, 4096);

    try std.testing.expectEqualStrings(
        "{\"count\":7,\"kind\":\"step\",\"weight\":null,\"inner\":{\"on\":true,\"level\":-1}}",
        try json_of(arena, piece, .answer),
    );
    try std.testing.expectEqualStrings(
        "{\"count\":7,\"kind\":\"step\",\"weight\":null,\"inner\":{\"on\":true,\"level\":-1}}",
        try json_of(arena, piece, .request),
    );
    try std.testing.expect(text_field(arena, piece, "type") == null);
    try std.testing.expectEqual(@as(u32, @sizeOf(Line)), value_bytes(piece));

    // A piece cut short, or one whose lengths do not add up, is not opened.
    try std.testing.expectError(error.Invalid, open(arena, piece[0 .. piece.len - 1]));
    try std.testing.expectError(error.Invalid, open(arena, piece[0..8]));

    // A value that lies outside the memory it came from is never kept.
    try std.testing.expectError(error.Invalid, keep(arena, arena, &given, 4097));
}
