//! A value a plugin hands over, read straight into one of core's own types: fields found by
//! their names, enum tags by theirs, an optional holding nothing as `null`. No JSON is written
//! or parsed on the way, but where core's own type is JSON by its definition: what core keeps
//! as JSON (`operation.Json`, written once from where the value lies) and a type that says
//! how it reads from JSON (`jsonParse`), which reads what `given_json.zig` writes.
const std = @import("std");
const operation = @import("../../sdk/operation.zig");
const dimension_input = @import("../../sdk/dimension_input.zig");
const json = @import("../../lib/json.zig");
const given_module = @import("given.zig");
const given_object = @import("given_object.zig");

const Given = given_module.Given;

pub const Error = given_module.Error;

pub const Options = struct {
    /// A field the type does not have is left behind rather than refused.
    ignore_unknown: bool = false,
    /// How an optional holding nothing is written into what core keeps as JSON.
    absent: given_module.Absent = .left_out,
};

/// Whether `Shape` reads and writes itself as JSON in a way only it knows.
pub fn through_json(comptime Shape: type) bool {
    comptime {
        std.debug.assert(Shape != operation.Json);

        return switch (@typeInfo(Shape)) {
            .int => |info| info.bits > 64,
            .float, .bool, .optional => false,
            .@"enum" => |info| info.mode == .nonexhaustive or own_json(Shape),
            .pointer => |info| info.size != .slice or info.sentinel() != null,
            .@"struct" => |info| info.is_tuple or info.layout == .@"packed" or own_json(Shape),
            else => true,
        };
    }
}

/// A type writing or reading its own JSON goes through it, unless it says it lies by its
/// fields (`publr_form = .fields`): its JSON is only how it is written for people.
fn own_json(comptime Shape: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Shape) == .@"struct" or @typeInfo(Shape) == .@"enum");

        const by_fields = @hasDecl(Shape, "publr_form") and
            std.mem.eql(u8, @tagName(Shape.publr_form), "fields");

        if (by_fields) {
            return false;
        }

        return std.meta.hasFn(Shape, "jsonParse") or std.meta.hasFn(Shape, "jsonStringify") or
            std.meta.hasFn(Shape, "jsonParseFromValue");
    }
}

/// The value of `node` at `bytes` as a `Shape`, everything it holds copied into the arena of
/// `given`.
pub fn read(
    comptime Shape: type,
    given: *Given,
    node: u32,
    bytes: []const u8,
    options: Options,
) Error!Shape {
    const said = given.described.nodes[node];

    std.debug.assert(bytes.len >= given.described.span(node));

    if (Shape == operation.Json) {
        return .{
            .text = try given.json_of(node, bytes, options.absent),
        };
    }

    // A value whose shape comes with the data, or a union, where core's type is a plain
    // one: read as the JSON it stands for.
    const shapeless = said.kind == .free or said.kind == .choice;

    if (comptime through_json(Shape)) {
        return parsed(Shape, given, try given.json_of(node, bytes, options.absent), options);
    } else if (shapeless) {
        return parsed(Shape, given, try given.json_of(node, bytes, options.absent), options);
    }

    if (said.kind == .pointer) {
        try given.enter();
        defer given.leave();

        return read(Shape, given, said.child, try given.pointee(node, bytes), options);
    }

    if (@typeInfo(Shape) == .optional) {
        if (said.kind == .optional and !given.present(node, bytes)) {
            return null;
        }

        return try read(@typeInfo(Shape).optional.child, given, node, bytes, options);
    }

    // Something that may be absent, read where it must be there.
    if (said.kind == .optional) {
        if (!given.present(node, bytes)) {
            return error.Invalid;
        }

        return read(Shape, given, said.child, bytes, options);
    }

    // A reference the plugin keeps whole, where core's type is its id alone.
    if (said.kind == .object and said.lone and comptime @typeInfo(Shape) != .@"struct") {
        const fields = given.described.fields_of(node);
        const id = try read(Shape, given, fields[0].node, bytes[fields[0].offset..], options);

        for (fields[1..]) |field| {
            try given.skip(field.node, bytes[field.offset..]);
        }

        return id;
    }

    return switch (@typeInfo(Shape)) {
        .int => int_of(Shape, given, node, bytes),
        .float => float_of(Shape, given, node, bytes),
        .bool => if (said.kind == .bool) bytes[0] != 0 else error.Invalid,
        .@"enum" => enum_of(Shape, given, node, bytes),
        .pointer => |info| if (info.child == u8)
            @constCast(try text_of(given, node, bytes))
        else
            list_of(info.child, given, node, bytes, options),
        .@"struct" => object_of(Shape, given, node, bytes, options),
        else => @compileError(@typeName(Shape) ++ " is read through its JSON"),
    };
}

fn parsed(comptime Shape: type, given: *Given, text: []const u8, options: Options) Error!Shape {
    std.debug.assert(text.len > 0);

    return json.parse(Shape, given.arena, text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = options.ignore_unknown,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

fn int_of(comptime Shape: type, given: *Given, node: u32, bytes: []const u8) Error!Shape {
    const said = given.described.nodes[node];

    std.debug.assert(said.kind != .optional and said.kind != .free);

    switch (said.kind) {
        .int => return std.math.cast(Shape, given.int(node, bytes)) orelse error.Invalid,
        .float => {
            const real = given.float(node, bytes);

            if (@round(real) != real or @abs(real) >= 1 << 62) {
                return error.Invalid;
            }

            return std.math.cast(Shape, @as(i64, @intFromFloat(real))) orelse error.Invalid;
        },
        .text => return std.fmt.parseInt(Shape, try given.text(bytes), 10) catch error.Invalid,
        else => return error.Invalid,
    }
}

fn float_of(comptime Shape: type, given: *Given, node: u32, bytes: []const u8) Error!Shape {
    const said = given.described.nodes[node];

    std.debug.assert(said.kind != .optional and said.kind != .free);

    return switch (said.kind) {
        .float => @floatCast(given.float(node, bytes)),
        .int => @floatFromInt(given.int(node, bytes)),
        .text => std.fmt.parseFloat(Shape, try given.text(bytes)) catch error.Invalid,
        else => error.Invalid,
    };
}

fn enum_of(comptime Shape: type, given: *Given, node: u32, bytes: []const u8) Error!Shape {
    const said = given.described.nodes[node];

    std.debug.assert(said.kind != .optional and said.kind != .free);

    switch (said.kind) {
        .enumeration => {
            const name = try given.tag(node, bytes);

            return std.meta.stringToEnum(Shape, name) orelse error.Invalid;
        },
        .text => return std.meta.stringToEnum(Shape, try given.text(bytes)) orelse error.Invalid,
        .int => {
            const number = given.int(node, bytes);

            inline for (@typeInfo(Shape).@"enum".field_names) |name| {
                if (@backingInt(@field(Shape, name)) == number) {
                    return @field(Shape, name);
                }
            }

            return error.Invalid;
        },
        else => return error.Invalid,
    }
}

fn text_of(given: *Given, node: u32, bytes: []const u8) Error![]const u8 {
    const said = given.described.nodes[node];

    std.debug.assert(said.kind != .optional and said.kind != .free);

    return switch (said.kind) {
        .text => given.text(bytes),
        // The description is given back before the value is: the name is copied.
        .enumeration => given.arena.dupe(u8, try given.tag(node, bytes)) catch error.OutOfMemory,
        else => error.Invalid,
    };
}

fn list_of(
    comptime Item: type,
    given: *Given,
    node: u32,
    bytes: []const u8,
    options: Options,
) Error![]Item {
    const said = given.described.nodes[node];

    if (said.kind != .list) {
        return error.Invalid;
    }

    const list = try given.items(node, bytes);
    const made = given.arena.alloc(Item, list.count) catch return error.OutOfMemory;

    try given.enter();
    defer given.leave();

    for (made, 0..) |*item, index| {
        item.* = try read(Item, given, said.child, list.at(@intCast(index)), options);
    }

    std.debug.assert(made.len == list.count);

    return made;
}

pub const index_of = given_object.index_of;
pub const carried = given_object.carried;
const object_of = given_object.object_of;

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");

/// `value`, a plugin's own type, where it lies, for a test to read back. Types without
/// addresses only: a slice is laid out as a plugin's in a 32-bit build alone, and the test
/// plugins send real ones (`scenarios_laid_out.zig`).
fn TestBlock(comptime Sent: type) type {
    return struct {
        described: described_module.Described,
        given: Given,

        const base: u32 = 64;

        fn init(self: *@This(), arena: std.mem.Allocator, value: *const Sent) !void {
            self.described = try described_module.parse(arena, comptime shape_wire.describe(Sent));
            self.given = .{
                .described = &self.described,
                .memory = .{
                    .block = .{
                        .base = base,
                        .bytes = std.mem.asBytes(value),
                    },
                },
                .arena = arena,
            };
        }
    };
}

test "a struct is read by its fields' names: null as null, a default for what is not sent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Sent = struct {
        count: u16,
        kind: enum { item, step },
        weight: ?f32,
        inner: ?struct {
            on: bool,
            level: ?i8,
        },
        extra: u8,
        language: enum { pl, en },
    };
    const Core = struct {
        kind: enum { step, item },
        count: u64,
        weight: ?f64,
        inner: ?struct {
            level: ?i32,
            on: bool,
        },
        limit: u32 = 9,
    };
    const sent: Sent = .{
        .count = 7,
        .kind = .step,
        .weight = null,
        .inner = .{
            .on = true,
            .level = null,
        },
        .extra = 1,
        .language = .pl,
    };
    var block: TestBlock(Sent) = undefined;

    try block.init(arena, &sent);

    const given = &block.given;
    const window = try given.window(0, TestBlock(Sent).base);
    const core = try read(Core, given, 0, window, .{
        .ignore_unknown = true,
    });

    try std.testing.expectEqual(@as(u64, 7), core.count);
    try std.testing.expect(core.kind == .step);
    try std.testing.expect(core.weight == null);
    try std.testing.expect(core.inner.?.on and core.inner.?.level == null);
    try std.testing.expectEqual(@as(u32, 9), core.limit);

    // A field core does not have is refused from anyone but a plugin's own code.
    try std.testing.expectError(error.Invalid, read(Core, given, 0, window, .{}));

    // One that must be there and has no default is missed; a number too large is refused.
    const Needy = struct {
        count: u8,
        name: u32,
    };
    const Small = struct {
        count: u2,
    };
    const loose: Options = .{
        .ignore_unknown = true,
    };

    try std.testing.expectError(error.Invalid, read(Needy, given, 0, window, loose));
    try std.testing.expectError(error.Invalid, read(Small, given, 0, window, loose));

    // A key per dimension beside the operation's own fields is gathered.
    const Asked = struct {
        count: u16,
        dimensions: dimension_input.Dimensions = .{},
    };
    const Narrow = struct {
        count: u16,
        language: enum { pl, en },
    };
    const narrow: Narrow = .{
        .count = 2,
        .language = .en,
    };
    var other: TestBlock(Narrow) = undefined;

    try other.init(arena, &narrow);

    const asked = try read(Asked, &other.given, 0, try other.given.window(
        0,
        TestBlock(Narrow).base,
    ), .{});

    try std.testing.expectEqual(@as(usize, 1), asked.dimensions.pairs.len);
    try std.testing.expectEqualStrings("language", asked.dimensions.pairs[0].dimension);
    try std.testing.expectEqualStrings("en", asked.dimensions.pairs[0].code);
}
