//! Where a field sits inside a definition, by its dotted path (`gallery.caption`), and a
//! definition with one sibling list swapped. Pure: no database, no HTTP.
const std = @import("std");
const model = @import("../../../model.zig");

const Def = model.content_type.Def;
const FieldDef = model.field.Def;
pub const Error = error{OutOfMemory};

/// Where a field sits: its siblings (the top level, or a parent's children), its place
/// among them, and the parent's name (empty at the top level).
pub const Place = struct {
    field: FieldDef,
    siblings: []const FieldDef,
    index: u32,
    parent: []const u8,
};

pub fn locate(def: Def, path: []const u8) ?Place {
    std.debug.assert(path.len > 0);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const dot = std.mem.indexOfScalar(u8, path, '.');
    const parent = if (dot) |at| path[0..at] else "";
    const name = if (dot) |at| path[at + 1 ..] else path;
    const siblings = siblings_of(def, parent) orelse return null;

    for (siblings, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.name, name)) {
            return .{
                .field = candidate,
                .siblings = siblings,
                .index = @intCast(index),
                .parent = parent,
            };
        }
    }

    return null;
}

/// The top-level fields, or the children of the top-level group or repeater `parent`.
pub fn siblings_of(def: Def, parent: []const u8) ?[]const FieldDef {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(parent.len <= 64 << 10);

    if (parent.len == 0) {
        return def.fields;
    }

    const found = model.content_type.find_field(def.fields, parent) orelse return null;

    if (model.field.is_leaf(found.kind)) {
        return null;
    }

    return found.fields;
}

/// The definition with one sibling list replaced.
pub fn with_siblings(
    arena: std.mem.Allocator,
    def: Def,
    parent: []const u8,
    siblings: []const FieldDef,
) Error!Def {
    std.debug.assert(siblings.len <= model.field.fields_max + 1);
    std.debug.assert(parent.len <= 64 << 10);

    var changed = def;

    if (parent.len == 0) {
        changed.fields = siblings;

        return changed;
    }

    const fields = try arena.dupe(FieldDef, def.fields);

    for (fields) |*candidate| {
        if (std.mem.eql(u8, candidate.name, parent)) {
            candidate.fields = siblings;
        }
    }

    changed.fields = fields;

    return changed;
}

test "a field's place is found by its dotted path; a sibling list is swapped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const def: Def = .{ .handle = "post", .name = "Post", .fields = &.{
        .{ .name = "title", .label = "Title", .kind = "string" },
        .{ .name = "gallery", .label = "Gallery", .kind = "repeater", .fields = &.{
            .{ .name = "caption", .label = "Caption", .kind = "string" },
        } },
    } };
    const caption = locate(def, "gallery.caption").?;
    try std.testing.expectEqual(@as(u32, 0), caption.index);
    try std.testing.expectEqualStrings("gallery", caption.parent);
    try std.testing.expect(locate(def, "gallery.nope") == null);
    try std.testing.expect(locate(def, "title.nope") == null);
    try std.testing.expectEqual(@as(u32, 1), locate(def, "gallery").?.index);

    const emptied = try with_siblings(arena, def, "gallery", &.{});
    try std.testing.expectEqual(@as(usize, 0), emptied.fields[1].fields.len);
    try std.testing.expectEqual(@as(usize, 1), def.fields[1].fields.len);
}
