//! A site's overrides of what an operation's code says: who may call it and its rate limit,
//! kept as settings (`operation.<name>.authorize`, `operation.<name>.limit`) and read where
//! each is checked. An answer is written as text: `signed_in`, `plugin_calls`, or
//! `roles:editor,author`. Anyone is no override: it is what untrusted callers mean by default.
const std = @import("std");
const Answer = @import("caller_answer.zig").Answer;

pub const roles_max: u32 = 16;
pub const name_len_max: u32 = 128;

pub fn authorize_key(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(name.len > 0 and name.len <= name_len_max);
    std.debug.assert(std.mem.indexOfScalar(u8, name, '.') != null);

    return std.fmt.allocPrint(arena, "operation.{s}.authorize", .{name});
}

pub fn limit_key(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(name.len > 0 and name.len <= name_len_max);
    std.debug.assert(std.mem.indexOfScalar(u8, name, '.') != null);

    return std.fmt.allocPrint(arena, "operation.{s}.limit", .{name});
}

/// The answer `text` names; null for text that names none.
pub fn parse_answer(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?Answer {
    std.debug.assert(text.len <= 1024);

    if (std.mem.eql(u8, text, "signed_in")) {
        return .signed_in;
    }

    if (std.mem.eql(u8, text, "plugin_calls")) {
        return .plugin_calls;
    }

    const prefix = "roles:";

    if (!std.mem.startsWith(u8, text, prefix)) {
        return null;
    }

    var roles: std.ArrayList([]const u8) = .empty;
    var names = std.mem.splitScalar(u8, text[prefix.len..], ',');

    while (names.next()) |name| {
        const role = std.mem.trim(u8, name, " ");

        if (role.len == 0 or roles.items.len == roles_max) {
            return null;
        }

        try roles.append(arena, try arena.dupe(u8, role));
    }

    if (roles.items.len == 0) {
        return null;
    }

    return .{
        .roles = roles.items,
    };
}

/// The answer as text, as `parse_answer` reads it.
pub fn answer_text(arena: std.mem.Allocator, answer: Answer) error{OutOfMemory}![]const u8 {
    std.debug.assert(answer != .roles or answer.roles.len > 0);

    return switch (answer) {
        .visitor => "visitor",
        .signed_in => "signed_in",
        .plugin_calls => "plugin_calls",
        .roles => |roles| try std.fmt.allocPrint(arena, "roles:{s}", .{
            try std.mem.join(arena, ",", roles),
        }),
    };
}

test "an answer read from its text and written back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const roles = (try parse_answer(arena, "roles:editor, author")).?;

    try std.testing.expectEqual(2, roles.roles.len);
    try std.testing.expectEqualStrings("roles:editor,author", try answer_text(arena, roles));
    try std.testing.expect((try parse_answer(arena, "signed_in")).? == .signed_in);
    try std.testing.expect(try parse_answer(arena, "roles:") == null);
    try std.testing.expect(try parse_answer(arena, "anyone") == null);

    const key = try limit_key(arena, "guestbook.sign");

    try std.testing.expectEqualStrings("operation.guestbook.sign.limit", key);
}
