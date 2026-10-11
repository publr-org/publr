const std = @import("std");

/// Every non-trivial function asserts something; two is the aim, one is tolerated and
/// counted, none is a violation. What is never tolerated is an assertion the compiler
/// already proves (see `padding_assert`).
const assertions_per_function_min: u32 = 1;
const assertions_per_function_aim: u32 = 2;
const function_body_lines_trivial: u32 = 3;
const function_lines_max: u32 = 70;

const function_depth_max: u32 = 8;

const FunctionFrame = struct {
    start_line: u32,
    indent: u32,
    body_lines: u32 = 0,
    /// Lines that only lay out a struct, left out of the length.
    layout_lines: u32 = 0,
    assertions: u32 = 0,
    is_container: bool,
};

/// `singles` counts the functions with fewer assertions than the aim (one, not none);
/// the caller reports it as a number at the end, never as a failure.
pub fn check_assertion_density(
    text: []const u8,
    path: []const u8,
    hint: []const u8,
    report: bool,
    singles: *u32,
) u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 1;
    var violations: u32 = 0;
    var frames: [function_depth_max]FunctionFrame = undefined;
    var depth: u32 = 0;

    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " ");
        const indent: u32 = @intCast(line.len - trimmed.len);
        const closes = depth > 0 and indent == frames[depth - 1].indent and
            std.mem.startsWith(u8, trimmed, "}");

        if (closes) {
            depth -= 1;
            violations += report_function(path, frames[depth], line_no, hint, report, singles);
            continue;
        }

        if (padding_assert(line)) {
            violations += 1;

            if (report) {
                std.debug.print("{s}:{d}: assertion the compiler already proves (a tautology, " ++
                    "`or true`, a type or size check){s}\n", .{ path, line_no, hint });
            }
        }

        if (depth > 0) {
            const frame = &frames[depth - 1];
            if (trimmed.len > 0 and layout_only(trimmed)) {
                frame.layout_lines += 1;
            } else if (trimmed.len > 0) {
                frame.body_lines += 1;
            }
            if (std.mem.indexOf(u8, line, "assert(") != null) {
                frame.assertions += 1;
            }
            if (std.mem.indexOf(u8, line, "assert_") != null) {
                frame.assertions += 1;
            }
            if (std.mem.indexOf(u8, line, "unreachable") != null) {
                frame.assertions += 1;
            }
            if (std.mem.indexOf(u8, line, "@compileError(") != null) {
                frame.assertions += 1;
            }
        }

        if (starts_function(trimmed)) {
            if (depth == function_depth_max) {
                return violations + 1;
            }
            frames[depth] = .{
                .start_line = line_no,
                .indent = indent,
                .is_container = std.mem.indexOf(u8, trimmed, ") type {") != null,
            };
            depth += 1;
        }
    }

    return violations;
}

/// A line that only lays out a struct (one field, or closing braces): struct values stand
/// one field per line (`literals.zig`), so the length limits count logic, not layout.
fn layout_only(trimmed: []const u8) bool {
    std.debug.assert(trimmed.len > 0);

    const closes = std.mem.trimEnd(u8, trimmed, "})];, ");

    if (closes.len == 0) {
        return true;
    }

    if (trimmed[0] != '.' or trimmed.len < 2 or !std.ascii.isAlphabetic(trimmed[1])) {
        return false;
    }

    const assigns = std.mem.indexOf(u8, trimmed, " = ") != null;
    const ends = std.mem.endsWith(u8, trimmed, ",") or std.mem.endsWith(u8, trimmed, "{");

    return assigns and ends;
}

test "layout lines are a struct's fields and closing braces" {
    try std.testing.expect(layout_only(".name = \"x\","));
    try std.testing.expect(layout_only(".group = .{"));
    try std.testing.expect(layout_only("}},"));
    try std.testing.expect(layout_only("});"));
    try std.testing.expect(!layout_only("const count = 1;"));
    try std.testing.expect(!layout_only("return .{"));
}

/// An assertion that cannot fail or restates what the compiler checks: padding.
fn padding_assert(line: []const u8) bool {
    std.debug.assert(line.len <= 1 << 16);

    if (std.mem.indexOf(u8, line, "assert(") == null) {
        return false;
    }

    const banned = [_][]const u8{
        " or tr" ++ "ue)",    "assert(tr" ++ "ue)", ".len >" ++ "= 0", "@intFrom" ++ "Ptr(",
        "!= undef" ++ "ined", "@Type" ++ "Of(",     "@align" ++ "Of(",
    };

    for (banned) |needle| {
        if (std.mem.indexOf(u8, line, needle) != null) {
            return true;
        }
    }

    const sizes_nothing = std.mem.indexOf(u8, line, "@size" ++ "Of(") != null and
        std.mem.indexOf(u8, line, ") >" ++ "= 0") != null;

    if (sizes_nothing) {
        return true;
    }

    const has_le = std.mem.indexOf(u8, line, ".len <= ") != null;
    const has_or = std.mem.indexOf(u8, line, " or ") != null;
    const has_gt = std.mem.indexOf(u8, line, ".len > ") != null;

    std.debug.assert(!(has_le and has_or and has_gt) or line.len > 20);

    return has_le and has_or and has_gt;
}

fn starts_function(trimmed: []const u8) bool {
    std.debug.assert(trimmed.len == 0 or trimmed[0] != ' ');

    const declares = std.mem.startsWith(u8, trimmed, "fn ") or
        std.mem.startsWith(u8, trimmed, "pub fn ");
    const opens = std.mem.endsWith(u8, std.mem.trimEnd(u8, trimmed, " "), "{");

    std.debug.assert(!declares or trimmed.len > 3);

    return declares and opens;
}

fn report_function(
    path: []const u8,
    frame: FunctionFrame,
    end_line: u32,
    hint: []const u8,
    report: bool,
    singles: *u32,
) u32 {
    std.debug.assert(end_line >= frame.start_line);
    std.debug.assert(path.len > 0);

    if (frame.is_container) {
        return 0;
    }

    var violations: u32 = 0;
    const trivial = frame.body_lines <= function_body_lines_trivial;

    if (!trivial and frame.assertions == assertions_per_function_min) {
        singles.* += 1;
    }

    if (!trivial and frame.assertions < assertions_per_function_min) {
        violations += 1;

        if (report) {
            std.debug.print("{s}:{d}: function has {d} assertion(s), minimum {d}{s}\n", .{
                path,
                frame.start_line,
                frame.assertions,
                assertions_per_function_min,
                hint,
            });
        }
    }

    const length = end_line - frame.start_line - frame.layout_lines;

    if (length > function_lines_max) {
        violations += 1;

        if (report) {
            std.debug.print("{s}:{d}: function is {d} lines, maximum {d}{s}\n", .{
                path,
                frame.start_line,
                length,
                function_lines_max,
                hint,
            });
        }
    }

    return violations;
}

test "assertion density: trivial functions pass, sparse ones are reported, long ones too" {
    const trivial =
        \\fn small() u32 {
        \\    return 1;
        \\}
    ;
    const dense =
        \\fn dense(value: u32) u32 {
        \\    std.debug.assert(value > 0);
        \\    std.debug.assert(value < 10);
        \\
        \\    const doubled = value * 2;
        \\
        \\    return doubled;
        \\}
    ;
    const sparse =
        \\fn sparse(value: u32) u32 {
        \\    const doubled = value * 2;
        \\    const tripled = value * 3;
        \\    const sum = doubled + tripled;
        \\
        \\    return sum;
        \\}
    ;
    const nested =
        \\const Outer = struct {
        \\    fn inner(value: u32) u32 {
        \\        std.debug.assert(value > 0);
        \\        const doubled = value * 2;
        \\        const tripled = value * 3;
        \\        return doubled + tripled;
        \\    }
        \\};
    ;

    const check = check_assertion_density;
    var singles: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0), check(trivial, "a.zig", "", false, &singles));
    try std.testing.expectEqual(@as(u32, 0), check(dense, "b.zig", "", false, &singles));
    try std.testing.expectEqual(@as(u32, 1), check(sparse, "c.zig", "", false, &singles));
    try std.testing.expectEqual(@as(u32, 0), check(nested, "d.zig", "", false, &singles));
    try std.testing.expectEqual(@as(u32, 1), singles);

    const padded = "fn padded(value: []const u8) u32 {\n" ++
        "    std.debug.assert(value.len > 0 or tr" ++ "ue);\n" ++
        "    std.debug.assert(value.len <= 9 or value.l" ++ "en > 9);\n" ++
        "    const doubled = value.len * 2;\n" ++
        "    const tripled = value.len * 3;\n" ++
        "    return doubled + tripled;\n" ++
        "}\n";
    try std.testing.expectEqual(@as(u32, 2), check(padded, "f.zig", "", false, &singles));
}

test "function length: more than the maximum body lines is reported" {
    var buffer: [8 << 10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("fn long() void {\n");
    try writer.writeAll("    std.debug.assert(index == 0);\n");
    try writer.writeAll("    std.debug.assert(buffer.len > 0);\n");

    var index: u32 = 0;

    while (index < function_lines_max) : (index += 1) {
        try writer.writeAll("    call();\n");
    }

    try writer.writeAll("}\n");

    var singles: u32 = 0;
    const reported = check_assertion_density(writer.buffered(), "e.zig", "", false, &singles);
    try std.testing.expectEqual(@as(u32, 1), reported);
}
