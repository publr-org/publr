const std = @import("std");

pub const lines_max: u32 = 100_000;
const file_bytes_max_hint = @import("limits.zig").file_bytes_max;
pub const message = "control flow needs a blank line before and after it";
pub const braces_message = "if/else bodies always take braces";

const keywords = [_][]const u8{
    "if (",
    "while (",
    "for (",
    "switch (",
    "inline for (",
    "inline while (",
};

pub fn check(
    gpa: std.mem.Allocator,
    text: []const u8,
    path: []const u8,
    hint: []const u8,
    report: bool,
) !u32 {
    std.debug.assert(path.len > 0);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var iterator = std.mem.splitScalar(u8, text, '\n');

    while (iterator.next()) |line| {
        if (lines.items.len == lines_max) {
            return error.TooManyLines;
        }
        try lines.append(gpa, line);
    }

    std.debug.assert(lines.items.len <= lines_max);

    var violations: u32 = 0;
    var index: u32 = 0;

    while (index < lines.items.len) : (index += 1) {
        if (unbraced_branch(lines.items[index])) {
            violations += 1;

            if (report) {
                std.debug.print("{s}:{d}: {s}{s}\n", .{ path, index + 1, braces_message, hint });
            }
        }

        if (!starts_control_flow(lines.items[index])) {
            continue;
        }

        const end = statement_end(lines.items, index);
        const before_ok = index == 0 or opens_paragraph(lines.items[index - 1]);
        const after_ok = end + 1 >= lines.items.len or closes_paragraph(lines.items[end + 1]);

        if (!before_ok or !after_ok) {
            violations += 1;

            if (report) {
                std.debug.print("{s}:{d}: {s}{s}\n", .{ path, index + 1, message, hint });
            }
        }
        index = end;
    }

    return violations;
}

fn starts_control_flow(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    std.debug.assert(trimmed.len <= line.len);
    std.debug.assert(keywords.len == 6);

    for (keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) {
            return true;
        }
    }

    return false;
}

fn unbraced_branch(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    const is_if = std.mem.startsWith(u8, trimmed, "if (");
    const is_else = std.mem.startsWith(u8, trimmed, "} else");

    std.debug.assert(!(is_if and is_else));

    if (!is_if and !is_else) {
        return false;
    }

    if (!std.mem.endsWith(u8, trimmed, ";")) {
        return false;
    }

    std.debug.assert(trimmed.len >= 4);

    const close = matching_paren(trimmed) orelse return is_else and statement_body(trimmed[6..]);
    const body = std.mem.trimStart(u8, trimmed[close + 1 ..], " ");

    if (is_else) {
        return statement_body(body);
    }

    return body.len > 0 and body[0] != '{';
}

fn statement_body(text: []const u8) bool {
    var body = std.mem.trimStart(u8, text, " ");

    if (body.len > 0 and body[0] == '|') {
        const capture_end = std.mem.indexOfScalarPos(u8, body, 1, '|') orelse return false;
        body = std.mem.trimStart(u8, body[capture_end + 1 ..], " ");
    }

    const starters = [_][]const u8{ "return", "break", "continue", "try ", "unreachable" };

    std.debug.assert(body.len <= text.len);
    std.debug.assert(starters.len == 5);

    for (starters) |starter| {
        if (std.mem.startsWith(u8, body, starter)) {
            return true;
        }
    }

    return false;
}

fn matching_paren(text: []const u8) ?u32 {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    var depth: u32 = 0;
    var index: u32 = @intCast(open);
    var in_string = false;

    std.debug.assert(open < text.len);
    std.debug.assert(depth == 0);

    while (index < text.len) : (index += 1) {
        const char = text[index];

        if (in_string) {
            if (char == '\\') {
                index += 1;
            } else if (char == '"') {
                in_string = false;
            }

            continue;
        }

        switch (char) {
            '"' => in_string = true,
            '\'' => index += 2,
            '(' => depth += 1,
            ')' => {
                depth -= 1;

                if (depth == 0) {
                    return index;
                }
            },
            else => {},
        }
    }

    return null;
}

fn opens_paragraph(previous: []const u8) bool {
    const trimmed = std.mem.trim(u8, previous, " ");
    std.debug.assert(trimmed.len <= previous.len);

    if (trimmed.len == 0) {
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "//")) {
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "\\\\")) {
        return true;
    }

    const last = trimmed[trimmed.len - 1];
    std.debug.assert(trimmed.len > 0);

    return last == '{' or last == '(' or last == ',' or std.mem.endsWith(u8, trimmed, "=>");
}

fn closes_paragraph(next: []const u8) bool {
    const trimmed = std.mem.trim(u8, next, " ");
    std.debug.assert(trimmed.len <= next.len);

    if (trimmed.len == 0) {
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "//")) {
        return true;
    }

    std.debug.assert(trimmed.len > 0);

    return trimmed[0] == '}' or trimmed[0] == ')' or trimmed[0] == ']';
}

fn statement_end(lines: []const []const u8, start: u32) u32 {
    std.debug.assert(start < lines.len);
    std.debug.assert(lines.len <= lines_max);

    const indent = indent_of(lines[start]);
    var index = start;

    while (true) {
        const trimmed = std.mem.trimEnd(u8, lines[index], " ");
        const opens_block = std.mem.endsWith(u8, trimmed, "{");
        const opens_list = std.mem.endsWith(u8, trimmed, "(");
        const ends_statement = std.mem.endsWith(u8, trimmed, ";") or
            std.mem.endsWith(u8, trimmed, ",");

        if (opens_list) {
            const closed = list_close(lines, index, indent);

            if (closed > index) {
                index = closed;
                continue;
            }
        }

        if (opens_block) {
            index = block_close(lines, index, indent);
            const closing = std.mem.trimEnd(u8, lines[index], " ");
            if (std.mem.endsWith(u8, closing, "{")) {
                continue;
            }

            return index;
        }
        if (ends_statement or index + 1 == lines.len) {
            return index;
        }
        if (index + 1 < lines.len and indent_of(lines[index + 1]) <= indent) {
            return index;
        }
        index += 1;
    }
}

/// The `)` that closes a header wrapped one argument per line, as `zig fmt` lays it out.
fn list_close(lines: []const []const u8, open: u32, indent: u32) u32 {
    std.debug.assert(open < lines.len);
    std.debug.assert(indent < file_bytes_max_hint);

    var index = open + 1;

    while (index < lines.len) : (index += 1) {
        const line = lines[index];

        if (indent_of(line) == indent and std.mem.startsWith(u8, line[indent..], ")")) {
            return index;
        }
    }

    return open;
}

fn block_close(lines: []const []const u8, open: u32, indent: u32) u32 {
    std.debug.assert(open < lines.len);

    var index = open + 1;

    while (index < lines.len) : (index += 1) {
        const line = lines[index];
        if (std.mem.trim(u8, line, " ").len == 0) {
            continue;
        }
        if (indent_of(line) == indent and std.mem.startsWith(u8, line[indent..], "}")) {
            return index;
        }
        if (indent_of(line) < indent) {
            return index - 1;
        }
    }

    std.debug.assert(index >= open);

    return @intCast(lines.len - 1);
}

fn indent_of(line: []const u8) u32 {
    std.debug.assert(line.len < file_bytes_max_hint);

    var count: u32 = 0;

    while (count < line.len and line[count] == ' ') count += 1;

    std.debug.assert(count <= line.len);

    return count;
}

test "spaced control flow passes, cramped control flow is reported" {
    const good =
        \\fn sample() void {
        \\    try select.bind_text(1, id);
        \\
        \\    if (!try select.step()) {
        \\        return error.SessionNotFound;
        \\    }
        \\
        \\    if (x) {
        \\        y();
        \\    } else if (z) {
        \\        w();
        \\    }
        \\
        \\    while (index < 3) : (index += 1) {
        \\        if (index == 1) {
        \\            continue;
        \\        }
        \\    }
        \\
        \\    inline for (
        \\        names,
        \\        types,
        \\    ) |name, Type| {
        \\        use(name, Type);
        \\    }
        \\}
    ;
    const bad =
        \\fn sample() void {
        \\    try select.bind_text(1, id);
        \\    if (!try select.step()) return error.SessionNotFound;
        \\    const stored = 1;
        \\    if (stored != 32) return error.SessionNotFound;
        \\    if (!eql(left, right)) {
        \\        return error.SessionNotFound;
        \\    }
        \\}
    ;
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 0), try check(gpa, good, "good.zig", "", false));
    try std.testing.expectEqual(@as(u32, 5), try check(gpa, bad, "bad.zig", "", false));
}

test "unbraced branches" {
    try std.testing.expect(unbraced_branch("    if (a) return x;"));
    try std.testing.expect(unbraced_branch("    if (call(arg, \")\")) |value| use(value);"));
    try std.testing.expect(unbraced_branch("    } else return x;"));
    try std.testing.expect(!unbraced_branch("    if (a) {"));
    try std.testing.expect(!unbraced_branch("    } else {"));
    try std.testing.expect(!unbraced_branch("    const pick = if (flag) 1 else 2;"));
    try std.testing.expect(!unbraced_branch("    if (a and"));
    try std.testing.expect(!unbraced_branch("    } else .{ .port = 1 };"));
    try std.testing.expect(unbraced_branch("    } else |err| return err;"));
}
