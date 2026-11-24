//! A value moved from one layout to another with nothing in between: read where it lies as
//! one plugin described it, built as another described it, fields and enum tags matched by
//! their names. A field only the sender has is left behind; one only the receiver has takes
//! its default. The same walk with one description on both sides copies a value out of a
//! plugin's memory whole (`held.zig`).
//!
//! No text is written or parsed on the way, but one case: a struct or a union one side has,
//! where the other takes a value whose shape comes with the data, is written as the JSON it
//! stands for and read back, once, here in core.
const std = @import("std");
const scalars = @import("transfer_scalars.zig");
const shapeless = @import("transfer_shapeless.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const laid_module = @import("laid.zig");

const Given = given_module.Given;
const Layout = laid_module.Layout;

pub const Error = error{ Invalid, OutOfMemory };

/// The value `from` at `bytes` built at `at` as `to` says.
pub fn move(
    layout: *Layout,
    to: u32,
    at: u32,
    given: *Given,
    from: u32,
    bytes: []const u8,
) Error!void {
    const want = layout.described.nodes[to];
    const have = given.described.nodes[from];

    std.debug.assert(bytes.len >= given.described.span(from));

    if (have.kind == .pointer) {
        try given.enter();
        defer given.leave();

        return move(layout, to, at, given, have.child, try given.pointee(from, bytes));
    }

    if (want.kind == .free or have.kind == .free) {
        return shapeless.move_free(layout, to, at, given, from, bytes);
    }

    if (have.kind == .optional) {
        if (!given.present(from, bytes)) {
            // Nothing, where the receiver's type must hold something.
            return if (want.kind == .optional) {} else error.Invalid;
        }

        return move(layout, to, at, given, have.child, bytes);
    }

    if (want.kind == .optional) {
        layout.present(to, at);

        return move(layout, want.child, at, given, from, bytes);
    }

    if (want.kind == .pointer) {
        return move(layout, want.child, try layout.pointee(to, at), given, from, bytes);
    }

    if (want.kind == .choice or have.kind == .choice) {
        return shapeless.move_choice(layout, to, at, given, from, bytes);
    }

    // A reference one side keeps whole and the other as its id alone.
    if (have.kind == .object and have.lone and want.kind != .object) {
        const first = given.described.fields_of(from)[0];

        try move(layout, to, at, given, first.node, bytes[first.offset..]);

        return pass(given, given.described.fields_of(from)[1..], bytes);
    }

    switch (want.kind) {
        .int => try layout.int(to, at, try scalars.int_of(given, want, from, bytes)),
        .float => layout.float(to, at, try scalars.float_of(given, from, bytes)),
        .bool => layout.boolean(at, if (have.kind == .bool) bytes[0] != 0 else {
            return error.Invalid;
        }),
        .text => try layout.text(at, try scalars.name_of(given, from, bytes)),
        .enumeration => if (have.kind == .int)
            try layout.tag_numbered(to, at, std.math.cast(i64, given.int(from, bytes)) orelse {
                return error.Invalid;
            })
        else
            try layout.tag(to, at, try scalars.name_of(given, from, bytes)),
        .list => try move_list(layout, to, at, given, from, bytes),
        .object => try move_object(layout, to, at, given, from, bytes),
        .free, .optional, .pointer, .choice => unreachable,
    }
}

fn move_list(
    layout: *Layout,
    to: u32,
    at: u32,
    given: *Given,
    from: u32,
    bytes: []const u8,
) Error!void {
    const want = layout.described.nodes[to];
    const have = given.described.nodes[from];

    if (have.kind != .list) {
        return error.Invalid;
    }

    const list = try given.items(from, bytes);
    const where = try layout.items(to, at, list.count);

    std.debug.assert(want.kind == .list);

    try given.enter();
    defer given.leave();

    for (0..list.count) |index| {
        const position: u32 = @intCast(index);

        try move(layout, want.child, where + want.size * position, given, have.child, list.at(
            position,
        ));
    }
}

/// The receiver's fields in its own order, each from the sender's field of that name. The
/// sender's parts beside the block were written in the sender's order: when the two orders
/// differ, the place among them is found again for each field.
fn move_object(
    layout: *Layout,
    to: u32,
    at: u32,
    given: *Given,
    from: u32,
    bytes: []const u8,
) Error!void {
    const want = layout.described.nodes[to];

    // A reference sent as its id alone: the first field, the others at their defaults.
    if (want.lone and given.described.nodes[from].kind != .object) {
        const fields = layout.described.fields_of(to);

        try move(layout, fields[0].node, at + fields[0].offset, given, from, bytes);

        for (fields[1..]) |field| {
            try layout.left_out(field, at + field.offset);
        }

        return;
    }

    if (given.described.nodes[from].kind != .object) {
        return error.Invalid;
    }

    const sent = given.described.fields_of(from);
    const tabled = given.described.nodes[from].choosy;
    const start = given.next;
    // The sender's fields before this one are passed: the side table stands at it.
    var passed: u32 = 0;

    std.debug.assert(layout.described.nodes[to].kind == .object);

    for (layout.described.fields_of(to), 0..) |field, position| {
        const index = given.described.field_named(from, field.name, @intCast(position)) orelse {
            try layout.left_out(field, at + field.offset);
            continue;
        };
        const found = sent[index];
        const inside = bytes[found.offset..];

        if (tabled) {
            if (index < passed) {
                given.next = start;
                passed = 0;
            }

            try pass(given, sent[passed..index], bytes);
            passed = index + 1;
        }

        if (absent_for(layout, field.node, given, found.node, inside)) {
            try layout.left_out(field, at + field.offset);
        } else {
            try move(layout, field.node, at + field.offset, given, found.node, inside);
        }
    }

    if (tabled) {
        try pass(given, sent[passed..], bytes);
    }
}

/// Steps over `fields` of the sender's object at `bytes`.
fn pass(given: *Given, fields: []const described_module.Field, bytes: []const u8) Error!void {
    std.debug.assert(fields.len <= described_module.nodes_max);

    for (fields) |field| {
        try given.skip(field.node, bytes[field.offset..]);
    }
}

/// Whether the sender's field holds nothing where the receiver's cannot say so: its default
/// stands in.
fn absent_for(layout: *Layout, to: u32, given: *Given, from: u32, bytes: []const u8) bool {
    const want = layout.described.nodes[to].kind;

    std.debug.assert(from < given.described.nodes.len);

    if (want == .optional or want == .free or given.described.nodes[from].kind != .optional) {
        return false;
    }

    return !given.present(from, bytes);
}

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");

test "a value moves between two layouts by its fields' names; zero lies between them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Sent = struct {
        count: u16,
        kind: enum { item, step },
        weight: ?f32,
        inner: struct {
            on: bool,
            level: ?i8,
        },
        extra: u64,
        size: ?i8,
    };
    const Wanted = struct {
        on_top: bool = true,
        kind: enum(u8) { step = 4, item = 9 },
        weight: ?f64,
        count: u64,
        inner: struct {
            level: ?i32,
            on: bool,
        },
        size: i8 = -2,
    };
    const sent: Sent = .{
        .count = 7,
        .kind = .step,
        .weight = 1.5,
        .inner = .{
            .on = true,
            .level = null,
        },
        .extra = 99,
        .size = null,
    };
    const from = try described_module.parse(arena, comptime shape_wire.describe(Sent));
    const to = try described_module.parse(arena, comptime shape_wire.describe(Wanted));
    var given: Given = .{
        .described = &from,
        .memory = .{
            .block = .{
                .base = 64,
                .bytes = std.mem.asBytes(&sent),
            },
        },
        .arena = arena,
    };
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = arena,
        .scratch = arena,
        .described = &to,
        .laid = &laid,
    };

    try layout.begin();
    try move(&layout, 0, 0, &given, 0, try given.window(0, 64));

    // These types hold no address: a 64-bit host lays them out as a plugin does.
    var wanted: Wanted = undefined;

    @memcpy(std.mem.asBytes(&wanted), laid.block.items[0..@sizeOf(Wanted)]);
    try std.testing.expect(wanted.on_top and wanted.kind == .step and wanted.count == 7);
    try std.testing.expect(wanted.weight.? == 1.5 and wanted.size == -2);
    try std.testing.expect(wanted.inner.on and wanted.inner.level == null);

    // Nothing of the sender's, or of core's, lies between the fields: the padding is zero.
    try std.testing.expect(try described_module.padding_is_zero(&to, laid.block.items));
}

test "a tag outside its enum, a number too large and a missing field end the move" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Sent = struct {
        kind: enum(u8) { item, step },
        count: u32,
    };
    const from = try described_module.parse(arena, comptime shape_wire.describe(Sent));
    var sent: Sent = .{
        .kind = .step,
        .count = 300,
    };
    const cases = [_]type{
        struct {
            kind: enum { item, step },
            count: u8,
        },
        struct {
            kind: enum { item, other },
        },
        struct {
            count: u32,
            name: bool,
        },
    };

    inline for (cases) |Wanted| {
        const to = try described_module.parse(arena, comptime shape_wire.describe(Wanted));
        var given: Given = .{
            .described = &from,
            .memory = .{
                .block = .{
                    .base = 64,
                    .bytes = std.mem.asBytes(&sent),
                },
            },
            .arena = arena,
        };
        var laid: laid_module.Laid = .{};
        var layout: Layout = .{
            .gpa = arena,
            .scratch = arena,
            .described = &to,
            .laid = &laid,
        };

        try layout.begin();
        try std.testing.expectError(
            error.Invalid,
            move(&layout, 0, 0, &given, 0, try given.window(0, 64)),
        );
    }

    // A byte that is none of the sender's own tags never reaches the receiver.
    std.mem.asBytes(&sent)[@offsetOf(Sent, "kind")] = 9;

    const Same = struct {
        kind: enum(u8) { item, step },
    };
    const to = try described_module.parse(arena, comptime shape_wire.describe(Same));
    var given: Given = .{
        .described = &from,
        .memory = .{
            .block = .{
                .base = 64,
                .bytes = std.mem.asBytes(&sent),
            },
        },
        .arena = arena,
    };
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = arena,
        .scratch = arena,
        .described = &to,
        .laid = &laid,
    };

    try layout.begin();
    try std.testing.expectError(
        error.Invalid,
        move(&layout, 0, 0, &given, 0, try given.window(0, 64)),
    );
}
