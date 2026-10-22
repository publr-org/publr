//! Mods: an owner passes a value through `ctx.mod("checkout.methods", methods)` wherever it
//! makes it, and every plugin's `publr.modify("checkout.methods", run)` changes it in turn,
//! compiled-in plugins first, then installed ones. Nothing is declared ahead: a name nobody
//! modifies comes back as it went. A modifier's name may hold `*` for exactly one part
//! (`*.title`, `checkout.*`). Values cross as JSON, a batch at a time, so a modifier written
//! for one item has its reads made together for all (`plugin/filter_reads.zig`).

const std = @import("std");

pub const items_max: u32 = 200;
pub const name_len_max: u32 = 96;
pub const text_bytes_max: u32 = 512;

/// What `ctx.mod` calls (core's `mod.apply`): the values, a JSON array, through every
/// modifier of `name`; they come back in the same order.
pub const Apply = struct {
    pub const name = "mod.apply";
    pub const In = struct {
        name: []const u8,
        values: []const u8,
    };
    pub const Out = struct {
        values: []const u8,
    };
};

/// A modifier as administrators see it: whose it is, the name it takes, why.
pub const Modifier = struct {
    plugin: []const u8,
    name: []const u8,
    reason: []const u8,
};

/// The values one apply hands each modifier, in order; it answers them changed.
pub const Batch = struct {
    items: []std.json.Value,
};

/// Whether a name may be applied or modified: dotted parts of `a-z`, `0-9` and `_`; a
/// modifier's may also be `*` for one whole part.
pub fn valid(name: []const u8, wildcard: bool) bool {
    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    std.debug.assert(name.len <= name_len_max);

    var parts = std.mem.splitScalar(u8, name, '.');

    while (parts.next()) |part| {
        if (part.len == 0) {
            return false;
        }

        if (wildcard and std.mem.eql(u8, part, "*")) {
            continue;
        }

        for (part) |char| {
            const allowed = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or
                char == '_';

            if (!allowed) {
                return false;
            }
        }
    }

    return true;
}

/// Whether a modifier's `pattern` takes the applied `name`: part by part, `*` any one part.
pub fn matches(pattern: []const u8, name: []const u8) bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(name.len > 0);

    var wanted = std.mem.splitScalar(u8, pattern, '.');
    var given = std.mem.splitScalar(u8, name, '.');

    while (wanted.next()) |part| {
        const other = given.next() orelse return false;

        if (!std.mem.eql(u8, part, "*") and !std.mem.eql(u8, part, other)) {
            return false;
        }
    }

    return given.next() == null;
}

/// Takes `changed` into `batch` when it is the same size; anything else is ignored.
pub fn take(batch: *Batch, changed: Batch) bool {
    std.debug.assert(batch.items.len <= items_max);

    if (changed.items.len != batch.items.len) {
        return false;
    }

    @memcpy(batch.items, changed.items);

    return true;
}

/// Text a modifier answered, for a page to show: cut on a character at `text_bytes_max`,
/// control characters made spaces; empty when it is not text.
pub fn cleaned(arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(text_bytes_max > 0);

    var end: u32 = @intCast(@min(value.len, text_bytes_max));

    while (end > 0 and end < value.len and (value[end] & 0xC0) == 0x80) {
        end -= 1;
    }

    const kept = value[0..end];

    if (!std.unicode.utf8ValidateSlice(kept)) {
        return "";
    }

    const out = try arena.dupe(u8, kept);

    for (out) |*char| {
        if (char.* < 0x20 or char.* == 0x7f) {
            char.* = ' ';
        }
    }

    return out;
}

test "names: dotted parts; a modifier's `*` stands for one part" {
    try std.testing.expect(valid("checkout.methods", false));
    try std.testing.expect(valid("*.title", true));
    try std.testing.expect(!valid("*.title", false));
    try std.testing.expect(!valid("checkout..methods", true));
    try std.testing.expect(!valid("Checkout.methods", true));
    try std.testing.expect(!valid("checkout.met*", true));

    try std.testing.expect(matches("variant.title", "variant.title"));
    try std.testing.expect(matches("*.title", "variant.title"));
    try std.testing.expect(matches("checkout.*", "checkout.methods"));
    try std.testing.expect(matches("product.*.price", "product.variant.price"));
    try std.testing.expect(!matches("*.title", "variant.title.short"));
    try std.testing.expect(!matches("checkout.*", "checkout"));
    try std.testing.expect(!matches("variant.title", "product.title"));
}

test "text a modifier answers: cut on a character, control characters made spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Earl Grey, 50 g", try cleaned(arena, "Earl Grey,\n50 g"));
    try std.testing.expectEqual(@as(usize, text_bytes_max), (try cleaned(arena, "é" ** 400)).len);
    try std.testing.expectEqualStrings("", try cleaned(arena, "\xff\xfe"));
}
