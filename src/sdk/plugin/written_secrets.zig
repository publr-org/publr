//! The secrets a plugin's code writes as `{secret:NAME}`, read by the build beside its doc
//! comments (the compiler cannot list a plugin's strings), so `define` can refuse one the
//! plugin did not declare in `.secrets`.
const std = @import("std");
const secrets = @import("../../model/secrets.zig");

pub const names_max: u32 = 1024;

/// Every name a file's string literals write, appended to `out` unless there already.
pub fn read(
    arena: std.mem.Allocator,
    text: [:0]const u8,
    out: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    std.debug.assert(text.len < std.math.maxInt(u32));
    std.debug.assert(out.items.len <= names_max);

    var tokenizer = std.zig.Tokenizer.init(text);

    while (true) {
        const token = tokenizer.next();

        switch (token.tag) {
            .eof => return,
            .string_literal, .multiline_string_literal_line => {
                try secrets.written_in(arena, text[token.loc.start..token.loc.end], out);
            },
            else => {},
        }
    }
}

/// The names as a declaration the docs module carries: `secrets_written`.
pub fn source(arena: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(names.len <= names_max);

    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(arena, "\npub const secrets_written = [_][]const u8{");

    for (names) |name| {
        std.debug.assert(secrets.valid_name(name));
        try out.print(arena, " \"{s}\",", .{name});
    }

    try out.appendSlice(arena, " };\n");

    return out.items;
}

test "names written in strings, not in comments" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\// {secret:IN_A_COMMENT}
        \\const header = "Bearer {secret:API_KEY}";
        \\const body =
        \\    \\{"key":"{secret:OTHER_KEY}"}
        \\;
    ;
    var names: std.ArrayList([]const u8) = .empty;

    try read(arena, text, &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("API_KEY", names.items[0]);
    try std.testing.expectEqualStrings("OTHER_KEY", names.items[1]);

    const written = try source(arena, names.items);

    try std.testing.expect(std.mem.indexOf(u8, written, "\"OTHER_KEY\",") != null);
    try std.testing.expectEqualStrings(
        "\npub const secrets_written = [_][]const u8{ };\n",
        try source(arena, &.{}),
    );
}
