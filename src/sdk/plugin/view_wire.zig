//! A design-system component's props on their way from an installed plugin's view to the host
//! that draws it: one JSON object, a field per prop. A node prop (children, `actions`, `empty`)
//! is drawn first, where the view runs, and travels as its HTML; the host takes it back as
//! markup drawn ahead of time. What only a render in one process means (the request, the
//! family roots) never travels: the host hands its own.
const std = @import("std");

pub const props_bytes_max: u32 = 1 << 20;

pub const Error = error{ Invalid, OutOfMemory, WriteFailed };

/// Whether `Type` is the render runtime's node: markup now or later, drawn by `render`.
pub fn is_node(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasField(Type, "render_fn") and
        @hasField(Type, "raw") and @hasDecl(Type, "is_empty");
}

/// A pointer to one thing (the request, the family roots): this process's alone.
fn is_local(comptime Type: type) bool {
    const info = @typeInfo(Type);

    comptime std.debug.assert(info != .@"opaque");

    if (info == .optional) {
        return is_local(info.optional.child);
    }

    return info == .pointer and info.pointer.size == .one;
}

/// `props` as the wire's JSON; `draw` turns a node into its HTML (`draw(node) ![]const u8`).
pub fn encode(
    arena: std.mem.Allocator,
    comptime Props: type,
    props: Props,
    draw: anytype,
) Error![]const u8 {
    comptime std.debug.assert(@typeInfo(Props) == .@"struct");

    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{
        .writer = &out.writer,
    };

    try json.beginObject();

    inline for (std.meta.fields(Props)) |field| {
        if (comptime !is_local(field.type)) {
            try json.objectField(field.name);
            try write_field(&json, field.type, @field(props, field.name), draw);
        }
    }

    try json.endObject();

    std.debug.assert(out.written().len >= 2);

    return out.written();
}

fn write_field(
    json: *std.json.Stringify,
    comptime Type: type,
    value: Type,
    draw: anytype,
) Error!void {
    comptime std.debug.assert(!is_local(Type));

    if (comptime is_node(Type)) {
        return json.write(try draw.node(value));
    }

    if (comptime @typeInfo(Type) == .optional and is_node(@typeInfo(Type).optional.child)) {
        if (value) |node| {
            return json.write(try draw.node(node));
        }

        return json.write(null);
    }

    try json.write(value);
}

/// The wire's JSON as `Props`: a node prop is markup drawn ahead of time (`Node.raw`), a prop
/// left out takes its default, and one with no default must be there.
pub fn decode(arena: std.mem.Allocator, comptime Props: type, text: []const u8) Error!Props {
    comptime std.debug.assert(@typeInfo(Props) == .@"struct");

    if (text.len == 0 or text.len > props_bytes_max) {
        return error.Invalid;
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return error.Invalid;
    };
    const object = if (parsed == .object) parsed.object else return error.Invalid;
    var props: Props = undefined;

    inline for (std.meta.fields(Props)) |field| {
        const given = if (comptime is_local(field.type)) null else object.get(field.name);

        if (given) |value| {
            @field(props, field.name) = try read_field(arena, field.type, value);
        } else if (field.defaultValue()) |default| {
            @field(props, field.name) = default;
        } else {
            return error.Invalid;
        }
    }

    return props;
}

fn read_field(arena: std.mem.Allocator, comptime Type: type, value: std.json.Value) Error!Type {
    comptime std.debug.assert(!is_local(Type));

    if (comptime is_node(Type)) {
        return .{
            .raw = if (value == .string) value.string else return error.Invalid,
        };
    }

    if (comptime @typeInfo(Type) == .optional and is_node(@typeInfo(Type).optional.child)) {
        return switch (value) {
            .null => null,
            .string => |html| .{
                .raw = html,
            },
            else => error.Invalid,
        };
    }

    return std.json.parseFromValueLeaky(Type, arena, value, .{
        .ignore_unknown_fields = true,
    }) catch error.Invalid;
}

/// Stands for the runtime's node in the tests: the same shape, markup now or a body later.
const TestNode = struct {
    raw: ?[]const u8 = null,
    ctx: *const anyopaque = undefined,
    render_fn: ?*const fn () void = null,

    pub fn is_empty(node: TestNode) bool {
        return (node.raw orelse "").len == 0;
    }
};

const TestProps = struct {
    title: []const u8,
    tone: enum { info, success } = .info,
    count: f64 = 0,
    rows: []const struct {
        name: []const u8,
    } = &.{},
    children: TestNode,
    actions: ?TestNode = null,
    publr_text_wire: ?[]const u8 = null,
    publr_request: ?*const anyopaque = null,
};

const TestDraw = struct {
    pub fn node(_: TestDraw, given: TestNode) Error![]const u8 {
        return given.raw orelse error.Invalid;
    }
};

test "props cross the wire: data as it is, nodes as their markup, the request left home" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const marker: u8 = 0;
    const text = try encode(arena, TestProps, .{
        .title = "Sampler log",
        .tone = .success,
        .count = 2,
        .rows = &.{.{
            .name = "a",
        }},
        .children = .{
            .raw = "<p>hi</p>",
        },
        .publr_request = &marker,
    }, TestDraw{});

    try std.testing.expect(std.mem.indexOf(u8, text, "publr_request") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"children\":\"<p>hi</p>\"") != null);

    const back = try decode(arena, TestProps, text);

    try std.testing.expectEqualStrings("Sampler log", back.title);
    try std.testing.expectEqual(.success, back.tone);
    try std.testing.expectEqualStrings("<p>hi</p>", back.children.raw.?);
    try std.testing.expect(back.actions == null);
    try std.testing.expect(back.publr_request == null);
    try std.testing.expectEqualStrings("a", back.rows[0].name);
}

test "a prop with no default must be there; anything but an object is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.Invalid, decode(arena, TestProps, "{\"title\":\"x\"}"));
    try std.testing.expectError(error.Invalid, decode(arena, TestProps, "[]"));
    try std.testing.expectError(error.Invalid, decode(arena, TestProps, ""));
    try std.testing.expectError(error.Invalid, decode(arena, TestProps, "{\"title\":1," ++
        "\"children\":\"\"}"));
}
