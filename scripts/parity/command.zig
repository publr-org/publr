const std = @import("std");

pub const args_max: u32 = 64;
pub const Error = error{ NoExample, TooManyArguments };

const marker = "$ publr ";

/// Split the example command line the binary prints in `--help` the way a shell would:
/// single or double quotes group words, and the leading `publr` is already gone.
pub fn parse(help: []const u8, storage: *[args_max][]const u8) Error![]const []const u8 {
    std.debug.assert(help.len > 0);
    std.debug.assert(storage.len == args_max);

    const line = find(help) orelse return Error.NoExample;
    var count: u32 = 0;
    var index: u32 = 0;

    while (index < line.len) {
        while (index < line.len and line[index] == ' ') {
            index += 1;
        }

        if (index == line.len) {
            break;
        }

        if (count == args_max) {
            return Error.TooManyArguments;
        }

        const opener = line[index];
        const quoted = opener == '"' or opener == '\'';

        if (quoted) {
            index += 1;
        }

        const terminator: u8 = if (quoted) opener else ' ';
        const start = index;

        while (index < line.len and line[index] != terminator) {
            index += 1;
        }

        storage[count] = line[start..index];
        count += 1;

        if (quoted and index < line.len) {
            index += 1;
        }
    }

    std.debug.assert(count <= args_max);

    return storage[0..count];
}

fn find(help: []const u8) ?[]const u8 {
    std.debug.assert(help.len > 0);
    std.debug.assert(marker.len > 0);

    var lines = std.mem.splitScalar(u8, help, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");

        if (std.mem.startsWith(u8, trimmed, marker)) {
            return trimmed[marker.len..];
        }
    }

    return null;
}

test "the printed example splits into arguments, quotes grouping words" {
    const help = "Usage: publr record save\n\nExample:\n\n  $ publr --as ada@example.com " ++
        "record save --document \"two words\"\n";
    var storage: [args_max][]const u8 = undefined;
    const args = try parse(help, &storage);

    try std.testing.expectEqual(@as(usize, 6), args.len);
    try std.testing.expectEqualStrings("--as", args[0]);
    try std.testing.expectEqualStrings("ada@example.com", args[1]);
    try std.testing.expectEqualStrings("record", args[2]);
    try std.testing.expectEqualStrings("--document", args[4]);
    try std.testing.expectEqualStrings("two words", args[5]);
}

test "help without an example line is an error" {
    var storage: [args_max][]const u8 = undefined;

    try std.testing.expectError(Error.NoExample, parse("Usage: publr project status\n", &storage));
}
