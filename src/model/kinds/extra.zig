const std = @import("std");
const field = @import("../field.zig");
const Value = std.json.Value;

pub fn color(def: field.Def, value: Value, path: []const u8, problems: *field.Problems) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    if (value != .string) {
        return;
    }

    const text = value.string;

    if (text.len != 7 or text[0] != '#') {
        problems.add(path, "use a color in #RRGGBB format");
        return;
    }

    for (text[1..]) |char| {
        if (!std.ascii.isHex(char)) {
            problems.add(path, "use a color in #RRGGBB format");
            return;
        }
    }
}

pub fn time(def: field.Def, value: Value, path: []const u8, problems: *field.Problems) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    if (value != .string) {
        return;
    }

    const text = value.string;

    if (text.len != 5 or text[2] != ':') {
        problems.add(path, "use a time in HH:MM format");
        return;
    }

    for ([_]u8{ text[0], text[1], text[3], text[4] }) |char| {
        if (!std.ascii.isDigit(char)) {
            problems.add(path, "use a time in HH:MM format");
            return;
        }
    }

    const hour = std.fmt.parseInt(u8, text[0..2], 10) catch 255;
    const minute = std.fmt.parseInt(u8, text[3..5], 10) catch 255;

    if (hour > 23 or minute > 59) {
        problems.add(path, "use a time between 00:00 and 23:59");
    }
}
