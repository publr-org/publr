//! What an installed plugin's view hands the host to draw, once for a whole page: its own
//! markup, and every design-system component it reached, each a name and its props where
//! they lie in the plugin's memory, laid out as the plugin's build describes them
//! (`shape_wire.zig`). Where a component goes in the markup, a placeholder stands
//! (`<publr-drawn n="3">`); a node prop (children, `actions`, `empty`) is markup too, with
//! placeholders for the components inside it, so a tree of any depth travels flat and no
//! markup is written twice. What only a render in one process means (the request, the family
//! roots) never travels: the host hands its own.
const std = @import("std");
const shape_wire = @import("shape_wire.zig");
const shape_said = @import("shape_said.zig");

/// The most components one page asks for, and the most its own markup takes.
pub const components_max: u32 = 4096;
pub const markup_bytes_max: u32 = 4 << 20;
pub const name_len_max: u32 = 64;

/// The tag standing where a component goes; `n` is its place in the page's components.
/// Attributes a writer around it puts on a component's root land on it, and the host moves
/// them onto the root it draws.
pub const placeholder_tag = "publr-drawn";
pub const placeholder_number = "n";

/// A page to draw (`publr_draw`): where its markup and its components are.
pub const Page = extern struct {
    markup: u32,
    markup_len: u32,
    components: u32,
    components_len: u32,
};

/// One component of a page: its name, how its props lie (`describe`), where they are, and
/// their unions beside them (`shape_parts.zig`).
pub const Component = extern struct {
    name: u32,
    name_len: u32,
    described: u32,
    described_len: u32,
    props: u32,
    table: u32 = 0,
    table_len: u32 = 0,
};

/// Whether `Type` is the render runtime's node: markup now or later, drawn by `render`.
pub fn is_node(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasField(Type, "render_fn") and
        @hasField(Type, "raw") and @hasDecl(Type, "is_empty");
}

/// The node `Type` is or may hold; null for any other type.
pub fn node_of(comptime Type: type) ?type {
    comptime {
        std.debug.assert(@typeInfo(Type) != .@"opaque");

        if (is_node(Type)) {
            return Type;
        }

        if (@typeInfo(Type) == .optional and is_node(@typeInfo(Type).optional.child)) {
            return @typeInfo(Type).optional.child;
        }

        return null;
    }
}

/// A pointer to one thing (the request, the family roots): this process's alone.
pub fn is_local(comptime Type: type) bool {
    const info = @typeInfo(Type);

    comptime std.debug.assert(info != .@"opaque");

    if (info == .optional) {
        return is_local(info.optional.child);
    }

    return info == .pointer and info.pointer.size == .one;
}

/// Whether field `name` of a component's props is handed to the host.
pub fn crosses(comptime Props: type, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(@typeInfo(Props) == .@"struct");

        return !is_local(@FieldType(Props, name));
    }
}

/// How `Props` lies in this build, as the host reads it: each field that crosses by its
/// name, a node as the text its `raw` holds (none for a node left out).
pub fn describe(comptime Props: type) []const u8 {
    comptime {
        @setEvalBranchQuota(shape_wire.nodes_max * shape_wire.steps_per_node);

        const info = @typeInfo(Props).@"struct";
        var fields: []const u8 = "";
        var count: u32 = 0;

        for (info.field_names, info.field_types) |name, Field| {
            if (!crosses(Props, name)) {
                continue;
            }

            const offset = @offsetOf(Props, name);
            const part = if (node_of(Field)) |Node|
                shape_wire.word(offset + @offsetOf(Node, "raw")) ++ shape_wire.word(0) ++
                    shape_said.said(?[]const u8, &.{}, false)
            else
                shape_wire.word(offset) ++ shape_wire.word(0) ++
                    shape_said.said(Field, &.{Props}, false);

            fields = fields ++ &[_]u8{name.len} ++ name ++ part;
            count += 1;
        }

        std.debug.assert(count <= info.field_names.len);

        return "o\x00" ++ shape_wire.word(@sizeOf(Props)) ++ shape_wire.word(count) ++ fields;
    }
}

/// The placeholder for component `number`, as markup.
pub fn write_placeholder(writer: *std.Io.Writer, number: u32) std.Io.Writer.Error!void {
    std.debug.assert(number < components_max);

    try writer.print("<" ++ placeholder_tag ++ " " ++ placeholder_number ++ "=\"{d}\">", .{
        number,
    });
}

/// Stands for the runtime's node in the tests: the same shape, markup now or a body later.
pub const TestNode = struct {
    raw: ?[]const u8 = null,
    ctx: *const anyopaque = undefined,
    render_fn: ?*const fn () void = null,

    pub fn is_empty(node: TestNode) bool {
        return (node.raw orelse "").len == 0;
    }
};

pub const TestProps = struct {
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

test "a description names every prop that crosses, a node as its text, the request not" {
    const text = comptime describe(TestProps);

    try std.testing.expectEqual(@as(u8, 'o'), text[0]);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x05title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x08children") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x07actions") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "publr_request") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "render_fn") == null);
    try std.testing.expect(node_of(?TestNode) == TestNode);
    try std.testing.expect(node_of([]const u8) == null);
}

test "a placeholder is a tag a writer can put attributes on" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_placeholder(&writer, 12);
    try std.testing.expectEqualStrings("<publr-drawn n=\"12\">", writer.buffered());
}
