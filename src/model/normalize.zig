//! What a value becomes before it is checked and kept: an email lowercased when its
//! field asks for it. Pure, over the parsed document.
const std = @import("std");
const field = @import("field.zig");
const kinds = @import("kinds.zig");

const Def = field.Def;
const Kind = kinds.Kind;
const Value = std.json.Value;

pub const text_len_max: u32 = kinds.string_len_max;

/// Every top-level field with a normalisation gets it, single or many.
pub fn apply(
    known: []const Kind,
    defs: []const Def,
    arena: std.mem.Allocator,
    object: *std.json.ObjectMap,
) error{OutOfMemory}!void {
    std.debug.assert(defs.len <= field.fields_max);
    std.debug.assert(known.len <= kinds.kinds_max);

    for (defs) |def| {
        if (!def.options.email.lowercase or !std.mem.eql(u8, def.kind, "email")) {
            continue;
        }

        const entry = object.getPtr(def.name) orelse continue;

        switch (entry.*) {
            .string => |text| entry.* = .{ .string = try lowered(arena, text) },
            .array => |*items| {
                for (items.items) |*item| {
                    if (item.* == .string) {
                        item.* = .{ .string = try lowered(arena, item.string) };
                    }
                }
            },
            else => {},
        }
    }
}

fn lowered(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(text_len_max > 0);
    std.debug.assert(field.fields_max > 0);

    const copy = try arena.dupe(u8, text);

    for (copy) |*char| {
        char.* = std.ascii.toLower(char.*);
    }

    return copy;
}

test "emails are lowercased when the field says so, single and many" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const defs = [_]Def{
        .{ .name = "mail", .label = "Mail", .kind = "email", .options = .{
            .email = .{ .lowercase = true },
        } },
        .{ .name = "cc", .label = "CC", .kind = "email", .many = true, .options = .{
            .email = .{ .lowercase = true },
        } },
        .{ .name = "kept", .label = "Kept", .kind = "email" },
    };
    var object: std.json.ObjectMap = .empty;
    var list = std.json.Array.init(arena);

    try list.append(.{ .string = "One@X.io" });
    try object.put(arena, "mail", .{ .string = "Ada@Example.COM" });
    try object.put(arena, "cc", .{ .array = list });
    try object.put(arena, "kept", .{ .string = "Keep@Case" });
    try apply(&kinds.core, &defs, arena, &object);
    try std.testing.expectEqualStrings("ada@example.com", object.get("mail").?.string);
    try std.testing.expectEqualStrings("one@x.io", object.get("cc").?.array.items[0].string);
    try std.testing.expectEqualStrings("Keep@Case", object.get("kept").?.string);
}
