//! Account rules that need no database: what an email must look like, what a display
//! name may be.

const std = @import("std");

pub const id_len_max: u32 = 64;

pub const email_len_max: u32 = 254;
pub const display_name_len_max: u32 = 128;
pub const EmailError = error{ InvalidEmail, OutOfMemory };
pub const NameError = error{InvalidName};

pub fn normalize_email(arena: std.mem.Allocator, raw: []const u8) EmailError![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    if (trimmed.len < 3 or trimmed.len > email_len_max) {
        return error.InvalidEmail;
    }

    const at = std.mem.indexOfScalar(u8, trimmed, '@') orelse return error.InvalidEmail;

    if (at == 0 or at == trimmed.len - 1) {
        return error.InvalidEmail;
    }

    if (std.mem.indexOfAny(u8, trimmed, " \t\r\n") != null) {
        return error.InvalidEmail;
    }

    const lowered = arena.alloc(u8, trimmed.len) catch return error.OutOfMemory;

    for (trimmed, 0..) |char, index| lowered[index] = std.ascii.toLower(char);

    std.debug.assert(lowered.len == trimmed.len);
    std.debug.assert(std.mem.indexOfScalar(u8, lowered, '@') != null);

    return lowered;
}

pub fn validate_display_name(name: []const u8) NameError![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");

    if (trimmed.len == 0 or trimmed.len > display_name_len_max) {
        return error.InvalidName;
    }

    std.debug.assert(trimmed.len <= name.len);
    std.debug.assert(trimmed.len > 0);

    return trimmed;
}

test "email normalisation and display name validation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const normalized = try normalize_email(arena, "  Ada@Example.COM\n");
    try std.testing.expectEqualStrings("ada@example.com", normalized);
    try std.testing.expectError(error.InvalidEmail, normalize_email(arena, "ada"));
    try std.testing.expectError(error.InvalidEmail, normalize_email(arena, "@example.com"));
    try std.testing.expectError(error.InvalidEmail, normalize_email(arena, "a da@example.com"));
    try std.testing.expectEqualStrings("Ada", try validate_display_name(" Ada "));
    try std.testing.expectError(error.InvalidName, validate_display_name("   "));
}
