//! Struct shapes always stand one field per line: every struct value (`.{ .a = 1 }`,
//! `T{ .a = 1 }`) and every struct or union declaration with fields ends its last field
//! with a comma, at every level, so `zig fmt` lays each field on a line of its own and the
//! nesting reads from the indentation. Lists (`.{ a, b }`, `&.{"x"}`) and empty values
//! (`.{}`) are not shapes and stay as they are.
const std = @import("std");
const Ast = std.zig.Ast;

pub const message = "a struct's last field takes a trailing comma (one field per line)";

/// Where a comma is missing: the byte offset just after the last field, and its line.
pub const Missing = struct {
    offset: u32,
    line: u32,
    /// The field ends with a multi-line string (`\\...`): its comma goes on a line of its
    /// own, never on the string's last line, which is the string's own text.
    multiline: bool = false,
};

pub const missing_max: u32 = 100_000;

/// Every place in `source` a struct's last field lacks its comma, in source order.
pub fn find(gpa: std.mem.Allocator, source: [:0]const u8) ![]Missing {
    std.debug.assert(source.len < std.math.maxInt(u32));

    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    var found: std.ArrayList(Missing) = .empty;
    errdefer found.deinit(gpa);

    if (tree.errors.len > 0) {
        return found.toOwnedSlice(gpa);
    }

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const last = last_field(&tree, node) orelse continue;
        const after = tree.lastToken(last) + 1;

        if (after < tree.tokens.len and tree.tokenTag(after) == .comma) {
            continue;
        }

        if (found.items.len == missing_max) {
            return error.TooManyMissing;
        }

        const end_token = tree.lastToken(last);
        const end: u32 = @intCast(tree.tokenStart(end_token) + tree.tokenSlice(end_token).len);

        try found.append(gpa, .{
            .offset = end,
            .line = @intCast(std.mem.count(u8, source[0..end], "\n") + 1),
            .multiline = tree.tokenTag(end_token) == .multiline_string_literal_line,
        });
    }

    std.mem.sort(Missing, found.items, {}, before);

    return found.toOwnedSlice(gpa);
}

fn before(_: void, left: Missing, right: Missing) bool {
    return left.offset < right.offset;
}

/// The last field of a struct value or of a struct or union declaration; null for any
/// other node, and for one without fields.
fn last_field(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    std.debug.assert(tree.nodes.len > 0);

    var buffer: [2]Ast.Node.Index = undefined;

    if (tree.fullStructInit(&buffer, node)) |init| {
        const fields = init.ast.fields;

        return if (fields.len == 0) null else fields[fields.len - 1];
    }

    const container = tree.fullContainerDecl(&buffer, node) orelse return null;
    const keyword = tree.tokenTag(container.ast.main_token);

    if (keyword != .keyword_struct and keyword != .keyword_union) {
        return null;
    }

    var last: ?Ast.Node.Index = null;

    for (container.ast.members) |member| {
        switch (tree.nodeTag(member)) {
            .container_field_init, .container_field_align, .container_field => last = member,
            else => {},
        }
    }

    return last;
}

/// `source` with every missing comma put in.
pub fn fixed(gpa: std.mem.Allocator, source: [:0]const u8, missing: []const Missing) ![]u8 {
    std.debug.assert(missing.len <= missing_max);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var from: u32 = 0;

    for (missing) |place| {
        try out.appendSlice(gpa, source[from..place.offset]);
        try out.appendSlice(gpa, if (place.multiline) "\n," else ",");
        from = place.offset;
    }

    try out.appendSlice(gpa, source[from..]);

    return out.toOwnedSlice(gpa);
}

test "struct values and declarations need their last comma, lists and empty values do not" {
    const gpa = std.testing.allocator;
    const source =
        \\const Inline = struct { first: u8 };
        \\const Laid = struct {
        \\    second: u8,
        \\};
        \\const Choice = enum { one, two };
        \\const value = .{ .first = 1, .nested = .{ .third = 2 } };
        \\const laid = .{
        \\    .first = 1,
        \\};
        \\const list = .{ 1, 2 };
        \\const empty = .{};
        \\const names = &.{"x"};
        \\const text = .{ .first =
        \\    \\{"x":1}
        \\};
        \\
    ;
    const missing = try find(gpa, source);
    defer gpa.free(missing);

    try std.testing.expectEqual(@as(usize, 4), missing.len);
    try std.testing.expect(missing[3].multiline);
    try std.testing.expectEqual(@as(u32, 1), missing[0].line);
    try std.testing.expectEqual(@as(u32, 6), missing[1].line);
    try std.testing.expectEqual(@as(u32, 6), missing[2].line);

    const repaired = try fixed(gpa, source, missing);
    defer gpa.free(repaired);

    try std.testing.expect(std.mem.indexOf(u8, repaired, "{\"x\":1}\n,") != null);

    const repaired_z = try gpa.dupeZ(u8, repaired);
    defer gpa.free(repaired_z);
    const again = try find(gpa, repaired_z);
    defer gpa.free(again);

    try std.testing.expectEqual(@as(usize, 0), again.len);
}
