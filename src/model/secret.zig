//! Secrets kept out of the logs: an input's fields an operation declares secret, and, as a
//! net under them, any field at any depth whose name says it holds one. Both are replaced by
//! a mark, so the log shows that a value was given and never what it was.

const std = @import("std");

pub const mark = "•";
pub const depth_max: u32 = 32;
pub const nodes_max: u32 = 1 << 16;

/// Whether a field's name says it holds a secret: `password`, `new_password`, `token`,
/// `client_secret`, `api_key`.
pub fn caught(name: []const u8) bool {
    std.debug.assert(name.len <= 1024);

    const words = [_][]const u8{ "password", "token", "secret", "credential" };

    for (words) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) {
            return true;
        }
    }

    return std.ascii.endsWithIgnoreCase(name, "_key") or std.ascii.eqlIgnoreCase(name, "apikey");
}

/// The input JSON with secrets replaced: the `declared` top-level fields, and every field
/// the net catches. Input that is not JSON is replaced whole, since it cannot be checked.
pub fn masked(
    arena: std.mem.Allocator,
    input: []const u8,
    declared: []const []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(declared.len <= 64);

    if (input.len == 0) {
        return "";
    }

    var value = std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{}) catch {
        return mark;
    };

    if (value == .object) {
        for (declared) |name| {
            if (value.object.getPtr(name)) |field| {
                field.* = .{ .string = mark };
            }
        }
    }

    try mask_caught(arena, &value);

    return std.json.Stringify.valueAlloc(arena, value, .{}) catch error.OutOfMemory;
}

/// Every object and array below `root`, walked with a worklist: a caught field's value
/// becomes the mark whatever it held.
fn mask_caught(arena: std.mem.Allocator, root: *std.json.Value) error{OutOfMemory}!void {
    std.debug.assert(nodes_max > 0);

    var pending: std.ArrayList(*std.json.Value) = .empty;
    var walked: u32 = 0;

    try pending.append(arena, root);

    while (pending.pop()) |node| {
        walked += 1;

        if (walked > nodes_max) {
            root.* = .{ .string = mark };
            return;
        }

        switch (node.*) {
            .object => |*object| {
                var fields = object.iterator();

                while (fields.next()) |field| {
                    if (caught(field.key_ptr.*) and holds_text(field.value_ptr.*)) {
                        field.value_ptr.* = .{ .string = mark };
                    } else {
                        try pending.append(arena, field.value_ptr);
                    }
                }
            },
            .array => |*array| {
                for (array.items) |*item| {
                    try pending.append(arena, item);
                }
            },
            else => {},
        }
    }
}

/// What a secret can be: text, or something holding text. A `password_link: true` says
/// only that a link was asked for, so a flag or a number is kept.
fn holds_text(value: std.json.Value) bool {
    std.debug.assert(nodes_max > 0);

    return switch (value) {
        .string, .number_string, .object, .array => true,
        .null, .bool, .integer, .float => false,
    };
}

test "secrets: declared ones, caught ones at any depth, the rest kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input =
        \\{"email":"ada@example.com","pin":"1234","password":"hunter2",
        \\"settings":{"api_key":"sk_live_1","items":[{"client_secret":"s","name":"x"}]},
        \\"token":{"nested":"value"}}
    ;
    const text = try masked(arena, input, &.{"pin"});

    try std.testing.expect(std.mem.indexOf(u8, text, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1234") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sk_live_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"s\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "value") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ada@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"x\"") != null);
    try std.testing.expectEqualStrings(mark, try masked(arena, "not json", &.{}));

    const flag = try masked(arena, "{\"password_link\":true}", &.{});
    try std.testing.expectEqualStrings("{\"password_link\":true}", flag);
    try std.testing.expect(caught("NewPassword"));
    try std.testing.expect(!caught("key"));
    try std.testing.expect(!caught("monkey"));
}
